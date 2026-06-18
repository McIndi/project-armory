# Handoff: `kubernetes.core` Migration + Idempotency Restoration

Status: Stages 0–2 complete (Helm track done, cause #1 closed) · Stage 3 next · Owner: Copilot · Drafted: 2026-06-17
Status: Stages 0–3 complete · Stage 4 code done, static validation in progress · Owner: Copilot · Drafted: 2026-06-17

## Goal

Restore run-to-run idempotency by migrating `ansible.builtin.command` (`helm` /
`kubectl`) to `kubernetes.core.*`, staged to minimize the context each change
requires. Two non-idempotent areas remain after the OpenBao PKI/TLS fix:

1. **Helm release churn** — all six `helm upgrade --install` calls advance their
   revision (1 → 2) and report `changed` on every run. **✅ Resolved (Stages 1–2):
   all six now no-op via `kubernetes.core.helm` + helm-diff.**
2. **Keycloak churn** — the operator Deployment ping-pongs (apply upstream →
   re-patch) and the `keycloak-0` StatefulSet pod restarts on reruns.

## Evidence (snapshot diff: `run-snapshot-20260617T114721Z` vs `…122929Z`)

| Signal | Run 1 | Run 2 | Verdict |
|---|---|---|---|
| OpenBao pod UID / start | `a86e638b…` / 10:33 | identical | stable (prior fix holds) |
| openbao-ca / server-tls hashes | `465c4e…` / `aaa70e…` | identical | stable |
| Helm revisions (all 6 releases) | `1` | `2` | churn — cause #1 |
| Keycloak pod UID / start | `697fea81…` / 10:22 | `0f8208d1…` / 12:07 | restarted — cause #3 |
| Keycloak operator ReplicaSet | `59dc6cddfc` | `867f777449` created→0→1→0→deleted, back to `59dc…` | ping-pong — cause #2 |

## Root causes

- **#1 Helm:** every component role runs a bare `helm upgrade --install … --wait`
  with hardcoded `changed_when: true`. `helm upgrade` records a new revision even
  when the rendered manifests are byte-identical; `changed_when: true` forces a
  changed report. Release-layer churn, not (mostly) workload churn.
- **#2 Operator ping-pong:** `keycloak/tasks/main.yml:397` applies the *unpatched*
  upstream `kubernetes.yml`, then `:415` patches the startup probe + CPU limit.
  Each rerun the apply reverts the prior patch (new RS), then the patch re-applies
  it (rolls back) — two operator rollouts per run.
- **#3 StatefulSet restart:** `keycloak-0` is recreated cascading from the operator
  restart re-reconciling the CR; secondary suspect is VSO re-syncing
  `keycloak-db-sync` / `keycloak-realm-admin-sync` (events show `SecretSynced`
  immediately before the kill) bumping Secret resourceVersions the StatefulSet
  references. Passwords are already read-once-and-reused (`main.yml:50–155`), so
  the target is resourceVersion churn, not value churn.

## Preconditions in the repo today

- **No `requirements.yml`, no `ansible-galaxy` install in provisioning, and
  `kubernetes.core` is NOT installed** (only referenced in `galaxy_tags`). The
  dependency-free posture is deliberate (`doc/handoffs/migration_opentofu_to_helm.md`
  §2); revisiting it is now sanctioned (`doc/simplification-opportunities.md` #2).
- Ansible runs inside the Vagrant VM (`vagrant ssh`, repo at `/vagrant`).
- Per `backlog.md`: **do not pin versions during dev** — install latest upstream.

## Global rules for every stage

**Division of responsibility — agents do NOT run the playbook.** The implementing
agent's job ends at *static* validation: code edits, `ansible-playbook
--syntax-check`, and `ansible-lint -c .ansible-lint`. Agents must **not** run
`ansible-playbook playbooks/site.yml` (or any role apply) against the VM, and must
not run `capture_run_snapshot.sh` — full runs are slow and not a good use of agent
tokens. The agent hands off "ready for verification"; the **maintainer** owns
running the playbook and the two-run idempotency check.

- Agents keep `ansible-lint -c .ansible-lint` and `ansible-playbook --syntax-check
  playbooks/site.yml` green (both are static — no cluster contact).
- **Maintainer-owned acceptance gate** (every "Verify" section below describes
  this, not an agent task): run the stage, capture with
  `ansible/scripts/capture_run_snapshot.sh`, do an immediate no-op rerun, capture
  again, diff. A stage is **done** only when its targeted resources show no churn
  (stable revisions / pod UIDs) on the second run. Agents surface what to look
  for; they do not execute it.
- The `kubernetes.core.helm` module needs the **`helm-diff`** plugin for accurate
  no-op detection; `kubernetes.core.k8s` needs the **`kubernetes` Python library**.

---

## Stage 0 — Bootstrap prerequisites + decisions (no behavior change) — ✅ complete

Smallest possible diff; everything else depends on it. This stage also resolves
the two policy/plumbing decisions the conversion hinges on, so later stages stay
purely mechanical.

**In scope — dependencies:**
- New `ansible/requirements.yml` with `collections: [kubernetes.core]` (unpinned).
- `Vagrantfile` provision shell: `ansible-galaxy collection install -r
  ansible/requirements.yml` and the Python `kubernetes` lib (required by the `k8s`
  module, **not** the `helm` module). Install it **system-wide / root-importable**
  (e.g. dnf `python3-kubernetes`), **not** `pip install --user` as `vagrant`: tasks
  run under global `ANSIBLE_BECOME=True`, so the module's interpreter is root's
  `/usr/bin/python3` and a per-user install is invisible (this bit Stage 3). The
  `Vagrantfile` is gitignored by repo convention; the VM's provisioning contract
  (resources + installed prerequisites) is documented in the tracked `README.md`.
- `ansible/roles/helm/tasks/main.yml`: after the binary install, install the
  `helm-diff` plugin idempotently (`helm plugin list` → install when absent; use
  `--verify=false` — the plugin source fails Helm's signature verification).

**In scope — supersede ADR 0006 (the "wholesale" clause blocks this plan):**
- `doc/decisions/0006-defer-kubernetes-core.md` ends with *"When the migration
  happens it should be wholesale, not mixed per-role."* This plan is deliberately
  staged/per-role with a transitional mixed state. Write **ADR 0008** that
  supersedes that clause: bless staged per-role conversion (per-role de-risks the
  kubeconfig/dependency/field-manager plumbing before any apply path is touched),
  and record that ADR 0001 (dependency-free) / 0005 (track-latest) are now
  satisfied enough to take the `kubernetes.core` + `python3-kubernetes` dependency.
- Mark ADR 0006 `Status: superseded by 0008`.
- Update `AGENTS.md` to (a) state the transitional mixed idiom is expected and
  which idiom new tasks use, and (b) define the **residual `command` allowlist** —
  `rollout restart`, `rollout status`, `create token`, `cluster-info`, and
  `exec`→`k8s_exec` have no clean module mapping and stay `command`. End state is
  ~90% modules + this documented remainder, not 100%.

**In scope — kubeconfig/auth contract for `kubernetes.core` tasks:**
- `command` tasks reach the cluster via global `ANSIBLE_BECOME=True` (`.env`)
  escalating to root, which can read the root-owned `0600`
  `/etc/rancher/k3s/k3s.yaml`. **`kubernetes.core` modules cannot rely on this:**
  they read file args (`kubeconfig`) in a controller-side action plugin as the
  unprivileged `vagrant` user *before* escalation, so a root-only kubeconfig fails
  with `[Errno 13] Permission denied` even under global become (confirmed in
  Stage 1 — see ADR 0008 "Why not `become: true`").
- **Resolution (implemented + validated):** make the canonical kubeconfig itself
  group-readable by `vagrant` via the k3s installer env in
  `roles/k3s/tasks/install.yml` — `K3S_KUBECONFIG_MODE: "0640"` and
  `K3S_KUBECONFIG_GROUP: "vagrant"`, leaving `/etc/rancher/k3s/k3s.yaml` as
  `root:vagrant 0640`. k3s re-applies these every time it (re)writes the file, so
  it stays correct durably across restarts. Exposure is `{root, vagrant}` — no
  broader than a private copy. Chosen over copying the file to
  `~vagrant/.kube/config`: one versioned, authoritative source of truth with no
  stale-copy footgun. **Every** `kubernetes.core.*` task sets `kubeconfig:` to
  `/etc/rancher/k3s/k3s.yaml` (directly or via `k3s_kubeconfig_path`); **no
  `become:`**. Legacy `command` tasks keep using the same path via global become
  until migrated. NB: the installer env only lands on a **clean** k3s install, so
  it applies via teardown/rebuild, not an in-place rerun.

**Do not touch:** any role's `command:` tasks.

**Gating:** `helm-diff` + collection unblock Stages 1–2; the `kubernetes` Python
lib + the kubeconfig/auth decision unblock Stage 3+.

**Verify:** `ansible-galaxy collection list | grep kubernetes.core`;
`python3 -c "import kubernetes"` (as the `vagrant` runtime user, not just root);
`helm plugin list | grep diff`; ADR 0008 written and 0006 marked superseded;
AGENTS.md residual-command allowlist present; `README.md` documents the VM
resource + prerequisite requirements provisioned by Vagrant.

---

## Stage 1 — Helm module pilot on one leaf role (`cert_manager`) — ✅ complete

Prove the `kubernetes.core.helm` pattern on the simplest role before fanning out.

**In scope — `ansible/roles/cert_manager/tasks/install.yml` only:**
- Replace the `helm upgrade --install` `command` (~line 21) with
  `kubernetes.core.helm`: `release_name`, `chart_ref` + `chart_repo_url`,
  `release_namespace`, `create_namespace: true`,
  `values_files: [.../cert-manager-values.yaml]` (keep the rendered file),
  `wait: true`.
- **`kubeconfig` (auth contract):** `/etc/rancher/k3s/k3s.yaml` — made
  group-readable by `vagrant` via the k3s `K3S_KUBECONFIG_MODE: "0640"` /
  `K3S_KUBECONFIG_GROUP: "vagrant"` installer env (see Stage 0 contract / ADR 0008).
  **No `become:`**.
- **Delete `changed_when: true`** — the module reports change natively.
- **`chart_version` (gotcha):** `certmanager_chart_version` defaults to `""`
  (no-pinning-during-dev). `default(omit)` does **not** omit an empty string — it
  only omits an *undefined* var — so the module would pass `--version ''`. Use the
  length guard instead, preserving the original behavior:
  `chart_version: "{{ certmanager_chart_version if (certmanager_chart_version | length > 0) else omit }}"`.

**Do not touch:** the values-render task, the webhook wait, any other role.

**Output:** document the working pattern block + gotchas (chart repo/ref form,
helm-diff dependency, the empty-string `chart_version` guard) inline for Stage 2.

**Agent done-criteria:** edits applied, `chart_version` guard correct, syntax-check
+ ansible-lint green; then hand off "ready for verification." Do **not** run the
playbook.

**Maintainer acceptance gate (not an agent task):** `--syntax-check` alone does not
sign off this stage. The maintainer runs the role twice and confirms the **second**
run reports `changed=0` for the helm task **and** `helm list -n cert-manager`
revision does not advance past first install. This two-run test is what proves the
helm-diff no-op path works and catches gotchas like the `chart_version` one above.

---

## Stage 2 — Roll the proven Helm pattern to the remaining 5 releases — ✅ complete

Mechanical repeat of Stage 1; closes **cause #1**. Roles are independent — isolate
each edit to that role's single helm task.

**In scope — the `helm upgrade --install` task in each:**
- `ansible/roles/openbao/tasks/install.yml:230`
- `ansible/roles/nginx_ingress/tasks/install.yml:48`
- `ansible/roles/vso/tasks/main.yml:139` — preserve the local-chart-path branch
  (`vso_chart_path`); map it to the module's `chart_ref` (a local path is valid).
- `ansible/roles/headlamp/tasks/deploy.yml:191`
- `ansible/roles/trust_manager/tasks/main.yml:13`

**`chart_version` handling (applies to all five):** 4 of these 5 roles default
`chart_version` to `""` (`openbao`, `nginx_ingress`, `trust_manager`, and `vso`
via an env lookup that defaults to `''`); only `headlamp` pins (`0.42.0`). Use the
length-guard idiom from Stage 1 on **every** role —
`chart_version: "{{ <role>_chart_version if (<role>_chart_version | length > 0) else omit }}"`
— **not** `default(omit)`, which passes `--version ''` for the empty-string roles.

**Do not touch:** post-helm `kubectl patch` tasks (openbao hosts mapping, headlamp
probe-scheme patch) — those are Stage 7.

**Verify (two-run gate):** full `playbooks/site.yml` rerun → on the **second** run
all six Helm revisions are stable (no advance) and no pod UIDs change from this
track. As in Stage 1, `--syntax-check` does not satisfy this.

---

## Stage 3 — `k8s_info` read-only pilot on `readiness_check` (validate plumbing)

**Why this is the first `k8s`-module stage, not keycloak:** the riskiest plumbing —
the kubeconfig/auth contract from Stage 0, python-client/API compatibility, and
field-manager behavior — must be proven on a **read-only, zero-blast-radius** role
before any apply path depends on it. `readiness_check` has the highest stdout-grep
density (~45 `kubectl get`) and is already entirely `changed_when: false`, so
converting it cannot cause workload churn. This stage does not advance the
idempotency goal directly; it de-risks Stages 4–7 that do.

**In scope — `ansible/roles/readiness_check/tasks/*` only:**
- Convert `kubectl get … -o jsonpath=…` reads → `kubernetes.core.k8s_info`
  (structured dict results; drop the jsonpath string parsing).
- Apply the Stage-0 kubeconfig contract (`kubeconfig: "{{ k3s_kubeconfig_path }}"`,
  **no `become:`**) to every converted task — this is the real validation target.
- Leave `kubectl wait` / `rollout status` and the `helm repo list` check as
  `command` (read-only, no module win).

**Do not touch:** any apply path; any other role.

**Output:** confirm the kubeconfig/auth contract works end-to-end and record any
adjustment back into ADR 0008 / AGENTS.md before apply paths inherit it.

**Verify:** `playbooks/readiness_check.yml` passes with identical results to the
pre-conversion run; no auth/kubeconfig errors; `--check` now produces real reads
(no-op guards permitting).

---

## Stage 4 — Convert the Keycloak role's `kubectl` applies to `kubernetes.core.k8s`

All cause #2/#3 churn lives in the keycloak role. Converting its applies first
gives real idempotency reporting and is the vehicle for Stage 5. Interconnected
within one file. Inherits the kubeconfig/auth contract proven in Stage 3.

**In scope — `ansible/roles/keycloak/tasks/main.yml` only:**
- Namespace two-step (~lines 11–31) → single `kubernetes.core.k8s`,
  `state: present`, `kind: Namespace`.
- Each templated `kubectl apply -f -` (vaultconnection/vaultauth, both
  VaultStaticSecrets, bootstrap-admin Secret, postgres, PG-CA ConfigMap, Keycloak
  CR, realmimport, ingress) → `kubernetes.core.k8s` with
  `definition: "{{ lookup('template', '<x>.j2') | from_yaml_all | list }}"`.
  Use a **stable `field_manager`** and an explicit `force_conflicts` decision on
  every apply (see verification note below).
- Drop the stdout-grep `changed_when` on converted tasks — the module computes
  change.
- Leave `wait` / `rollout status` / `kubectl wait` tasks as `command` for now
  (switching to `wait`/`wait_condition` params is optional, not required).

**Do not touch:** operator install/patch logic (Stage 5); the realm-REST include
files (`realm_groups.yml`, `realm_users.yml`, `rotator.yml`).

**Verify (two-run rule):** the **first** post-conversion run may report one-time
diffs/field-manager noise as server-side apply adopts fields previously owned by
client-side kubectl apply — this is **not** real drift. Confirm idempotency on the
**second** post-conversion run: converted apply tasks report `changed=0` (pod churn
may remain — that's Stages 5–6).

---

## Stage 5 — Eliminate the operator apply/patch ping-pong (cause #2)

Root fix for operator ReplicaSet churn, using the `k8s` module now available here.

**In scope — `ansible/roles/keycloak/tasks/main.yml`, operator install + patch
(~lines 397–439):**
- Replace "apply upstream `kubernetes.yml` → strategic-patch the Deployment" with
  **one converging server-side apply**: fetch the upstream operator manifest, merge
  the startup-probe `failureThreshold` + CPU-limit overrides into the Deployment,
  apply once via `kubernetes.core.k8s` with `server_side_apply` + a stable
  `field_manager`.
- *Alternative if merging upstream is awkward:* keep two tasks but **gate the
  upstream apply** on an image/version mismatch precheck (`k8s_info` on the
  Deployment) so it only runs on install/upgrade, leaving the patch as a
  steady-state no-op.

**Do not touch:** Keycloak CR / StatefulSet handling.

**Verify (two-run rule):** allow a one-time field-manager/last-applied diff on the
first converted run; on the **second** run the operator pod UID is stable and there
are no `keycloak-operator-*` RS create/scale/delete events.

---

## Stage 6 — Resolve the Keycloak StatefulSet restart (cause #3)

Re-measure before changing anything — the cascade may already be gone after
Stage 5.

**In scope — keycloak role:**
- Rerun; if `keycloak-0` UID is now stable, close this stage as
  resolved-by-Stage-5 and document it.
- If it still churns: compare the `Keycloak` CR `.metadata.generation` and the
  resourceVersions of `keycloak-db-secret` / realm-admin Secret across runs. If VSO
  re-syncs identical data and bumps resourceVersion, set a `refreshAfter` /
  content-stable policy on the VaultStaticSecrets so unchanged secrets don't
  re-trigger the operator.

**Verify:** no-op rerun → `keycloak-0` UID and start time unchanged.

---

## Stage 7 — Sweep remaining roles to `kubernetes.core.k8s` + fold in Task D

Finishes the backlog item repo-wide and removes the last always-changed tasks.
Each role independent — one commit at a time.

**In scope (per role, isolated):**
- Remaining `kubectl apply -f -` / namespace two-steps in `openbao`, `vso`,
  `nginx_ingress`, `headlamp`, and the `common` shared task files →
  `kubernetes.core.k8s`.
- **Task D:** `ansible/roles/headlamp/tasks/deploy.yml:245` probe-scheme `kubectl
  patch` (`changed_when: true`) → `k8s` server-side apply / `k8s_json_patch` so an
  unchanged patch reports `ok`.
- `openbao` post-helm host/patch tasks: convert where it removes a stdout-grep
  `changed_when`.

**Do not touch:** `readiness_check` `helm repo list` check — informational; charts
install inline via `--repo`, so no repos are registered (empty list is expected).
(The `readiness_check` `get` reads were already converted in Stage 3.)

**Verify (two-run rule):** allow one-time field-manager adoption diffs on the first
converted run per role; on the **second** full `site.yml` rerun, `changed=0` except
genuinely-drifted tasks and a final snapshot diff clean across Helm, operator, and
all workloads.

---

## Stage dependency graph

```
0 ─┬─ 1 ─ 2                      (Helm track — closes cause #1)
   └─ 3 ─ 4 ─ 5 ─ 6             (k8s plumbing pilot → Keycloak — closes #2 / #3)
            └─────────── 7      (sweep + Task D; needs 2, 3, and 4)
```

Stage 0 gates everything (deps + ADR 0008 + kubeconfig contract). Stage 3 (the
read-only `k8s_info` pilot) gates every apply path (4–7) by proving the
kubeconfig/auth + field-manager plumbing first. The Helm track (1–2) and the k8s
track (3→…) are independent after Stage 0 and may be parallelized.

## Verification convention (applies to every apply-conversion stage)

Server-side / three-way-merge apply adopts fields previously managed by
client-side `kubectl apply`, so the **first** post-conversion run can report
one-time diffs and field-manager noise that are **not** real drift. Judge
idempotency on the **second** post-conversion run. Use a stable `field_manager`
per role and make the `force_conflicts` choice explicit.

## Reference

- Scope counts and rationale: `doc/simplification-opportunities.md` #2 (9 helm
  calls, 31 `kubectl apply`, 54 stdout-grep `changed_when`, 3 namespace two-steps).
- Original dependency-free decision: `doc/handoffs/migration_opentofu_to_helm.md` §2.
- ADR to supersede: `doc/decisions/0006-defer-kubernetes-core.md` (the
  "wholesale, not mixed per-role" clause) → new ADR 0008 (written in Stage 0).
- Version pinning is deferred to ship time (`backlog.md`) — do not pin here.
