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
| `ARMORY_OPENBAO_HOST` | `openbao.armory.local` | OpenBao UI ingress hostname |
| `ARMORY_EDGE_EXTRA_SAN_HOSTS` | empty | Optional comma-separated extra DNS SANs appended to the consolidated edge certificate |
| `ARMORY_EDGE_GATEWAY_IP` | empty | Optional explicit edge bind/probe IP override |
| `ARMORY_EDGE_GATEWAY_INTERFACE` | empty | Optional interface override when explicit edge IP is unset |
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
| `edge_gateway_ip` | empty (or `ARMORY_EDGE_GATEWAY_IP`) | Canonical edge IP override for gateway externalIP, host mappings, and readiness probes |
| `edge_gateway_interface` | empty (or `ARMORY_EDGE_GATEWAY_INTERFACE`) | Interface override used when `edge_gateway_ip` is unset |
| `edge_gateway_excluded_cidrs` | `10.0.2.0/24` | CIDRs excluded from automatic edge-IP candidate selection |
| `edge_gateway_excluded_ifname_patterns` | `^lo$`, `^cni.*`, `^flannel.*`, `^docker.*`, `^virbr.*` | Interface name patterns excluded from automatic edge-IP candidate selection |
| `keycloak_pg_tls_enabled` | `true` | Keycloak↔Postgres TLS with `sslmode=verify-full` |
| `ingress_http_policy` | `disabled` | `redirect-only` (HTTP→HTTPS redirect) or `disabled` (close 80/tcp in firewalld) |
| `openbao_ui_enabled` | `true` (development inventory) | Enables OpenBao UI ingress exposure and OIDC follow-on wiring |

These were staged-rollout toggles during the TLS build-out; all are now
enabled. They remain toggles so a regression can be bisected by flipping one
back.

### Canonical edge IP resolution

Playbooks resolve a single `edge_gateway_ip_resolved` value before role
execution with this precedence:

1. `edge_gateway_ip`
2. `edge_gateway_interface`
3. First auto-detected active IPv4 candidate not matching excluded
   interface patterns/CIDRs
4. `ansible_facts.default_ipv4.address` fallback

One-off deterministic override example:

```bash
ansible-playbook playbooks/site.yml -e edge_gateway_ip=192.168.56.10
```

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
| `openbao_ui_enabled` / `openbao_ingress_enabled` (openbao) | `false` / `{{ openbao_ui_enabled }}` | Feature flag and ingress toggle for OpenBao UI exposure |
| `openbao_ingress_host` / `openbao_ingress_tls_secret_name` (openbao) | `openbao.<domain>` / `openbao-ui-tls` | OpenBao UI ingress host and cert secret |
| `openbao_ingress_tls_issuer_name` (openbao) | `openbao-pki-external` | cert-manager ClusterIssuer used by ingress-shim |
| `openbao_oidc_client_id` / `openbao_oidc_secret_path` (openbao_oidc) | `openbao` / `openbao/ui-oidc` | Keycloak client id and OpenBao KV path for persisted client secret |
| `openbao_oidc_redirect_uris` (openbao_oidc) | UI callback pair | Required redirect URI list for OpenBao UI OIDC login |
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
