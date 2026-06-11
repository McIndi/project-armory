# Simplification & Refactor Opportunities

Status: analysis (not scheduled — candidates for prioritization)
Scope: armory Ansible codebase. Opportunities **not** already planned/underway
(excludes: keycloak teardown, beeai removal, vso extraction, garrison — those are
covered in their own docs).
Goal: reduce hand-rolled glue where k3s / cert-manager / Keycloak / VSO / Helm
already provide the capability; cut duplication; improve grokability.

## Decision record (2026-06-08)

- Implemented: new `trust_manager` role and staged declarative CA distribution
   toggle path (`trust_manager_enabled`, `use_declarative_ca_distribution`).
- Implemented: Keycloak -> Postgres TLS wiring with verify-full defaults behind
   `keycloak_pg_tls_enabled` rollout toggle.
- Implemented: explicit ingress HTTP profile toggle
   (`ingress_http_policy=redirect-only|disabled`) with policy-aware readiness
   assertions.
- Rollback controls: switch the three toggles back to compatibility defaults
   without reverting unrelated code.

## Measured repetition (basis for the recommendations)
Counts from the current tree (`ansible/roles`):

| Pattern | Count | Notes |
|---|---|---|
| `kubectl apply -f -` command tasks | 31 | each needs a hand-written `changed_when` |
| `changed_when: "'created'/'configured' in stdout"` | 54 | brittle stdout string-matching |
| `helm upgrade --install` via `command` | 9 | values rendered to temp files |
| namespace `create --dry-run=client \| apply` two-step | 3 | one per workload role |
| VSO per-consumer templates (`vault{connection,auth,staticsecret}`) | 9 | 3 consumers × 3 |
| OpenBao CA-copy dance touch points | 4 ns | vso, keycloak, beeai, headlamp |
| `no_log: "{{ not (armory_log_nolog ...) }}"` | 87 | per-task duplication |
| `Resolve ARMORY_LOG_NOLOG flag` set_fact | 11 roles | duplicated role preamble |

---

## High impact

### 1. CA distribution → cert-manager `trust-manager`
**Now:** every VSO consumer copies the OpenBao CA into its namespace via a ~6-task
dance — read `openbao-ca` from ns `openbao`, write `/tmp/openbao-ca-*.crt`,
`kubectl create secret --dry-run | apply`, delete tmp — repeated for vso,
keycloak, beeai, headlamp.
**Better:** deploy `trust-manager` (cert-manager subproject; cert-manager already
in-cluster). Declare one `Bundle` that distributes the OpenBao CA to all (or
label-selected) namespaces automatically. New namespaces get it for free.
**Win:** deletes the tmp-file juggling and ~6 tasks × 4 namespaces; declarative;
standard. **Cost:** one extra small controller. **Risk:** low, isolated.

### 2. `command: kubectl/helm` → `kubernetes.core` modules
**Now:** 31 `kubectl apply -f -`, 54 stdout-grep `changed_when`, 9 `helm` shell
calls, 3 namespace dry-run two-steps. All a consequence of the deliberate
dependency-free choice in
[`migration_opentofu_to_helm.md` §2](handoffs/migration_opentofu_to_helm.md)
(*"revisit … once the tofu removal is proven"* — it is now proven).
**Better:** `kubernetes.core.k8s` (apply manifests/dicts, real idempotency + diff,
`state: present` for namespaces) and `kubernetes.core.helm` (values as dicts, no
temp `values.yaml`). Removes all 54 hand-written `changed_when` greps and the
namespace two-steps.
**Win:** largest single grok improvement; real change/diff reporting; less brittle.
**Cost:** adds `kubernetes.core` collection + `python-kubernetes` on the VM
(`requirements.yml`). **Risk:** medium — touches every role; do deliberately,
after the beeai cutover settles. This is the "revisit" the migration doc deferred.

### 3. One parameterized VSO-consumer helper
**Now:** the per-consumer VSO wiring — ServiceAccount + VaultConnection +
VaultAuth + VaultStaticSecret + OpenBao ACL policy + k8s auth role — is duplicated
across keycloak, headlamp, beeai (9 near-identical templates + repeated tasks).
**Better:** a `vso_consumer` role (or `include_role` task-file) taking
`(namespace, service_account, openbao_role, openbao_policy, kv_path, dest_secret,
secret_keys)`. One generic template set + one task file; consumers pass vars.
**Win:** 9 templates → 1 generic; single place to change VSO wiring. Complements
the freshly-extracted `vso` role. **Risk:** low-medium; mechanical.

---

## Medium impact

### 4. Local Helm chart for the Keycloak stack
**Now:** the `keycloak` role applies four separate manifests via kubectl
(`postgres.yaml.j2`, `keycloak.yaml.j2`, `realmimport.yaml.j2`, `ingress.yaml.j2`)
plus the operator install + a post-apply deployment patch.
**Better:** bundle the four declarative objects into `charts/keycloak-stack`,
rendered with values once → single `helm upgrade --install`.
**Win:** atomic apply + rollback; `helm uninstall` becomes the teardown (resolves
the still-pending keycloak teardown role); one values source of truth.
**Keep out of the chart:** the operator install (upstream manifests) and anything
imperative (OpenBao bootstrap/unseal, secret seeding) — those stay in Ansible.
**Do not** over-reach to a full umbrella chart; the imperative bootstrap doesn't
belong in Helm. **Risk:** low-medium.

### 5. Re-home the k3s API-server OIDC wiring
**Now:** k3s apiserver OIDC is configured from the **headlamp** role
(`headlamp/tasks/k3s_oidc_configure.yml`, tag `k3s_oidc`), while the `k3s` role
writes partial issuer config early and gates the enable behind
`k3s_oidc_ca_configured`. Two-phase, split across two roles, surprising location.
**Better:** move the apiserver OIDC config into the `k3s` role, ordered/tagged to
run **after** keycloak (the IdP must exist first). "k3s OIDC lives in the k3s
role, after the IdP" is far more grokkable than finding it inside headlamp.
**Win:** removes a genuine "where is this even configured?" wart. **Risk:** medium
— ordering-sensitive (needs realm + OIDC CA available); test the OIDC CA timing.

---

## Low impact / cheap wins

### 6. Hoist `armory_log_nolog`
Re-`set_fact`'d at the top of 11 roles; define once in `group_vars/all`. (The 87
per-task `no_log` expressions can't be DRY'd individually, but the 11 duplicate
preambles go.) **Risk:** trivial.

### 7. headlamp Keycloak client → declarative (conditional)
The ~270-line imperative GET/PUT/POST `headlamp/tasks/oidc_client.yml` could become
a client entry in the `armory` realm import now that the operator owns realm
import. **Tradeoff:** `KeycloakRealmImport` update/overwrite semantics (the reason
it's currently REST) + client-secret generation still needs an imperative step.
**Only** pursue once realm-import update behavior is verified safe. Partial win.

### 8. cert-manager Certificate template consolidation
Three near-identical `Certificate` templates (nginx_ingress, headlamp, vso).
Minor: a shared cert task/template parameterized by name/ns/dnsNames/issuer.
Low priority.

---

## Suggested sequence
1. **trust-manager (#1)** — isolated, high clarity, low risk.
2. **vso_consumer helper (#3)** — builds on the new `vso` role.
3. **keycloak-stack chart (#4)** — also delivers clean teardown.
4. **`kubernetes.core` migration (#2)** — biggest win, but the dependency decision
   + touches every role; schedule after the beeai cutover lands.
5. **k3s OIDC re-home (#5)**, then cheap wins **#6/#8** anytime.

## Explicitly out of scope here
Items already planned/underway: keycloak teardown role, final beeai removal,
VSO extraction (done), garrison build, the Keycloak operator/server startup-probe
tuning (in progress).
