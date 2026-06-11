# VSO Extraction Plan — Standalone `vso` Role

> **ARCHIVED — executed. Kept for history; do not follow as current
> instructions.** Durable rationale lives in [../decisions/](../decisions/).

Status: proposed (evaluation stage — no changes applied)
Scope: extract the **Vault Secrets Operator (VSO) install** out of
`beeai_agentstack_tofu` into a standalone `vso` role, so VSO is a shared
prerequisite that any consumer (keycloak, headlamp, beeai) can rely on.
Goal: unblock standalone-Keycloak validation (clean `--tags vso`) and remove the
last hard dependency on the beeai role before its deletion.
Companion: [`keycloak-operator-implementation-plan.md`](keycloak-operator-implementation-plan.md).

## 1. Why

VSO is a **shared** cluster dependency: `keycloak`, `headlamp`
([`headlamp/tasks/deploy.yml`](../../ansible/roles/headlamp/tasks/deploy.yml)), and
`beeai_agentstack_tofu` all create VSO custom resources
(VaultConnection / VaultAuth / VaultStaticSecret) to sync OpenBao secrets.

But the **operator itself** is installed only inside the beeai role, and those
install tasks share one `block` with the entire agentstack chart deploy
([`beeai_agentstack_tofu/tasks/main.yml:7`](../../ansible/roles/beeai_agentstack_tofu/tasks/main.yml),
tag `beeai_vso` but not separable from the chart apply). Consequences:

- You cannot install VSO without deploying Agent Stack.
- Removing `beeai_agentstack_tofu` (the cutover endgame) would take VSO with it
  and break **both** keycloak and headlamp.

Extracting VSO into its own role fixes both and makes the dependency explicit.

## 2. Split: what moves vs what stays

**Moves into the new `vso` role (the shared operator install):**
- Hardened-chart validation assert.
- VSO working dir + effective Helm values (controller kube-rbac-proxy TLS +
  `defaultVaultConnection`).
- VSO namespace creation.
- OpenBao CA secret copy **into the VSO namespace** (for the operator's default
  connection).
- cert-manager `Certificate` for the kube-rbac-proxy TLS + waits for cert/secret.
- `helm upgrade --install` of the hardened VSO chart.

(Source: [`beeai_agentstack_tofu/tasks/main.yml:9-203`](../../ansible/roles/beeai_agentstack_tofu/tasks/main.yml).)

**Stays in each consumer role (per-namespace, per-consumer):**
- ServiceAccount + VaultConnection + VaultAuth + VaultStaticSecret.
- OpenBao CA secret copy into the consumer's own namespace.
- OpenBao ACL policy + Kubernetes auth role for that consumer.

`keycloak` already owns these (its templates + tasks); `headlamp` owns them in
`deploy.yml`; `beeai` keeps its own. No consumer change needed beyond ordering.

## 3. New role layout

```
ansible/roles/vso/
├─ defaults/main.yml      # vso_* vars (renamed from beeai_vso_*)
├─ meta/main.yml
├─ tasks/main.yml         # the 6 moved task groups above
├─ templates/
│   └─ kube_rbac_proxy_certificate.yaml.j2   # moved from beeai templates
└─ README.md
```

### Variable rename (`beeai_vso_*` → `vso_*`)
| Old (beeai) | New (vso role) |
|---|---|
| `beeai_vso_chart_path` / `_repo` / `_name` / `_version` | `vso_chart_path` / … |
| `beeai_vso_release_name` (`vault-secrets-operator`) | `vso_release_name` |
| `beeai_vso_namespace` (`vault-secrets-operator-system`) | `vso_namespace` |
| `beeai_vso_require_hardened_chart` | `vso_require_hardened_chart` |
| `beeai_vso_helm_timeout_seconds` | `vso_helm_timeout_seconds` |
| `beeai_vso_kube_rbac_proxy_tls_*` | `vso_kube_rbac_proxy_tls_*` |
| `beeai_vso_kube_rbac_proxy_cert_*` (issuer `openbao-pki`/ClusterIssuer) | `vso_kube_rbac_proxy_cert_*` |
| `beeai_vso_chart_values` | `vso_chart_values` |
| `beeai_openbao_cluster_addr` / `_tls_server_name` / `_ca_secret_name` | `vso_openbao_cluster_addr` / … |

### Env var rename (with fallback during transition)
`BEEAI_VSO_CHART_PATH` / `_REPO` / `_NAME` / `_VERSION` →
`VSO_CHART_PATH` / `_REPO` / `_NAME` / `_VERSION`, e.g.
`lookup('env','VSO_CHART_PATH') | default(lookup('env','BEEAI_VSO_CHART_PATH'), true)`.
Update `.env.example` accordingly. (Hardened chart still lives at
`charts/vso-hardened`.)

## 4. site.yml ordering

VSO needs cert-manager + OpenBao PKI (ClusterIssuer `openbao-pki`) ready, and
must precede every VSO consumer:

```
env_guard → system_update → helm → k3s → openbao → nginx_ingress (+ cert-manager)
  → vso            ← NEW
  → keycloak       (when keycloak_enabled)
  → beeai_agentstack_tofu   (transition only; until cutover removes it)
  → headlamp
  → readiness_check
```

Tag the role `vso` (and `vso_install`). Consumers gain a clean prerequisite:
`ansible-playbook … --tags vso` installs the operator alone.

## 5. beeai transition

- Delete the VSO install sub-block from
  [`beeai_agentstack_tofu/tasks/main.yml`](../../ansible/roles/beeai_agentstack_tofu/tasks/main.yml)
  (lines ~9-203) and its `templates/vso_kube_rbac_proxy_certificate.yaml.j2`.
- beeai keeps its credential generation, VaultConnection/Auth/StaticSecret, and
  chart apply — it now **consumes** the VSO that the `vso` role installed.
- beeai's `beeai_vso_*` defaults that only fed the operator install are removed;
  any it still references for its own VaultConnection (openbao addr, CA secret
  name, its SA/role) stay or point at the new `vso_*` equivalents.
- This is incremental: beeai still deploys during transition; only the operator
  install relocates. Full beeai removal remains the later cutover step.

## 6. Validation impact

Replaces the awkward "VSO is trapped in beeai" caveat from the Keycloak plan.
New clean sequence prefix:

```bash
# Install VSO operator standalone
ansible-playbook -i inventories/development/hosts.yml playbooks/site.yml --tags vso
sudo k3s kubectl get deploy -n vault-secrets-operator-system   # operator Available
# then keycloak_install as before
```

## 7. Risks / watch-items

1. **Idempotent re-deploy on a live VM.** The VM already has VSO (from beeai
   runs). The `vso` role's `helm upgrade --install` of the same release/namespace
   should adopt it cleanly; verify it does not fight Helm ownership metadata.
2. **`defaultVaultConnection`.** Chart creates a connection in the operator ns.
   Consumers use their own namespaced connections, so this is largely cosmetic —
   keep for parity, confirm no consumer accidentally depends on it by name.
3. **cert-manager / `openbao-pki` ClusterIssuer** must exist before `vso` runs
   (it does, via nginx_ingress + openbao roles). Ordering in §4 enforces this.
4. **CA secret duplication** (`openbao-ca` in vso ns + each consumer ns) is
   existing behavior, unchanged.
5. **Hardened chart requirement** stays enforced by the moved assert.

## 8. Out of scope

Full removal of `beeai_agentstack_tofu` (separate cutover step), and garrison.
