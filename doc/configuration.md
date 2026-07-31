# Configuration Reference

Three layers of configuration, from broadest to narrowest:

1. **`.env`** — environment for the Ansible CLI itself plus a small set of
   cross-cutting values. Copied from `.env.openshift.example` (the template
   for this branch's actual target — the OpenShift inventory), sourced before
   every run. The `env_guard` role refuses to run if it isn't loaded.
   `.env.example` is a separate, older template for a k3s-based deployment
   this branch no longer supports; don't use it here.
2. **`ansible/inventories/openshift/group_vars/all.yml`** — deployment toggles
   that multiple roles must agree on.
3. **Role defaults** (`ansible/roles/<role>/defaults/main.yml`) — per-role
   tunables. The defaults files are commented and are the authoritative
   reference; this page lists only the values most likely to be overridden.

A variable needed by more than one role must live in the OpenShift
inventory's `group_vars/all.yml`, not in a role's defaults — role defaults are
invisible to other roles.

## .env

Values from `.env.openshift.example` — the template this branch actually
uses. Most host/domain values that mattered on k3s now come from
`inventories/openshift/group_vars/all.yml` instead (they derive from the
cluster's apps domain); `.env` only carries what Ansible itself needs plus
cluster access.

| Variable | Default | Purpose |
|---|---|---|
| `ARMORY_ENV_SOURCED` | `armory2-env-loaded-v1` | Sentry checked by `env_guard`; do not change |
| `ARMORY_LOG_NOLOG` | `false` | `true` disables `no_log` redaction (prints secrets; debugging only) |
| `ARMORY_PROJECT_ROOT` | `${HOME}/project-armory` | Repo root on the Fedora 44 workstation; use `/opt/project-armory` if you install it there |
| `ARMORY_ANSIBLE_ROOT` | `${ARMORY_PROJECT_ROOT}/ansible` | Where playbooks run from |
| `KUBECONFIG` | `${HOME}/.kube/config` | The controller runs outside the cluster; produced by `oc login`. The OpenShift inventory reads it |
| `ANSIBLE_INVENTORY` | `inventories/openshift/hosts.yml` | The line that actually selects OpenShift — pointing this at a k3s-era inventory fails against this cluster |
| `ARMORY_PUBLIC_DOMAIN` | `apps.example.com` | The cluster's real apps domain. Names the OpenBao external PKI cert role; public TLS itself comes from the router's Let's Encrypt wildcard, so that issuer is largely vestigial here, but the name should still reflect the real domain |
| `ARMORY_INTERNAL_PKI_ALLOWED_DOMAINS` | `svc.cluster.local` | DNS suffixes the internal PKI issuer may sign |
| `ARMORY_PUBLIC_BASE_URL`, `ARMORY_OPENBAO_HOST`, `ARMORY_HEADLAMP_HOST`, `ARMORY_EDGE_GATEWAY_IP` | — | Not used on OpenShift. Kept only so any code that still does a lookup on them doesn't trip over one being entirely absent; the real values come from the inventory (`keycloak_public_base_url`, `openbao_ingress_host`), Headlamp isn't deployed on this branch, and there's no node edge to bind an IP to |
| `ANSIBLE_*` (remaining) | see `.env.openshift.example` | Controller-side Ansible behavior (log path, callback, retries, etc.) |

There is no `ansible.cfg` — Ansible behavior comes entirely from the
`ANSIBLE_*` vars above, which is why `set -a` before sourcing `.env` matters:
without it they're set in your shell but never exported to the
`ansible-playbook` child process.

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
| `openbao_ui_enabled` (openbao) | `false` | Feature flag for OpenBao UI exposure |
| `openbao_ingress_host` (openbao) | `openbao.<domain>` | OpenBao UI public hostname. Exposure itself isn't a dedicated Ingress/Route — it's an entry in `envoy_proxy_upstreams`, sharing the same Route + Envoy edge as Keycloak; TLS issuer is `envoy_proxy_tls_issuer_name` |
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
