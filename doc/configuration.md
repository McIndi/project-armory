# Configuration Reference

Three layers of configuration, from broadest to narrowest:

1. **`.env`** — environment for the Ansible CLI itself plus a small set of
   cross-cutting values. Copied from `.env.example`, sourced before every
   run. The `env_guard` role refuses to run if it isn't loaded.
2. **`ansible/inventories/openshift/group_vars/all.yml`** — deployment toggles
   that multiple roles must agree on.
3. **Role defaults** (`ansible/roles/<role>/defaults/main.yml`) — per-role
   tunables. The defaults files are commented and are the authoritative
   reference; this page lists only the values most likely to be overridden.

A variable needed by more than one role must live in the OpenShift
inventory's `group_vars/all.yml`, not in a role's defaults — role defaults are
invisible to other roles.

## .env

| Variable | Default | Purpose |
|---|---|---|
| `ARMORY_ENV_SOURCED` | `armory2-env-loaded-v1` | Sentry checked by `env_guard`; do not change |
| `ARMORY_LOG_NOLOG` | `false` | `true` disables `no_log` redaction (prints secrets; debugging only) |
| `ARMORY_PROJECT_ROOT` | `/vagrant/project-armory` | Repo mount point in the VM; all paths derive from it |
| `ARMORY_ANSIBLE_ROOT` | `${ARMORY_PROJECT_ROOT}/ansible` | Where playbooks run from |
| `ARMORY_PUBLIC_DOMAIN` | `armory.local` | External domain; drives ingress hosts, PKI allowed domains, cert role names |
| `ARMORY_PUBLIC_BASE_URL` | `https://armory.local` | Base URL consumed by OIDC redirect configuration |
| `ARMORY_OPENBAO_HOST` | `openbao.armory.local` | OpenBao UI ingress hostname |
| `ARMORY_EDGE_EXTRA_SAN_HOSTS` | empty | Optional comma-separated extra DNS SANs appended to the consolidated edge certificate |
| `ARMORY_INTERNAL_PKI_ALLOWED_DOMAINS` | `svc.cluster.local` | DNS suffixes the internal PKI issuer may sign |
| `ANSIBLE_*` | see `.env.example` | Controller-side Ansible behavior (log path, callback, ssh/pipelining, etc.); local runs in `/vagrant` should set `ANSIBLE_CONFIG=/vagrant/project-armory/ansible/ansible.cfg` because `/vagrant` is world-writable |

## group_vars/all.yml

| Variable | Current | Purpose |
|---|---|---|
| `armory_privileged_tasks` | `false` | Keeps cluster-scoped privilege grants in `bootstrap.yml`; `site.yml` runs scoped |
| `armory_apps_domain` | cluster-specific | Shared apps domain used to derive public hosts |
| `keycloak_enabled` | `true` | Enables standalone Keycloak deployment |
| `keycloak_public_base_url` | `https://<armory_keycloak_host>` | Canonical external Keycloak URL for issuer/redirects |
| `keycloak_pg_tls_enabled` | `true` | Keycloak↔Postgres TLS with `sslmode=verify-full` |
| `ingress_http_policy` | `disabled` | `redirect-only` (HTTP→HTTPS redirect) or `disabled` (close 80/tcp in firewalld) |
| `openbao_ui_enabled` | `true` (OpenShift inventory) | Enables OpenBao UI ingress exposure and OIDC follow-on wiring |

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
| `openbao_audit_rotate_cron_schedule` / `..._rotate_keep` (openbao) | `17 2 * * *` / 7 | In-cluster CronJob rotation cadence and retention |
| `openbao_ui_enabled` / `openbao_ingress_enabled` (openbao) | `false` / `{{ openbao_ui_enabled }}` | Feature flag and ingress toggle for OpenBao UI exposure |
| `openbao_ingress_host` / `openbao_ingress_tls_secret_name` (openbao) | `openbao.<domain>` / `openbao-ui-tls` | OpenBao UI ingress host and cert secret |
| `openbao_ingress_tls_issuer_name` (openbao) | `openbao-pki-external` | cert-manager ClusterIssuer used by ingress-shim |
| `openbao_oidc_client_id` / `openbao_oidc_secret_path` (openbao_oidc) | `openbao` / `openbao/ui-oidc` | Keycloak client id and OpenBao KV path for persisted client secret |
| `openbao_oidc_redirect_uris` (openbao_oidc) | UI callback pair | Required redirect URI list for OpenBao UI OIDC login |
| `keycloak_deployment_name` (keycloak) | `keycloak` | Deployment identity root; service defaults to `<name>-service` |
| `keycloak_realm_groups` (keycloak) | admin/operator/viewer groups | Top-level groups ensured in realm import + admin REST reconciliation |
| `keycloak_realm_users` (keycloak) | admin/operator/viewer users | Seeded realm users with OpenBao-backed passwords and expected group memberships |
| `keycloak_admin_events_prune_enabled` / `..._cron_schedule` (keycloak) | `true` / weekly | Admin-event retention prune CronJob control |
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
