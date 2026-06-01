# Migration Plan — Remove OpenTofu, Deploy Helm Releases Natively

Status: proposed
Scope: replace OpenTofu as the Helm-release driver across all 4 roles that use it.
Goal: one source of release truth (Helm), drop tofu install + state files + state-drift cleanup.

## 1. Why

OpenTofu is used **only** as a thin wrapper around `helm_release`. No terraform-native
features are in play (no data sources, modules, remote state, `count`/`for_each`, outputs,
or providers beyond `helm`; the `kubernetes` provider declared in beeai `main.tf` is unused).

The only thing tofu adds over calling Helm directly is a **second state store**
(`.terraform/` + `terraform.tfstate`) layered on top of Helm's own release state
(release secrets in-cluster). The two disagree on re-runs, and the playbook already
spends ~150 lines fighting that drift (`helm uninstall` direct, `tofu state rm`,
manual StatefulSet/PVC deletion). Removing tofu removes the drift source.

### Inventory of tofu usage

| Role | Template(s) | Releases | Notes |
|------|-------------|----------|-------|
| `opentofu` | — | — | Installs `tofu` binary. Delete entirely. |
| `openbao` | `main.tf.j2` | `openbao` | values via `file()` (already a rendered `values.yaml`) |
| `nginx_ingress` | `main.tf.j2` | `certmanager`, `nginx_ingress` | 2 releases, `depends_on` ordering |
| `headlamp` | `main.tf.j2` | `headlamp` | values via `yamlencode(var.chart_values)` |
| `beeai_agentstack_tofu` | `main.tf.j2`, `vso_main.tf.j2` | `beeai_agentstack`, `vso` | beeai has 2-pass apply; VSO uses local hardened chart path |

## 2. Target approach

**Decision: `helm upgrade --install` via `ansible.builtin.command`.**

Rationale: zero new dependencies (helm already installed by the `helm` role; cleanup
tasks already shell out to `helm`), and matches the project's existing command-module
idiom (`k3s kubectl` everywhere). The repo has no `ansible.cfg`/`requirements.yml`.

Alternative considered: `kubernetes.core.helm` module — cleaner values handling (dict,
no temp file) and native idempotency, but adds a `kubernetes.core` collection +
`python3-kubernetes` dependency on the VM. Reject for now to keep the change dependency-free;
revisit as a follow-up once the tofu removal is proven.

### Flag mapping (tofu `helm_release` → helm CLI)

| `helm_release` arg | helm CLI equivalent |
|--------------------|---------------------|
| `name` / `namespace` | `<release> --namespace <ns>` |
| `create_namespace` | `--create-namespace` |
| `repository` + `chart` + `version` | `--repo <url> <chart> --version <v>` (or local path as chart ref) |
| `values = [yamlencode(...)]` | `-f <rendered values.yaml>` |
| `wait` | `--wait` |
| `timeout` (seconds) | `--timeout <N>s` |
| `atomic` | `--atomic` |
| `cleanup_on_fail` | `--cleanup-on-fail` |
| `upgrade_install = true` | `helm upgrade --install` (the verb itself) |
| `depends_on` | task ordering in the playbook |

### Reusable pattern (per release)

```yaml
- name: Render <X> Helm values
  ansible.builtin.template:        # or copy: for a dict built via set_fact
    src: values.yaml.j2
    dest: "{{ <x>_work_dir }}/values.yaml"
    mode: "0644"

- name: Deploy <X> via Helm
  ansible.builtin.command:
    cmd: >-
      helm upgrade --install {{ <x>_release_name }} {{ <x>_chart_name }}
      --namespace {{ <x>_namespace }}
      --create-namespace
      --repo {{ <x>_chart_repo }}
      {% if <x>_chart_version %}--version {{ <x>_chart_version }}{% endif %}
      -f {{ <x>_work_dir }}/values.yaml
      --wait --timeout {{ <x>_timeout_seconds }}s
      --kubeconfig {{ <x>_kubeconfig_path }}
      --output json
  register: _<x>_helm
  changed_when: >-
    (_<x>_helm.stdout | from_json).info.description | default('') != 'Upgrade complete'
    or 'STATUS: deployed' not in (_<x>_helm.stdout | default(''))
```

Notes:
- For a **local chart path** (VSO hardened chart, possibly beeai), drop `--repo` and pass
  the directory as the chart ref.
- `changed_when` can stay simple — Helm is idempotent; a no-op upgrade still returns 0.
  If precise change detection matters, diff `helm get values`/revision before+after, or
  accept "always changed" for these deploy tasks (low cost in this playbook).
- Values currently built as a **dict via `set_fact`** (headlamp, beeai) should be written
  to a temp `values.yaml` with `copy: content: "{{ x | to_nice_yaml }}"`, then `-f`'d.

## 3. Per-role steps

### 3.1 `opentofu` role — DELETE
- Remove `ansible/roles/opentofu/` entirely (tasks/defaults/meta/README, 104-line tasks).
- Remove `- role: opentofu` block from `ansible/playbooks/site.yml` (lines 19–22).
- Remove the `opentofu`/`tofu_install` tags references.
- Grep for `tofu` / `opentofu` across `defaults/` and `meta/` to catch leftover vars
  (`*_tofu_work_dir`, `*_tofu_chart_values`, etc. — rename to `*_work_dir` /
  `*_chart_values` or leave var names, just stop rendering `.tf`).

### 3.2 `openbao` role
File: `tasks/install.yml`
- DELETE: "Render OpenTofu configuration" (renders `main.tf`), "Render OpenTofu variables
  file" (tfvars), "Initialize OpenTofu", "Deploy OpenBao via OpenTofu helm provider"
  (lines ~2–15, 217–274).
- KEEP: existing "Render OpenBao Helm values" → `values.yaml` (already produced).
- ADD: one `helm upgrade --install openbao` task using that `values.yaml` (`-f`),
  `--wait --timeout 300s`, `--repo {{ openbao_chart_repo }}`.
- DELETE template: `templates/main.tf.j2`.
- Everything after the deploy (pod recreate, CRB, readiness waits) is plain kubectl —
  unchanged.

File: `tasks/teardown.yml`
- Replace "Check if OpenBao OpenTofu state exists" + "Destroy ... via OpenTofu" with
  `helm uninstall {{ openbao_release_name }} -n {{ openbao_namespace }} --ignore-not-found`.

### 3.3 `nginx_ingress` role
File: `tasks/install.yml`
- DELETE tofu workdir/render/tfvars/init/apply tasks (lines ~6–100).
- ADD two ordered `helm upgrade --install` tasks (cert-manager first, then nginx) to
  preserve the old `depends_on`. Use `certmanager_tofu_chart_values` /
  `nginx_tofu_chart_values` → temp values files; timeouts from
  `certmanager_tofu_timeout_seconds` / `nginx_tofu_timeout_seconds`.
- KEEP: "Wait for cert-manager webhook" + firewall tasks — unchanged. (The webhook wait
  already guards ordering; keep it between the two helm installs as today.)
- DELETE template: `templates/main.tf.j2`.

File: `tasks/teardown.yml` — swap both `tofu destroy` for two `helm uninstall`.

### 3.4 `headlamp` role
File: `tasks/deploy.yml`
- KEEP everything up to and including "Build Headlamp chart values payload"
  (`_headlamp_chart_values` set_fact) — that dict is the values source.
- DELETE: "Ensure Headlamp OpenTofu working directory", "Render OpenTofu configuration",
  "Render OpenTofu variables file", "Initialize OpenTofu", "Deploy Headlamp via OpenTofu"
  (lines ~169–283).
- ADD: write `_headlamp_chart_values | to_nice_yaml` to `values.yaml`, then
  `helm upgrade --install headlamp ... --timeout 600s -f values.yaml`.
- KEEP: OIDC resolver IP lookup + hostAlias patch + rollout wait (post-deploy) — unchanged.
- DELETE template: `templates/main.tf.j2`.

### 3.5 `beeai_agentstack_tofu` role  (biggest, do last)
This role is 1898 lines; the tofu pieces are a minority but tangled with a 2-pass apply.

VSO sub-deploy (`tasks/main.yml` lines ~54–288):
- DELETE: VSO workdir, render `vso_main.tf`, render VSO tfvars, `tofu init`, `tofu apply`.
- ADD: build VSO values dict (already assembled inline in the tfvars `content:`), write to
  `values.yaml`, `helm upgrade --install {{ beeai_vso_release_name }}` with the hardened
  chart. Chart ref = `beeai_vso_chart_path` (local dir) when set, else
  `--repo {{ beeai_vso_chart_repo }} {{ beeai_vso_chart_name }} --version ...`.
- DELETE template: `templates/vso_main.tf.j2`.

BeeAI main deploy (the 2-pass flow, lines ~693–1808):
- The "effective chart values" set_fact (`beeai_tofu_effective_chart_values`) stays — write
  it to `values.yaml`.
- DELETE: "Ensure BeeAI OpenTofu working directory", "Render OpenTofu configuration",
  "Render OpenTofu variables file", `tofu init`, first `tofu apply`, the second-pass tfvars
  rewrite, second `tofu apply`.
- Stale-release cleanup block (lines ~858–1053): this exists to reconcile tofu state vs
  Helm. With tofu gone, **simplify drastically** — `helm upgrade --install` is itself the
  reconcile. Keep only the genuinely-needed PostgreSQL PVC reset (the chart can't rotate the
  PG password in place), drop `tofu state list` / `tofu state rm` / the direct
  `helm uninstall` stale path. Net: ~100 lines removed here.
- Two-pass logic becomes two `helm upgrade --install` calls:
  1. first install with `--timeout {{ beeai_tofu_timeout_seconds }}s` (non-atomic, so the
     Keycloak StatefulSet survives for patching — matches current behavior),
  2. Keycloak `KC_HOSTNAME_STRICT` + startup-probe patch (unchanged kubectl patch),
  3. second `helm upgrade --install` with `--timeout {{ beeai_tofu_post_patch_timeout_seconds }}s`
     guarded by the same `helm release status != deployed` check that exists today
     (it already reads the release secret directly via kubectl — no tofu needed).
- KEEP unchanged: all the kubectl patches (UI/API OIDC), keycloak_oidc_fix include, ingress
  apply, credential reconciliation.
- DELETE templates: `templates/main.tf.j2`.

File: `tasks/teardown.yml` — replace both `tofu destroy` with `helm uninstall` for
`beeai_agentstack` and `vso` (the playbook already deletes namespaces/PVCs separately).

## 4. Cross-cutting cleanup
- `ansible/playbooks/teardown_k3s_workloads.yml` — audit for tofu references.
- `defaults/main.yml` in each role — rename/remove `*_tofu_*` vars; keep chart repo/name/
  version/timeout vars (now consumed by helm directly).
- Role READMEs (`opentofu`, `*_tofu`) — update or delete; consider renaming role
  `beeai_agentstack_tofu` → `beeai_agentstack` (optional, touches site.yml + meta deps).
- `doc/current_state_*.md` — note the deploy mechanism change.

## 5. Sequencing (low-risk order)
1. **openbao** — simplest single release, `values.yaml` already rendered. Prove the pattern.
2. **headlamp** — single release, values as dict. Validates the dict→`values.yaml` path.
3. **nginx_ingress** — 2-release ordering + webhook wait.
4. **beeai** — 2-pass + cleanup simplification. Do last, most surface area.
5. Delete `opentofu` role + site.yml block once all four are converted and green.
6. Update teardown playbook + READMEs + docs.

Convert and validate **one role per PR** (or per `vagrant up --provision` cycle with that
role's tag). Don't big-bang all four.

## 6. Validation per role
- Greenfield: `vagrant destroy -f && vagrant up` → role deploys clean (no prior tofu state).
- Idempotency: re-run `ansible-playbook ... --tags <role>` → second run shows the release
  already `deployed`, no errors.
- In-place adopt: on a VM that previously deployed via tofu, run the converted role →
  `helm upgrade --install` should adopt the existing release (Helm owns the release secret
  regardless of tofu). Confirm no duplicate release / no orphaned resources. **Test this
  once on beeai specifically** (most complex release).
- Teardown: `ansible-playbook teardown_k3s_workloads.yml` → `helm uninstall` removes the
  release; namespaces/PVCs cleaned as before.
- Run the existing `readiness_check` role after each conversion — it's the end-to-end gate.

## 7. Expected outcome
- Delete: `opentofu` role (104 lines) + 5 `.tf.j2` templates + ~10 tfvars/init/apply task
  pairs + tofu state-drift cleanup (~100 lines in beeai). Rough net **−300 to −400 lines**.
- Remove `tofu init` (provider download) from every run → faster playbook (backlog: profile
  execution times).
- One release state model (Helm). No `.terraform`/`tfstate` on the VM.
- No new runtime dependency (helm CLI only, already present).

## 8. Risks / watch-outs
- **Change detection**: `helm upgrade --install` is harder to mark `changed`/`ok` precisely
  than `tofu apply`'s "0 added/changed/destroyed" string. Acceptable for deploy tasks;
  tighten later if needed.
- **beeai non-atomic first pass**: current flow relies on the first apply NOT being atomic so
  the half-up Keycloak StatefulSet stays patchable. Preserve by omitting `--atomic` on pass 1.
- **Local chart refs** (VSO hardened chart): pass directory as chart ref, no `--repo`.
- **In-place adoption** is the one genuinely novel path — validate before rolling to any
  long-lived environment. Fresh `vagrant up` is unaffected.
