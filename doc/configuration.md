# Configuration Reference

Three layers of configuration, from broadest to narrowest:

1. **`.env`** — environment for the Ansible CLI itself plus a small set of
   cross-cutting values. Copied from `.env.example`, sourced before every
   run. The `env_guard` role refuses to run if it isn't loaded.
2. **`ansible/inventories/development/group_vars/all.yml`** — deployment
   toggles that multiple roles must agree on.
3. **Role defaults** (`ansible/roles/<role>/defaults/main.yml`) — per-role
   tunables. The defaults files are commented and are the authoritative
   reference; this page lists only the values most likely to be overridden.

A variable needed by more than one role must live in `group_vars/all.yml`,
not in a role's defaults — role defaults are invisible to other roles.

## .env

| Variable | Default | Purpose |
|---|---|---|
| `ARMORY_ENV_SOURCED` | `armory2-env-loaded-v1` | Sentry checked by `env_guard`; do not change |
| `ARMORY_LOG_NOLOG` | `false` | `true` disables `no_log` redaction (prints secrets; debugging only) |
| `ARMORY_PROJECT_ROOT` | `/vagrant/project-armory` | Repo mount point in the VM; all paths derive from it |
| `ARMORY_ANSIBLE_ROOT` | `${ARMORY_PROJECT_ROOT}/ansible` | Where playbooks run from |
| `ARMORY_PUBLIC_DOMAIN` | `armory.local` | External domain; drives ingress hosts, PKI allowed domains, cert role names |
| `ARMORY_PUBLIC_BASE_URL` | `https://armory.local` | Base URL consumed by OIDC redirect configuration |
| `ARMORY_HEADLAMP_HOST` | `headlamp.armory.local` | Headlamp ingress hostname |
| `ARMORY_INTERNAL_PKI_ALLOWED_DOMAINS` | `svc.cluster.local` | DNS suffixes the internal PKI issuer may sign |
| `VSO_CHART_PATH` | `/vagrant/project-armory/charts/vso-hardened` | Local hardened VSO chart (preferred for the demo) |
| `VSO_CHART_REPO` / `VSO_CHART_NAME` / `VSO_CHART_VERSION` | empty | Alternative: published hardened chart coordinates |
| `ANSIBLE_*` | see `.env.example` | Replaces `ansible.cfg` (inventory path, become, logging to `log/ansible.log`, `timer` callback, etc.) — the repo deliberately has no checked-in `ansible.cfg` because `/vagrant` is world-writable |

## group_vars/all.yml

| Variable | Current | Purpose |
|---|---|---|
| `keycloak_enabled` | `true` | Switches all consumers (k3s OIDC, headlamp, readiness) to the standalone Keycloak deployment |
| `trust_manager_enabled` | `true` | Installs trust-manager and the CA `Bundle` |
| `use_declarative_ca_distribution` | `true` | Consumers read CA from trust-manager target Secrets instead of per-role copies (cert-manager excepted) |
| `trust_manager_internal_ca_bundle_name` / `..._target_secret_name` | `openbao-ca-bundle` | Bundle and target Secret naming |
| `trust_manager_internal_ca_target_namespaces` | cert-manager, vso, keycloak, headlamp | Namespaces receiving the CA Secret |
| `keycloak_pg_tls_enabled` | `true` | Keycloak↔Postgres TLS with `sslmode=verify-full` |
| `ingress_http_policy` | `disabled` | `redirect-only` (HTTP→HTTPS redirect) or `disabled` (close 80/tcp in firewalld) |

These were staged-rollout toggles during the TLS build-out; all are now
enabled. They remain toggles so a regression can be bisected by flipping one
back.

## Notable role defaults

Authoritative list: each role's `defaults/main.yml`. Frequently relevant:

| Variable (role) | Default | Purpose |
|---|---|---|
| `openbao_chart_version` (openbao) | `""` (latest) | Pin only at ship time — see [decisions/0005](decisions/0005-track-latest-upstream.md) |
| `openbao_key_shares` / `openbao_key_threshold` (openbao) | 5 / 3 | Unseal shard scheme |
| `openbao_kv_mount` (openbao) | `secret` | KV v2 mount for application credentials |
| `openbao_pki_root_ttl` / `..._intermediate_ttl` / `..._cert_ttl` (openbao) | ~10y / ~5y / ~1y | Certificate lifetimes |
| `openbao_audit_enabled` (openbao) | `true` | File audit device on dedicated PVC |
| `openbao_audit_storage_size` (openbao) | `2Gi` | Audit PVC size |
| `openbao_audit_rotate_on_calendar` / `..._rotate_keep` (openbao) | `daily` / 7 | Host-side rotation cadence and retention |
| `keycloak_operator_version` (keycloak) | pinned (e.g. `26.5.2`) | Operator manifest version |
| `keycloak_realm_groups` (keycloak) | admin/operator/viewer groups | Top-level groups ensured in realm import + admin REST reconciliation |
| `keycloak_realm_users` (keycloak) | admin/operator/viewer users | Seeded realm users with OpenBao-backed passwords and expected group memberships |
| `keycloak_realm_admin_rotation_enabled` / `..._schedule` (keycloak) | `true` / ~monthly | Realm-admin password rotation CronJob |
| `headlamp_chart_version` (headlamp) | pinned | Headlamp Helm chart |
| `headlamp_oidc_group_bindings` (headlamp) | admins→cluster-admin, operators→edit, viewers→view | ClusterRoleBindings rendered per OIDC group |
| `k3s_version` (k3s) | `""` (latest) | k3s release channel default |
| `k3s_oidc_username_prefix` / `k3s_oidc_groups_prefix` (k3s) | `oidc:` / `oidc:` | Prefixes for OIDC usernames/groups to prevent RBAC identity collisions |
| `readiness_check_fail_on_issues` (readiness_check) | see defaults | Whether readiness failures fail the play |

Note: `openbao_audit_enabled` is also read by `readiness_check` (with a
`default(true)` guard). If you disable audit, set it in `group_vars/all.yml`
so both roles see it.

## Adding configuration

When surfacing a new option (an open backlog item aims to surface more):

- Single role → that role's `defaults/main.yml`, with a comment.
- Multiple roles → `group_vars/all.yml`, with a comment saying who reads it.
- Host/workstation-level or path/domain values → `.env` +
  `.env.example`, read via `lookup('ansible.builtin.env', ...)` with a
  default.
