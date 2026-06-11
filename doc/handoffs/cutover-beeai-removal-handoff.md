# Cutover Handoff — Keycloak Teardown + Final BeeAI Removal

> **ARCHIVED — executed. Kept for history; do not follow as current
> instructions.** Durable rationale lives in [../decisions/](../decisions/).

Status: ready for implementation (handoff to Copilot)
Scope: (A) add a teardown path to the `keycloak` role; (B) remove the
`beeai_agentstack_tofu` role and all armory-side BeeAI/Agent Stack coupling now
that Keycloak is standalone.
Preconditions: the standalone `vso` + `keycloak` roles exist and are wired into
`site.yml`; `keycloak_enabled: true` is set in
`inventories/development/group_vars/all.yml`; `nginx_ingress_tls_namespace` is
already set to `keycloak` (the `armory-tls` cert lands in the Keycloak namespace).
Companions: [`keycloak-operator-implementation-plan.md`](keycloak-operator-implementation-plan.md),
[`vso-extraction-plan.md`](vso-extraction-plan.md),
[`agentstack-keycloak-reqs-for-garrison.md`](../agentstack-keycloak-reqs-for-garrison.md).

## How to use this doc (Copilot)
Execute the tasks in order. Each task lists exact files and the change. After
each phase, run the validation in §6. Do **not** invent new abstractions; match
existing role conventions. Ask before deviating. No manual cluster prereqs are
needed — `ansible-playbook playbooks/site.yml` resolves all ordering/deps.

---

## A. Keycloak teardown

### A1. Create `ansible/roles/keycloak/tasks/teardown.yml`
Mirror the convention in
[`beeai_agentstack_tofu/tasks/teardown.yml`](../../ansible/roles/beeai_agentstack_tofu/tasks/teardown.yml)
and [`vso/tasks/teardown.yml`](../../ansible/roles/vso/tasks/teardown.yml): register
the namespace for the framework's namespace sweep, then delete custom resources
and the operator. Delete CRs **before** the namespace so operator finalizers
clear. Suggested contents:

```yaml
---
- name: Register Keycloak namespace for teardown checks
  ansible.builtin.set_fact:
    teardown_role_target_namespaces: >-
      {{ (teardown_role_target_namespaces | default([])) + [keycloak_namespace] | unique }}

- name: Delete KeycloakRealmImport (ignore if absent)
  ansible.builtin.command:
    cmd: >-
      k3s kubectl delete keycloakrealmimport {{ keycloak_realm }}-realm
      -n {{ keycloak_namespace }} --ignore-not-found
  environment: { KUBECONFIG: "{{ keycloak_kubeconfig_path }}" }
  register: _kc_td_realm
  changed_when: "'deleted' in (_kc_td_realm.stdout | default(''))"
  failed_when: false

- name: Delete Keycloak custom resource (ignore if absent)
  ansible.builtin.command:
    cmd: >-
      k3s kubectl delete keycloak {{ keycloak_cr_name }}
      -n {{ keycloak_namespace }} --ignore-not-found --timeout=120s
  environment: { KUBECONFIG: "{{ keycloak_kubeconfig_path }}" }
  register: _kc_td_cr
  changed_when: "'deleted' in (_kc_td_cr.stdout | default(''))"
  failed_when: false

- name: Delete Keycloak Operator (ignore if absent)
  ansible.builtin.command:
    cmd: >-
      k3s kubectl delete -n {{ keycloak_namespace }}
      -f {{ keycloak_k8s_resources_base_url }}/kubernetes.yml --ignore-not-found
  environment: { KUBECONFIG: "{{ keycloak_kubeconfig_path }}" }
  register: _kc_td_operator
  changed_when: "'deleted' in (_kc_td_operator.stdout | default(''))"
  failed_when: false
```
Notes:
- Leave the cluster-scoped CRDs in place by default (deleting them cascades to any
  other Keycloak CRs cluster-wide). If a full purge is wanted, add an explicit,
  separately-gated task — do not delete CRDs implicitly.
- PostgreSQL PVC, secrets, and the ingress live in `keycloak_namespace`; the
  framework's namespace deletion (k3s `teardown_workloads`) removes them.

### A2. Wire into `ansible/playbooks/teardown_k3s_workloads.yml`
Add a keycloak teardown include. Order it **before** the `vso` teardown (Keycloak
consumes VSO) and before openbao:
```yaml
    - name: Run Keycloak teardown tasks
      ansible.builtin.include_role:
        name: keycloak
        tasks_from: teardown
      when: keycloak_enabled | default(false) | bool
```
Place it directly after the BeeAI teardown include (which will be removed in §B)
— i.e. it becomes the first workload teardown once BeeAI is gone.

---

## B. Final BeeAI removal

### B1. Delete the role and its references
- **Delete directory** `ansible/roles/beeai_agentstack_tofu/` entirely. This
  removes `keycloak_oidc_fix.yml` (the Agent-Stack audience fix), the agentstack
  ingress/VSO templates, and `teardown.yml`. (That audience-fix logic is already
  captured for garrison in
  [`agentstack-keycloak-reqs-for-garrison.md`](../agentstack-keycloak-reqs-for-garrison.md).)
- **`ansible/playbooks/site.yml`** — remove the `beeai_agentstack_tofu` role block
  (the `- role: beeai_agentstack_tofu` entry and its `tags`).
- **`ansible/playbooks/teardown_k3s_workloads.yml`** — remove the
  "Run BeeAI teardown tasks" include.

### B2. Readiness role
- **Delete** `ansible/roles/readiness_check/tasks/check_beeai.yml`.
- **`readiness_check/tasks/main.yml`** — remove the `check_beeai.yml` include block.
- **`readiness_check/defaults/main.yml`** — remove `readiness_check_beeai_enabled`
  and all `readiness_check_beeai_*` settings. Keep the keycloak ones.
- **`readiness_check/templates/readiness_report.j2`** — remove any BeeAI-specific
  rendering branches.
- **`readiness_check/README.md`** — drop BeeAI references; keep Keycloak.

### B3. Consumer fallback cleanups (remove dead `beeai_*` branches)
These roles still carry `beeai_*` fallback expressions that are now dead (and
reference vars that will no longer exist). Simplify each to the standalone value:
- **`headlamp/defaults/main.yml`** — the keycloak coordinate vars currently read
  `… if headlamp_keycloak_enabled else (beeai_… | default(...))`. With BeeAI gone
  the `else` branch is dead. Either keep `headlamp_keycloak_enabled` defaulting to
  `true` and drop the `beeai_*` fallbacks, or hardcode the standalone values.
  Result must not reference any `beeai_*` var.
- **`k3s/defaults/main.yml`** — `k3s_oidc_issuer_url` realm ternary: drop the
  `agentstack` branch; realm is `armory`.
- **`readiness_check/defaults/main.yml`** — the `readiness_check_keycloak_*`
  vars' `else 'agentstack'/'keycloak-secret'` branches become dead; simplify.
- Grep gate (must return nothing): `grep -rn "beeai" ansible/roles/{headlamp,k3s,readiness_check}`.

### B4. OpenBao role — decouple BeeAI credential provisioning
OpenBao currently generates and stores BeeAI/Agent-Stack secrets and a BeeAI VSO
policy/role. None of this is needed by armory after removal (Keycloak and Headlamp
each create their own OpenBao policy + k8s auth role at runtime; the Keycloak DB
password is generated by the `keycloak` role).
- **Delete** `ansible/roles/openbao/tasks/credentials.yml` (generates
  `secret/beeai/credentials` + `secret/beeai/encryption-key`, all Agent-Stack
  shaped).
- **`openbao/tasks/main.yml`** — remove the "BeeAI credentials in OpenBao" include
  block (tags `[openbao, openbao_credentials, beeai]`).
- **`openbao/tasks/configure.yml` (lines ~216-270)** — remove the BeeAI VSO policy
  (`secret/data/beeai/*`) and the k8s auth role bound to `openbao_beeai_namespace`
  / `openbao_vso_sa_name`.
  **CRITICAL:** verify the Kubernetes auth *method enable* and `auth/kubernetes/config`
  are **outside** this block (they must remain — keycloak/headlamp roles create
  their own roles under the existing method). Only remove the BeeAI-specific
  policy + role, not the auth-method enablement.
- **`openbao/defaults/main.yml`** — remove `openbao_beeai_namespace` and
  `openbao_vso_sa_name` (and any other `*beeai*` defaults).
- **`openbao/meta/main.yml`** + **`openbao/README.md`** — drop BeeAI wording.

### B5. Environment + top-level docs
- **`.env.example`** — remove `BEEAI_ADMIN_EMAIL` (Keycloak realm-admin email is
  `ARMORY_ADMIN_EMAIL`, already defaulted in the keycloak role). Confirm no other
  `BEEAI_*` remain.
- **`README.md` (top level)** — rewrite the BeeAI/Agent Stack sections: role list,
  the `--tags beeai_*` command examples, the credential-retrieval snippets
  (`agentstack` namespace / `beeai-credentials` / `keycloak-secret`), and the
  access/login sections. Replace with the standalone Keycloak equivalents
  (ns `keycloak`, `keycloak-initial-admin`, realm `armory`, `--tags vso` /
  `keycloak_install`). See the credential map below.
- **`doc/migration_opentofu_to_helm.md`** — historical; leave as-is (it documents
  a past migration). Optionally add a one-line note that beeai has since moved to
  garrison.

### B6. Credential map after removal (for README rewrite)
| Purpose | Where |
|---|---|
| Keycloak master admin | secret `keycloak-initial-admin` (ns `keycloak`), keys `username`/`password` |
| Realm `armory` admin (Headlamp login) | OpenBao `secret/keycloak/realm-admin`, key `password` |
| Keycloak DB | OpenBao `secret/keycloak/db` → VSO → secret `keycloak-db-secret` |

---

## 6. Validation (single full run — no manual prereqs)

The playbook handles all ordering and dependencies. With `keycloak_enabled: true`
globally and BeeAI removed:

```bash
cd /vagrant/project-armory/ansible          # .env sourced → inventory + become auto
ansible-playbook --syntax-check playbooks/site.yml
ansible-playbook playbooks/site.yml          # full converge: …→ vso → keycloak → headlamp → readiness
```

Gates (operator gives real status; HTTP is secondary):
```bash
sudo k3s kubectl rollout status deploy/vault-secrets-operator -n vault-secrets-operator-system
sudo k3s kubectl rollout status statefulset/postgres -n keycloak
sudo k3s kubectl wait --for=condition=Ready   keycloak/keycloak           -n keycloak --timeout=900s
sudo k3s kubectl wait --for=condition=Done     keycloakrealmimport/armory-realm -n keycloak --timeout=900s
sudo k3s kubectl get secret armory-tls -n keycloak     # shared cert present in keycloak ns
curl -sk https://armory.local/realms/armory/.well-known/openid-configuration | head -c 200; echo
```
End-to-end: Headlamp login as realm `admin` (password from OpenBao
`secret/keycloak/realm-admin`) → OIDC round-trip → `kubectl get nodes` works
(RBAC bound by `<issuer>#admin`, [headlamp/rbac.yml](../../ansible/roles/headlamp/tasks/rbac.yml)).

Teardown check:
```bash
ansible-playbook playbooks/teardown_k3s_workloads.yml -e teardown_confirm=true
# expect: keycloak CRs deleted, operator removed, ns keycloak + vault-secrets-operator-system swept
```

## 7. Final grep gates (must all return nothing)
```bash
grep -rni "beeai"            ansible/ .env.example          # no references in code/env
grep -rn  "agentstack"       ansible/roles/{k3s,headlamp,readiness_check,nginx_ingress,openbao}
grep -rn  "beeai_agentstack_tofu" ansible/
```
(Historical `doc/` files may retain references; code/config must be clean.)

## 8. Out of scope
Garrison build (separate project). The `doc/agentstack-keycloak-reqs-for-garrison.md`
already carries everything Agent Stack needs against the external Keycloak.
