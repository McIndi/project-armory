# Security Posture

What is protected, how, and — equally important — what is deliberately not
hardened because this is a single-VM demonstration environment. Architecture
background: [architecture.md](architecture.md).

## Credential model

All generated credentials live in OpenBao KV v2 (`secret/`). Nothing is
hand-set or committed to the repo.

| Identity | Credential | Scope |
|---|---|---|
| In-cluster consumers (VSO sync, rotator) | Kubernetes auth: ServiceAccount token → OpenBao role | Per-consumer ACL policy (`keycloak-vso`, `headlamp-vso`, `keycloak-realm-admin-rotator`), each limited to its own KV paths |
| cert-manager | Kubernetes auth → `cert-manager` role | `cert-manager` policy: sign certificates on the PKI mounts only |
| Ansible automation | Scoped periodic `ansible-provisioner` token, encrypted at `/opt/openbao/provisioner-token.yml` | KV write on `keycloak/*`/`headlamp/*` only, external-CA PEM read, `sys/audit` read; cannot author policies or bind auth roles ([decisions/0007](decisions/0007-scoped-provisioner-token.md)) |
| Human break-glass | Root token via Ansible Vault file or KV `secret/openbao/init` | See [operations.md](operations.md#break-glass-openbao-root-token) |
| Keycloak realm admin (`admin`) | Generated password, rotated ~monthly by CronJob | Realm `armory`; this is the Headlamp login |
| Keycloak master bootstrap admin | Generated password | Master realm console only |
| Rotator service account | Dedicated Keycloak client `realm-admin-rotator` | realm-management `manage-users` only — cannot administer the realm |

Key properties:

- Passwords are generated once (32/24-char random), persisted to OpenBao,
  and reused on re-runs; rotation goes through OpenBao so VSO propagates it.
- Each VSO consumer has its own ServiceAccount, OpenBao role, and policy.
  No shared in-cluster credential exists.
- The OpenBao unseal keys (5 shares, threshold 3) and root token are stored
  Ansible-Vault-encrypted on the VM.

## TLS

Standards applied across the stack:

- Internal callers use service FQDNs (`<svc>.<ns>.svc.cluster.local`), never
  raw IPs or short names.
- Internal HTTPS callers use explicit CA bundles (OpenBao root + issuer CA);
  `skipTLSVerify` is asserted **off** by readiness checks.
- Ingress backend protocol matches the service's TLS mode (e.g. Keycloak
  ingress terminates externally and re-encrypts to HTTPS upstream on 8443).

Communication paths:

| Path | Transport | Certificate source |
|---|---|---|
| Workstation → ingress (Keycloak, Headlamp) | HTTPS | `openbao-pki-external` via cert-manager |
| Ingress → Keycloak | HTTPS (8443) | `openbao-pki-internal` |
| Ingress → Headlamp | HTTPS | `openbao-pki-internal` |
| Keycloak → PostgreSQL | TLS `verify-full` (`keycloak_pg_tls_enabled`) | `openbao-pki-internal` |
| VSO / cert-manager / Ansible → OpenBao | HTTPS (8200) | OpenBao role self-managed server cert; CA distributed by trust-manager |
| k3s API server → Keycloak (OIDC) | HTTPS with explicit CA file | `openbao-pki-internal` chain |
| kube-rbac-proxy sidecar (VSO metrics) | HTTPS | `openbao-pki-internal` (hardened chart `charts/vso-hardened`) |
| Workstation HTTP (port 80) | Closed (`ingress_http_policy: disabled`) or redirect-only | — |

CA distribution is declarative via trust-manager (`openbao-ca-bundle` Secret
per consumer namespace); cert-manager self-bootstraps from a direct copy
because it anchors the chain. The VM system trust store also carries the
OpenBao root CA.

## Audit logging

OpenBao runs a `file` audit device (declared in server config — OpenBao
v2.4+ rejects API-driven audit device creation as unsafe; see
[decisions/0004](decisions/0004-declarative-audit-device.md)).

- Captures every request/response: caller identity, policies evaluated and
  the granting policy, operation, path, source address.
- Secret values and tokens are HMAC-SHA256 hashed — auditable without being
  readable.
- Dedicated PVC; daily host-side rotation, 7 files kept.
- OpenBao **blocks all requests** if no enabled audit device is writable —
  fail-closed by design.

Viewing and query recipes: [operations.md](operations.md#openbao-audit-log).

Current limitation: Ansible's API calls appear as the root token's identity,
so automation traffic is not distinguishable per task. The provisioner-token
change gives automation its own identity in this log.

## Ansible output hygiene

Tasks that handle credentials set `no_log`, controlled by
`ARMORY_LOG_NOLOG` (default `false` = redacted). Setting it to `true` prints
secrets to console and `log/ansible.log` — use only for short debugging
sessions and rotate anything exposed.

## Kubernetes RBAC

- k3s API server validates OIDC tokens from the `armory` realm; the Keycloak
  `admin` group maps to `cluster-admin` via ClusterRoleBinding.
- Finer-grained per-role users (view-only, namespace-scoped) are not yet
  implemented — tracked in the backlog.

## Demo-grade vs production: accepted gaps

These are known, deliberate trade-offs for a single-VM demonstration. They
are listed here so the posture is honest; several are tracked in the backlog.

| Gap | Detail | Status |
|---|---|---|
| Vault password co-location | `/opt/openbao/.vault-pass` sits beside the files it encrypts; encryption at rest protects against off-host copy, not host compromise | Accepted for demo |
| Manual unseal keys on disk | Auto-unseal (KMS/HSM) not configured; unseal shards live in the encrypted init-keys file | Accepted for demo |
| No backup/restore | OpenBao `file` storage and Postgres PVC have no snapshot story; losing the disk loses all secrets and the root CA | Backlog |
| Single node, single replica | No HA for OpenBao, Keycloak, or ingress | By design (demo) |
| Unpinned component versions | Tracks latest upstream during development, by policy ([decisions/0005](decisions/0005-track-latest-upstream.md)); pinning is an end-of-project step | By design |
| No runtime security / network policies | No NetworkPolicies, no admission control, no falco-class monitoring | Out of scope |
| Coarse RBAC | Single admin group → cluster-admin | Backlog |
