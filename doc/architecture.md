# Architecture

How the components fit together and why they are ordered the way they are.
For day-to-day commands see [operations.md](operations.md); for the security
posture see [security.md](security.md); for tunables see
[configuration.md](configuration.md).

## Overview

Project Armory deploys a single-node Kubernetes platform on a Fedora VM
(Vagrant) with centralized secrets, internal PKI, and OIDC identity. All
provisioning is Ansible, running locally inside the VM against `localhost`.

Components and where they run:

| Component | Namespace | Deployed by role | Purpose |
|---|---|---|---|
| k3s | (host) | `k3s` | Kubernetes distribution; API server configured for Keycloak OIDC |
| OpenBao | `openbao` | `openbao` | Secrets (KV v2) and PKI root of trust; audit log |
| cert-manager | `cert-manager` | `cert_manager` | Issues TLS certificates from OpenBao PKI via ClusterIssuers |
| trust-manager | `cert-manager` | `trust_manager` | Distributes the OpenBao CA bundle to consumer namespaces |
| Envoy Gateway | `envoy-gateway-system` | `envoy_gateway` | Gateway API edge; HTTPS entry point and trace-context trust boundary |
| Vault Secrets Operator | `vault-secrets-operator-system` | `vso` | Syncs OpenBao secrets into Kubernetes Secrets |
| Keycloak + PostgreSQL | `keycloak` | `keycloak` | OIDC identity provider (operator + Keycloak CR + Postgres StatefulSet) |
| Headlamp | `headlamp` | `headlamp` | Kubernetes web UI, authenticated via Keycloak OIDC |
| metrics-server | `kube-system` | (bundled with k3s) | Resource metrics API (`kubectl top`, Headlamp graphs) |

## Role execution order

`playbooks/site.yml` runs roles in dependency order:

```
env_guard → system_update → helm → k3s → openbao → cert_manager
→ trust_manager → envoy_gateway → vso → keycloak → headlamp → readiness_check
```

The ordering constraints that matter:

- **openbao before cert_manager**: cert-manager's ClusterIssuers sign against
  OpenBao's PKI mounts, which must exist first.
- **cert_manager before trust_manager**: trust-manager is a cert-manager
  subproject and depends on its CRDs/webhooks. cert-manager is also the one
  consumer that cannot use trust-manager-distributed CA Secrets (it would be a
  circular dependency), so it self-bootstraps from a direct copy of the
  `openbao-ca` Secret.
- **vso before keycloak/headlamp**: both consumers create VSO custom
  resources; the CRDs and operator must exist.
- **keycloak before headlamp**: the headlamp role provisions its OIDC client
  in Keycloak and configures the k3s API server's OIDC flags (which need the
  issuer to exist). See [decisions/](decisions/) for why k3s OIDC config
  currently lives in the headlamp role.
- **readiness_check last**: validates the whole stack; see
  [operations.md](operations.md#readiness-checks).

The `common` role is not in the sequence; it is a utility included by other
roles (root-token loading, CA secret copying, internal HTTPS caller setup).

## Secrets flow

OpenBao KV v2 (mount `secret/`) is the source of truth for all generated
credentials. Nothing is hand-set; passwords are generated once by Ansible,
persisted to OpenBao, and reused on re-runs.

```
Ansible (generate once)                     consumers
        │                                       ▲
        ▼                                       │
   OpenBao KV v2  ──►  VSO (VaultStaticSecret) ──►  k8s Secret
   secret/keycloak/db          │                 keycloak-db-secret
   secret/keycloak/realm-admin │                 keycloak-realm-admin
   secret/headlamp/oidc        │                 (headlamp ns)
```

Per consumer, the VSO wiring is: a ServiceAccount, a `VaultConnection`
(HTTPS endpoint + CA Secret ref), a `VaultAuth` (Kubernetes auth role), and
one or more `VaultStaticSecret` resources. Each consumer gets its own OpenBao
ACL policy and Kubernetes auth role (`keycloak-vso`, `headlamp-vso`,
`keycloak-realm-admin-rotator`), scoped to its own KV paths. The duplication
across consumers is a known refactor candidate
([simplification-opportunities.md](simplification-opportunities.md) #3).

OpenBao authentication for in-cluster consumers is the Kubernetes auth
method: pods present their ServiceAccount token, OpenBao validates it against
the API server, and grants the policy bound to that role.

Ansible itself authenticates with a scoped periodic `ansible-provisioner`
token (encrypted at `/opt/openbao/provisioner-token.yml`, minted and renewed
by the openbao role). The root token is reserved for bootstrap and
break-glass: [decisions/0007](decisions/0007-scoped-provisioner-token.md).

## PKI and trust distribution

OpenBao is the certificate authority. Three PKI mounts form the hierarchy:

```
pki-root  ("Armory Root CA", ~10y)
  ├── pki-int  ("Armory Internal Issuing CA", ~5y)  → in-cluster service certs
  │       allowed domains: svc.cluster.local
  └── pki-ext  ("Armory External Issuing CA", ~5y)  → ingress certs
          allowed domains: ARMORY_PUBLIC_DOMAIN (default armory.local)
```

cert-manager exposes these as ClusterIssuers (`openbao-pki-internal`,
`openbao-pki-external`). Certificates:

- The consolidated edge certificate (`armory-tls`, all public hosts + node IP
  SAN, in the gateway namespace) is issued from `openbao-pki-external`.
- Internal service certs (Keycloak HTTPS on 8443, Postgres TLS, VSO
  kube-rbac-proxy) are issued from `openbao-pki-internal`.
- OpenBao's own server certificate is self-managed by the `openbao` role
  (openssl on the host) because OpenBao must serve TLS before its PKI
  engine exists.

CA distribution: trust-manager maintains a `Bundle` that copies the OpenBao
CA into a target Secret (`openbao-ca-bundle`) in each consumer namespace
(`cert-manager`, `vault-secrets-operator-system`, `keycloak`, `headlamp`).
This is the declarative path enabled by `use_declarative_ca_distribution`;
cert-manager is the exception noted above. The OpenBao CA is also installed
into the VM's system trust store (`/etc/pki/ca-trust/source/anchors/`) so
host-side automation can verify TLS.

## Identity and OIDC

Keycloak (realm `armory`) is the identity provider for both the Kubernetes
API server and Headlamp.

- **k3s API server**: configured with `--oidc-*` flags pointing at the
  `armory` realm (issuer URL, client, groups claim). Keycloak group
  membership maps to Kubernetes RBAC: the `admin` group is bound to
  `cluster-admin` via ClusterRoleBinding.
- **Headlamp**: the headlamp role provisions a dedicated OIDC client in the
  realm via the Keycloak admin REST API (client secret stored in OpenBao at
  `secret/headlamp/oidc`, synced by VSO). Users log into Headlamp with realm
  credentials; Headlamp forwards the OIDC token to the API server, which
  validates it against Keycloak.
- **Realm admin** (`admin`, the Headlamp login) is distinct from the
  Keycloak **master bootstrap admin** (console only). The realm admin
  password is rotated monthly by a CronJob; see
  [operations.md](operations.md#password-rotation).

Keycloak runs as: Keycloak Operator → `Keycloak` CR → pods, backed by a
plain PostgreSQL StatefulSet provisioned by the `keycloak` role (not the
operator). Realm and seed admin/group come from a `KeycloakRealmImport` CR;
per-client config (e.g. the Headlamp client) is REST-managed by consumers.

## Network and edge

- Envoy Gateway (Gateway API) is the HTTPS entry point. k3s disables both
  `traefik` and `servicelb`, so the Envoy Service is ClusterIP patched with
  the node IP as an `externalIP`; kube-proxy binds 443 (and 80 under
  `redirect-only`) on the node.
- The edge is the trust boundary for W3C trace context: inbound
  `traceparent`/`tracestate`/`baggage`/`b3` are stripped early on all
  external routes and the gateway mints the root span
  (see [decisions/0009](decisions/0009-envoy-gateway-edge.md)).
- `ingress_http_policy` controls port 80: `redirect-only` (HTTP→HTTPS
  redirect listener) or `disabled` (no HTTP listener; 80/tcp closed in
  firewalld).
- External hostnames (hosts-file or DNS on the workstation):
  `armory.local` (Keycloak) and `headlamp.armory.local` (Headlamp), both
  HTTPS behind the shared `openbao-pki-external` edge certificate. Routes are
  per-workload `HTTPRoute`s in the owning namespaces; the gateway re-encrypts
  to backends with `BackendTLSPolicy` validation.
- Internal traffic uses service FQDNs (`<svc>.<ns>.svc.cluster.local`) with
  TLS and explicit CA bundles; see [security.md](security.md#tls) for the
  per-path matrix.
- OpenBao is ClusterIP-only. Host-side automation reaches it because the
  `openbao` role maps `openbao.openbao.svc.cluster.local` to the Service
  ClusterIP in the VM's `/etc/hosts`. There is no NodePort.

## Implementation conventions

- Kubernetes objects are applied with `k3s kubectl` via `command` tasks;
  Helm releases with `helm upgrade --install`. This is a deliberate
  dependency-free choice; see [decisions/](decisions/) for the trade-off
  against `kubernetes.core`.
- Manifests are Jinja2 templates in each role's `templates/`, rendered and
  piped to `kubectl apply -f -`, with `changed_when` keyed on
  `created`/`configured` in stdout.
- Idempotency: Helm owns external components; generated credentials are
  read-before-write against OpenBao; OpenBao init is guarded by the presence
  of the init-keys file.
- Every role is tagged for targeted re-runs (`--tags openbao`, etc.).
