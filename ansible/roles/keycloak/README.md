# keycloak role

## Purpose
Deploy standalone Keycloak in Armory as a shared identity provider, using the
official **Keycloak Operator** backed by a plain **PostgreSQL StatefulSet**, with
OpenBao-backed DB credentials (synced via VSO) and a declarative bootstrap of the
`armory` realm.

## What this role does
1. Ensures the `keycloak` namespace.
2. Generates/persists credentials in OpenBao:
   - `secret/keycloak/db` — PostgreSQL `username`/`password` (VSO-synced).
   - `secret/keycloak/realm-admin` — seed realm-admin password (Ansible-injected
     into the realm import; never synced to a k8s Secret).
3. Configures an OpenBao policy + Kubernetes auth role for VSO (DB secret only).
4. Applies VaultConnection, VaultAuth, and a VaultStaticSecret that syncs the DB
   credentials into the `keycloak-db-secret` Secret (keys `username`/`password`).
5. Deploys a PostgreSQL StatefulSet + Service (`postgres:16`, local-path PVC).
  When `keycloak_pg_tls_enabled=true`, PostgreSQL serves TLS with a cert-manager
  certificate and Keycloak connects with `sslmode=verify-full`.
6. Installs the Keycloak Operator (pinned CRDs + operator Deployment).
7. Applies the `Keycloak` custom resource (internal HTTPS only via the existing
   TLS secret flow, `http.httpEnabled: false`, `ingress.enabled: false`,
   `proxy.headers: xforwarded`, `hostname.strict: false`).
8. Applies a `KeycloakRealmImport` for the `armory` realm (seed admin user, admin
   group, groups protocol mapper). The Headlamp OIDC client is **not** created
   here — the Headlamp role provisions it via the admin REST API.
9. Applies an own nginx `Ingress` referencing the existing `armory-tls` secret.

## Credentials
- **Keycloak master admin** is generated in OpenBao and materialized as
  `keycloak-bootstrap-admin` (keys `username` / `password`) before first CR
  creation. Consumers (Headlamp, readiness) read this Secret.
- **Realm end-user `admin`** (logs into Headlamp; bound to `cluster-admin` by k3s
  via the `<issuer>#admin` User subject) is seeded by the realm import with the
  password from `secret/keycloak/realm-admin`.

## Internal TLS caller standard
- Internal Keycloak control-plane callers must use
  `https://<service>.<namespace>.svc.cluster.local:8443`.
- Callers must build an explicit trust bundle that includes both the OpenBao root
  CA and the issuer CA from the OpenBao internal PKI mount (default: `pki-int`).
- The role's rotator setup follows this via the shared
  `common/tasks/prepare_internal_https_caller.yml` helper.

## Activation
Staged off by default. Enable **globally** (inventory/group_vars or extra-vars) so
consumer roles (headlamp, k3s, readiness) switch their coordinates too:

```yaml
keycloak_enabled: true
```

Then run:

```bash
ansible-playbook playbooks/site.yml --tags keycloak_install
```

## Key variables
| Variable | Default | Notes |
|---|---|---|
| `keycloak_enabled` | `false` | Master switch (set globally). |
| `keycloak_operator_version` | `26.5.2` | Pins CRDs + operator + server image. |
| `keycloak_realm` | `armory` | Armory's own realm. |
| `keycloak_cr_name` | `keycloak` | Drives the Keycloak service and bootstrap admin secret. |
| `keycloak_public_base_url` | `$ARMORY_PUBLIC_BASE_URL` / `https://armory.local` | Issuer + ingress host. |
| `keycloak_ingress_tls_secret` | `armory-tls` | Referenced, not created. |
| `keycloak_pg_image` | `postgres:16` | Backing DB. |
| `keycloak_pg_tls_enabled` | `true` | Enable Postgres TLS + Keycloak verify-full DB connection. |
| `keycloak_pg_tls_verify_mode` | `verify-full` | JDBC SSL verification mode enforced by Keycloak. |
| `keycloak_pg_storage_size` | `8Gi` | local-path PVC. |
| `keycloak_hostname_strict` | `false` | Lets in-cluster callers use the ClusterIP service. |

## Notes / limitations
- Operator manifests are fetched by URL from `raw.githubusercontent.com`; the VM
  needs egress. To air-gap, vendor the three YAMLs and point
  `keycloak_k8s_resources_base_url` at a local path.
- PostgreSQL has no backups configured (single-node dev/demo posture).
- `KeycloakRealmImport` is bootstrap-oriented; ongoing per-client config is
  REST-driven by consumers.
