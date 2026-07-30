# Security Posture

What is protected, how, and — equally important — what is deliberately not
hardened because this is a single-tenant reference deployment, not a
production-hardened one. Architecture background:
[architecture.md](architecture.md).

## Credential model

All generated credentials live in OpenBao KV v2 (`secret/`). Nothing is
hand-set or committed to the repo. There is no sync operator (Vault Secrets
Operator was removed — see
[decisions/0010](decisions/0010-remove-vso-playbook-materialized-secrets.md)):
the playbook writes the derived Kubernetes Secret itself, immediately after
writing the same value to OpenBao KV.

| Identity | Credential | Scope |
|---|---|---|
| cert-manager | Kubernetes auth → `cert-manager` role | `cert-manager` policy: sign certificates on the PKI mounts only |
| Ansible automation | Scoped periodic `ansible-provisioner` token, encrypted at `~/.armory/openbao/provisioner-token.yml` on the controller | KV write on `keycloak/*`, `openbao/*`, `registry/*` only, external-CA PEM read, `sys/audit` read; cannot author policies or bind auth roles ([decisions/0007](decisions/0007-scoped-provisioner-token.md)) |
| Human break-glass | Root token via Ansible Vault file or KV `secret/openbao/init` | See [operations.md](operations.md#break-glass-openbao-root-token) |
| Human OpenBao UI access | Keycloak OIDC (`openbao` client) | Keycloak groups (`armory-admins`/`-operators`/`-viewers`) map via OpenBao external identity group-aliases to policies `armory-ui-admin`/`-operator`/`-viewer` |
| Keycloak realm admin (`admin`) | Generated password | Realm `armory`; used for OpenBao UI login only — not a cluster identity |
| Keycloak master bootstrap admin | Generated password | Master realm console only |
| Registry push/pull | htpasswd (bcrypt), generated password | `armory` username; pull secrets materialized into consumer namespaces |

Key properties:

- Passwords are generated once (24/32-char random), persisted to OpenBao,
  and reused on re-runs — never regenerated just because the playbook ran
  again.
- Rotating a credential means re-running the owning role's tags (e.g.
  `site.yml --tags keycloak_install`), which updates OpenBao KV and then
  reapplies the Kubernetes Secret together. There is no background
  reconciliation loop keeping the two in sync between runs.
- The OpenBao unseal keys (5 shares, threshold 3) and root token are stored
  Ansible-Vault-encrypted on the controller under `~/.armory/openbao`.

## TLS

Standards applied across the stack:

- Internal callers use service FQDNs (`<svc>.<ns>.svc.cluster.local`), never
  raw IPs or short names.
- Internal HTTPS callers use explicit CA bundles; `skipTLSVerify` is asserted
  **off** by readiness checks. Public endpoints (Keycloak, OpenBao UI) are
  validated against real system trust, since the OpenShift router serves them
  behind a publicly-trusted Let's Encrypt wildcard certificate.
- Ingress backend protocol matches the service's TLS mode: an OpenShift Route
  terminates externally (`reencrypt`) and re-encrypts to the in-namespace
  Envoy edge, which re-encrypts again to the actual workload (Keycloak on
  8443, OpenBao on 8200). The router alone can't provide this — see
  [architecture.md](architecture.md#network-and-edge) for why Envoy sits
  between the Route and every workload.

Communication paths:

| Path | Transport | Certificate source |
|---|---|---|
| Workstation → Route (Keycloak, OpenBao UI, registry) | HTTPS | OpenShift router's Let's Encrypt wildcard (cluster-managed, not armory's) |
| Route → Envoy edge | HTTPS (re-encrypt) | `tex26-openbao-pki-internal` |
| Envoy edge → Keycloak / OpenBao upstream | HTTPS (re-encrypt) | Combined trust bundle: OpenBao's own bootstrap CA (signs OpenBao's listener) + the `pki-int` issuer CA (signs Keycloak's) — these are two distinct CAs, not one |
| Keycloak → PostgreSQL | TLS `verify-full` (`keycloak_pg_tls_enabled`) | `tex26-openbao-pki-internal` |
| cert-manager / Ansible → OpenBao | HTTPS (8200) | OpenBao's own bootstrap CA, generated on the controller and copied into consumer namespaces as needed |
| Workstation HTTP (port 80) | Closed (`ingress_http_policy: disabled`) or redirect-only | — |

CA distribution is **imperative, not declarative**: trust-manager's CRDs are
present on the cluster but its controller isn't running (owner's cluster
configuration), so armory copies CA secrets between namespaces directly
(`common/tasks/copy_openbao_ca_secret.yml`) and builds combined trust bundles
where a consumer needs to validate more than one CA
(`common/tasks/prepare_internal_https_caller.yml`). The controller's own
system trust store also carries OpenBao's bootstrap CA (installed via
`update-ca-trust` during `openbao` role install).

## Audit logging

OpenBao runs a `file` audit device (declared in server config — OpenBao
v2.4+ rejects API-driven audit device creation as unsafe; see
[decisions/0004](decisions/0004-declarative-audit-device.md)).

- Captures every request/response: caller identity, policies evaluated and
  the granting policy, operation, path, source address.
- Secret values and tokens are HMAC-SHA256 hashed — auditable without being
  readable.
- Dedicated PVC; daily in-cluster CronJob rotation, 7 files kept.
- OpenBao **blocks all requests** if no enabled audit device is writable —
  fail-closed by design.

Viewing and query recipes: [operations.md](operations.md#openbao-audit-log).

Day-to-day automation authenticates as the `ansible-provisioner` token, not
root, so its traffic is attributable to that identity in the log rather than
appearing as root activity. Task-level attribution beyond that (which
specific Ansible task made a given call) isn't available — every provisioner
call looks the same in the log regardless of which role issued it.

## Kubernetes / OpenShift RBAC

Cluster login itself (`oc login`, the OpenShift web console) uses the
cluster's own LDAP identity provider — that's the cluster owner's
configuration, not something armory manages or can change. Keycloak is an
**application-level** identity provider only: it gates OpenBao UI login, not
cluster access.

The automation account (`tex26-automation`) that runs `site.yml` is scoped to
least privilege, not cluster-admin:

- Its Role/ClusterRole grants come from the exact same rule lists
  (`automation_rbac_namespace_rules`, `automation_rbac_cluster_rules`) that
  `roles/automation_rbac/tasks/preflight.yml` checks against before any work
  starts, so a grant and its check cannot drift apart.
- Three grants it cannot make for itself (OpenBao's token-review binding,
  OpenBao's SCC binding, cert-manager's self-token Role) are applied instead
  by `bootstrap.yml`, run once as cluster-admin — see
  [architecture.md](architecture.md#role-execution-order).
- `site.yml`'s preflight is a sample, not an exhaustive check of every
  verb×resource combination: it checks one combination per declared rule.
  Since RBAC grants a rule's resources and verbs atomically once bound, this
  still proves the grant is live, but it won't catch an out-of-band edit to
  a live Role or a `resourceNames`-scoped rule that varies within itself.

## Demo-grade vs production: accepted gaps

These are known, deliberate trade-offs for a single-tenant reference
deployment. They are listed here so the posture is honest; several are
tracked in the backlog.

| Gap | Detail | Status |
|---|---|---|
| Vault password co-location | `~/.armory/openbao/.vault-pass` sits beside the files it encrypts on the controller; encryption at rest protects against off-host copy, not controller compromise | Accepted for demo |
| Manual unseal keys on disk | Auto-unseal (KMS/HSM) not configured; unseal shards live in the encrypted init-keys file | Accepted for demo |
| No backup/restore | OpenBao `file` storage and Postgres PVC have no snapshot story; losing the disk loses all secrets and the root CA | Backlog |
| No HA for OpenBao, Keycloak, or PostgreSQL | Single replica each. The Envoy edge itself does run 2 replicas by default (`envoy_proxy_replicas`), so the edge alone isn't a single point of failure, but everything behind it is | By design (demo) |
| Unpinned component versions | Tracks latest upstream during development, by policy ([decisions/0005](decisions/0005-track-latest-upstream.md)); pinning is an end-of-project step | By design |
| No runtime security / network policies | No NetworkPolicies, no admission control, no falco-class monitoring | Out of scope |
| OpenBao UI exposed on ingress | Demo convenience for end-to-end SSO and role walkthroughs; increases external attack surface versus API-only exposure | Enabled only via `openbao_ui_enabled` toggle |
