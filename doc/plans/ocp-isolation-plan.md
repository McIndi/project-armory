# Plan: isolate `ocp-deployment` from k3s (v2)

Goal: strip the branch to a coherent, best-practices Ansible codebase that targets
**only** the OpenShift deployment of project-armory. This deliberately abandons the
"steer by inventory, never fork roles" rule and its merge-cleanliness with `main`.

v2 changes after review: the Phase-0 VSO install/wiring split was **rejected as
unworkable** (the hardened chart mounts the kube-rbac-proxy TLS secret as a pod
volume and the install waits on rollout — splitting stalls bootstrap in
`ContainerCreating`). Superseded by a bigger decision:

> **VSO is removed entirely.** The playbook materializes Kubernetes Secrets
> itself from OpenBao (which stays the source of truth). Rotation-driven secret
> sync is **out of scope** — rotating a secret means re-running the playbook.

Scope: `project-armory` only. Garrison untouched (but see "Downstream notes").
Nothing has ever been deployed; there is no live-cluster migration or cleanup to do.

Ground rules for the implementer:
- **Never run anything against the cluster.** Validation is local: `--syntax-check`,
  `--list-tasks`, `--check`, `ansible-lint`, YAML parse, grep gates.
  Honest limits: `--check` here proves templating/variable resolution only — nearly
  every cluster-touching task is guarded `when: not ansible_check_mode` (verified:
  a full `--check` yields ~443 skips). `--list-tasks` does **not** expand dynamic
  `include_tasks` (keycloak/main.yml has 6, readiness_check/main.yml has 11), so the
  task-diff oracle is blind inside those files — the grep gates in §V compensate.
- The inventory path stays `inventories/openshift/` (no rename — §V depends on it).
- Work phases in order; each ends with the §V gate. Recapture the `--list-tasks`
  baseline **after any phase that moves or deletes tasks** — the diff rule is only
  "no unexplained loss vs the previous phase," never vs a stale baseline.
- Delete, don't comment out. Remove `when:`s that become tautological.
- Commit per phase, message prefix `isolate(ocp):`.

## Progress log

- [x] 2026-07-24: Completed a scheduler-selector follow-up cleanup.
  After the CronJob-only code collapse, removed the now-dead
  `armory_scheduler_kind` inventory knob from both
  `inventories/openshift/group_vars/all.yml` and
  `inventories/development/group_vars/all.yml` so no inert selector remains.
  Local Vagrant validation passed again for `site.yml` and `bootstrap.yml`
  (`--syntax-check` and `--check`, both recaps `failed=0`). This closes the
  `armory_scheduler_kind` selector fully (code and config).
  Next intended Phase 3 slice: `target_platform` collapse, including explicit
  verification of the `openbao_oidc` hostAlias/edge-gateway lookup unknown
  before deleting that chain.

- [x] 2026-07-24: Completed a Phase 3 scheduler-selector slice
  (`armory_scheduler_kind` collapse to CronJob-only behavior).
  Removed the non-OCP host-timer branches from
  `roles/openbao/tasks/audit_rotate.yml` and
  `roles/keycloak/tasks/admin_events_prune.yml`, deleted the now-dead host
  timer script templates
  (`roles/openbao/templates/openbao-audit-rotate.sh.j2` and
  `roles/keycloak/templates/keycloak-admin-events-prune.sh.j2`), removed the
  obsolete host-timer defaults (`openbao_audit_rotate_on_calendar` and
  `keycloak_admin_events_prune_on_calendar`), and deleted the matching systemd
  cleanup tasks from `roles/openbao/tasks/teardown.yml`. Local validation in
  Vagrant passed for `site.yml` and `bootstrap.yml` syntax checks plus
  check-mode runs (`failed=0` in both recaps). Fresh task-list snapshots were
  captured to `/tmp/now-site-step7.txt` and `/tmp/now-bootstrap-step7.txt` for
  use as the next baseline after this task-moving slice.

- [x] 2026-07-24: Completed the follow-on Phase 3 edge selector cleanup
  (eliminate `edge_kind` and dead direct-Route branches).
  After verifying the pass-1 collapse left `openbao/tasks/route.yml` and
  `keycloak/tasks/route.yml` unreachable under the only live OCP edge path,
  removed both route task files and templates, removed their invocation sites
  (`roles/openbao_oidc/tasks/main.yml` and `roles/keycloak/tasks/main.yml`),
  removed `edge_kind` from both inventories, and deleted the now-orphaned
  readiness Gateway-API trace check (`roles/readiness_check/tasks/check_trace_boundary.yml`).
  Also scrubbed residual comments/docs that referenced the deleted selector or
  check file. Validation: local Vagrant syntax-check and check-mode both passed
  for `site.yml` and `bootstrap.yml` (`failed=0` in both recaps); static include/
  import target existence check found no missing referenced files; and
  `site.yml --list-tasks` pass1→pass2 diff showed only expected deletions:
  Keycloak's dead "Expose Keycloak through the edge" include and the dead
  OpenBao Route tasks. Verified the live public edge still comes from
  `envoy_proxy/templates/routes.yaml.j2` with OpenShift inventory upstreams for
  `armory_keycloak_host` and `armory_openbao_host`.

- [x] 2026-07-24: Completed the first Phase 3 slice (`edge_kind` collapse, pass 1).
  Removed the remaining Gateway-API `httproute` paths while keeping the
  OpenShift Route/Route->Envoy behavior: dropped the now-tautological
  `envoy_proxy` role gate in `playbooks/site.yml`; deleted the
  `httproute` branch from `roles/openbao/tasks/route.yml`; removed Keycloak's
  HTTPRoute/BackendTLSPolicy apply block from `roles/keycloak/tasks/main.yml`;
  simplified `roles/keycloak/tasks/route.yml` and
  `roles/readiness_check/tasks/main.yml` to the Route/Envoy path; deleted
  `roles/common/tasks/apply_backend_ca_configmap.yml`; and deleted both
  `roles/openbao/templates/httproute.yaml.j2` and
  `roles/keycloak/templates/httproute.yaml.j2`. Also retitled the single
  `site.yml` play to "Base configuration for OpenShift deployment" to avoid the
  stale Fedora/k3s wording while this selector collapse is underway. Local
  validation in Vagrant passed: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check`,
  `... playbooks/bootstrap.yml --syntax-check`, `... playbooks/site.yml --check`,
  and `... playbooks/bootstrap.yml --check` all completed with `failed=0`.
  A fresh `site.yml --list-tasks` snapshot contains no `HTTPRoute` or
  `BackendTLSPolicy` tasks, and static reference checks found no remaining
  references to `apply_backend_ca_configmap.yml` or the deleted
  `httproute.yaml.j2` templates.

- [x] 2026-07-24: Completed the Phase 2 close-out boundary items.
  Merged `playbooks/site.yml` back to a single play after confirming the old
  split no longer served any handler-flush purpose: the surviving early roles
  (`env_guard`, `helm`) declare no `notify` or `handlers`, so the removed k3s
  restart rationale was dead. Also removed the leftover empty directory
  skeletons `ansible/roles/delve/`, `ansible/roles/headlamp/`, and
  `charts/delve/`. Local validation in Vagrant passed:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift
  playbooks/site.yml --syntax-check`, `... playbooks/bootstrap.yml
  --syntax-check`, `... playbooks/site.yml --check`, and
  `... playbooks/bootstrap.yml --check` all completed with `failed=0`.
  The `site.yml --list-tasks` diff versus the Phase 1 baseline showed the
  expected cumulative Phase 2 removals plus the disappearance of the obsolete
  second-play wrapper, with no unexpected task loss.

- [x] 2026-07-24: Teardown follow-up hardening after review.
  Updated `playbooks/teardown_openshift.yml` so namespace deletion now waits
  for completion (`wait: true`, `wait_timeout: 300`) to avoid immediate
  bootstrap reruns failing on namespaces still in `Terminating`. Also added a
  header callout that tearing down the OpenBao namespace deletes its PVC and
  stored PKI/KV data. Local validation in Vagrant passed:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift
  playbooks/teardown_openshift.yml --syntax-check`,
  `... --list-tasks -e teardown_confirm=true`, plus unchanged syntax-check
  passes for `playbooks/site.yml` and `playbooks/bootstrap.yml`.

- [x] 2026-07-23: Completed the remaining additive Phase 2 playbook step
  (`teardown_openshift.yml`).
  Added `playbooks/teardown_openshift.yml` with a hard confirmation gate
  (`teardown_confirm=true`) plus a cluster-admin preflight, and explicit
  deletion scope for armory-owned resources only: the five `tex26-*`
  namespaces, `tex26-automation` ClusterRole/ClusterRoleBinding,
  `openbao-tokenreview` ClusterRoleBinding, ClusterIssuers
  `tex26-openbao-pki-internal` and `tex26-openbao-pki-external`,
  cross-namespace Role/RoleBinding pairs (`tex26-automation-ca-writer`,
  `cert-manager-tokenrequest`, `tex26-automation-root-ca-reader`), and the
  armory-managed OpenBao CA secret copy in namespace `cert-manager`.
  The playbook intentionally does not helm-uninstall or mutate the shared
  cert-manager installation. Local validation in Vagrant passed:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift
  playbooks/teardown_openshift.yml --syntax-check`,
  `... --list-tasks -e teardown_confirm=true`, plus unchanged syntax-check
  passes for `playbooks/site.yml` and `playbooks/bootstrap.yml`.

- [x] 2026-07-23: Completed a eighth Phase 2 slice (remove `delve`).
  Deleted `roles/delve/` and `charts/delve/`, removed the `delve` role entry
  from `playbooks/site.yml`, and scrubbed the leftover Delve inventory knobs
  from both `inventories/development/group_vars/all.yml` and
  `inventories/openshift/group_vars/all.yml`. Also trimmed a few stale Delve
  comment references in `roles/envoy_gateway/README.md`,
  `roles/openbao/defaults/main.yml`, and `roles/openbao/tasks/install.yml`.
  Local validation in Vagrant passed: `ANSIBLE_ROLES_PATH=roles ansible-playbook
  -i inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed after sourcing `.env`; and a fresh `site.yml` task-list
  snapshot was captured for the Phase 2 baseline update.

- [x] 2026-07-23: Completed a seventh Phase 2 slice (remove `k3s`).
  Deleted `roles/k3s/`, removed its role entry from `playbooks/site.yml`, and
  removed `k3s_audit_enabled` from both inventories. Also removed the now-dead
  Delve k8s-audit shipper task (`roles/delve/tasks/shippers.yml`) plus its
  template (`roles/delve/templates/delve_shipper_k8s_audit.yaml.j2`) and
  cleaned matching stale references in `roles/delve/README.md`. Local
  validation in Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed with failed=0 after sourcing `.env`; and list-task diffs vs
  the Phase 1 baseline (`/tmp/base-site-p1.txt`, `/tmp/base-bootstrap-p1.txt`)
  showed the expected cumulative `site.yml` removals including the `k3s` role
  tasks with no bootstrap delta. Static grep gate for removed artifacts
  (`roles/k3s`, `k3s_audit_enabled`, `delve_shipper_k8s_audit.yaml.j2`) found
  no remaining references under `ansible/`.

- [x] 2026-07-23: Headlamp slice follow-up cleanup after review.
  Removed the remaining `headlamp` leftovers from OpenShift inventory
  (`readiness_check_headlamp_enabled`, `headlamp_namespace`,
  `headlamp_openbao_oidc_path`), removed `headlamp` from
  `openbao_provisioner_kv_prefixes` in `roles/openbao/defaults/main.yml`, and
  fixed the accidental comment truncation in
  `roles/envoy_gateway/defaults/main.yml` while keeping only
  `ARMORY_OPENBAO_HOST` / `ARMORY_DELVE_HOST` in gateway SAN defaults. Local
  validation in Vagrant passed: `site.yml` and `bootstrap.yml` syntax-check and
  `--check` both returned failed=0.

- [x] 2026-07-23: Completed a sixth Phase 2 slice (remove `headlamp`).
  Deleted `roles/headlamp/` and removed its role entry from `playbooks/site.yml`;
  removed the `readiness_check` headlamp toggle and task include; dropped the
  headlamp host from the consolidated gateway SAN list; and trimmed the OpenShift
  inventory comment plus the readiness-check README's stale role list entry.
  Local validation in Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed after sourcing `.env`; and the task-list diff against the
  Phase 1 baseline showed the expected cumulative `headlamp` removals with no
  bootstrap delta.

- [x] 2026-07-23: Completed a fifth Phase 2 slice (remove `trust_manager`).
  Deleted `roles/trust_manager/` and removed its role entry from
  `playbooks/site.yml`; removed `trust_manager_enabled` and
  `use_declarative_ca_distribution` from both inventories; and simplified CA
  secret defaults/guards in `roles/delve`, `roles/headlamp`,
  `roles/keycloak`, `roles/openbao_oidc`, and `roles/readiness_check` so they
  always use direct OpenBao CA-secret copy. Local validation in Vagrant:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift
  playbooks/site.yml --syntax-check` and `... playbooks/bootstrap.yml
  --syntax-check` both passed; `--check` for both playbooks passed after
  sourcing `.env`; and list-task diffs vs the Phase 1 baseline
  (`/tmp/base-site-p1.txt`, `/tmp/base-bootstrap-p1.txt`) showed no bootstrap
  delta and the expected cumulative `site.yml` removals, including the
  trust-manager tasks.

- [x] 2026-07-23: Completed a fourth Phase 2 slice (remove `host_dependencies`).
  Deleted `roles/host_dependencies/` and removed its role entry from
  `playbooks/site.yml`; also updated the stale OpenShift inventory comment that
  listed `host_dependencies` among the gated node-owning roles. Local
  validation in Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed after sourcing `.env`; and list-task diffs vs the Phase 1
  baseline (`/tmp/base-site-p1.txt`, `/tmp/base-bootstrap-p1.txt`) showed no
  bootstrap delta and the expected cumulative `site.yml` removals, including
  the `host_dependencies` task.

- [x] 2026-07-23: Completed a third Phase 2 slice (remove `system_update`).
  Deleted `roles/system_update/` and removed its role entry from
  `playbooks/site.yml`; also updated the stale OpenShift inventory comment that
  listed `system_update` among the gated node-owning roles. Local validation in
  Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed after sourcing `.env`; and list-task diffs vs the Phase 1
  baseline (`/tmp/base-site-p1.txt`, `/tmp/base-bootstrap-p1.txt`) showed no
  bootstrap delta and only the expected cumulative `site.yml` removals from the
  already-completed `kernel_tuning` slice plus the two `system_update` tasks.

- [x] 2026-07-23: Completed a second Phase 2 slice (remove `kernel_tuning`).
  Deleted `roles/kernel_tuning/` and removed its role entry from
  `playbooks/site.yml`; also updated the stale OpenShift inventory comment that
  listed `kernel_tuning` among gated node-owning roles. Local validation in
  Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed after sourcing `.env`; and list-task diffs vs the Phase 1
  baseline (`/tmp/base-site-p1.txt`, `/tmp/base-bootstrap-p1.txt`) showed only
  the expected removal of the five `kernel_tuning` tasks from `site.yml` with
  no bootstrap task-list delta.

- [x] 2026-07-23: Completed the first Phase 2 slice (teardown-order safety).
  Deleted `playbooks/teardown_k3s_workloads.yml` and
  `roles/cert_manager/tasks/teardown.yml` together so no playbook can retain
  includes to deleted k3s / envoy-gateway teardown tasks. Local validation in
  Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for both
  playbooks passed after sourcing `.env`; and fresh list-task snapshots were
  captured to `/tmp/now-site-p2-step1.txt` and `/tmp/now-bootstrap-p2-step1.txt`
  with diffs against the Phase 1 baseline (`/tmp/base-site-p1.txt`,
  `/tmp/base-bootstrap-p1.txt`) showing no task-list deltas.

- [x] 2026-07-23: Closed the remaining Phase 1 step 1 deletions and recaptured
  the Phase 1 baseline.
  Deleted `ansible/roles/vso/` and `charts/vso-hardened/`, removed
  `vso_enabled` from both inventories, and removed `VSO_CHART_*` env plumbing
  from `.env`, `.env.example`, and `.env.openshift.example`. Also removed the
  now-dangling `include_role: name: vso` task from
  `playbooks/teardown_k3s_workloads.yml` so no playbook references a deleted
  role. Local validation in Vagrant: `ANSIBLE_ROLES_PATH=roles
  ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check`
  and `... playbooks/bootstrap.yml --syntax-check` both passed; `--check` for
  both playbooks passed after sourcing `.env`; and fresh list-task baselines
  were captured to `/tmp/base-site-p1.txt` and `/tmp/base-bootstrap-p1.txt`
  (diff vs the previous step baseline was empty for both playbooks).

- [x] 2026-07-23: Completed Phase 1 step 6.
  Removed the `secrets.hashicorp.com` permission rule from
  `roles/automation_rbac/defaults/main.yml`
  (`automation_rbac_namespace_rules`) now that VSO resources are gone. Local
  validation in Vagrant: `ANSIBLE_ROLES_PATH=roles ansible-playbook -i
  inventories/openshift playbooks/site.yml --syntax-check` and
  `... playbooks/bootstrap.yml --syntax-check` both passed; `--list-tasks`
  diffs versus the prior baseline (`/tmp/now-site-step4.txt` and
  `/tmp/now-bootstrap-step4.txt`) were empty; and `--check` for both playbooks
  passed once the repo `.env` was sourced before running Ansible.

- [x] 2026-07-23: Completed Phase 1 step 4 and closed the coupled rotator regression.
  Removed the Keycloak realm-admin rotator include from
  `roles/keycloak/tasks/main.yml`, deleted `roles/keycloak/tasks/rotator.yml`
  and `roles/keycloak/templates/realm_admin_rotator.yaml.j2`, and dropped the
  rotator defaults / inventory vars that kept the CronJob reachable on
  OpenShift. Local validation in Vagrant: `ANSIBLE_ROLES_PATH=roles
  ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check`
  and `... playbooks/bootstrap.yml --syntax-check` both passed; grep of the
  Ansible tree returned no remaining `keycloak_rotator_*`,
  `keycloak_openbao_rotator_path`, `keycloak_realm_admin_rotation_*`,
  `rotator.yml`, or `realm_admin_rotator.yaml.j2` references; and `--check`
  for both playbooks passed once the repo `.env` was sourced before running
  Ansible.

- [x] 2026-07-23: Completed Phase 1 step 5.
  Removed `roles/openbao/tasks/consumer_wiring.yml`, dropped its import from
  `roles/openbao/tasks/main.yml`, and deleted the now-unused OpenShift
  inventory wiring vars for Keycloak / rotator / Headlamp / Delve Kubernetes
  auth roles and ACL policy names. Local validation in Vagrant:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check`
  and `... playbooks/bootstrap.yml --syntax-check` both passed; `--list-tasks`
  diff versus the Phase 1 baseline only removed the expected
  `openbao_consumer_wiring` tasks; and `--check` for both playbooks passed once
  the repo `.env` was sourced before running Ansible.

- [x] 2026-07-23: Completed the remainder of Phase 1 step 1.
  Removed the `readiness_check` VSO include and its defaults, and deleted the
  now-dead Keycloak VSO templates plus their stale defaults/comments. Local
  validation in Vagrant:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check`
  and `... playbooks/bootstrap.yml --syntax-check` both passed, and the
  recaptured `--list-tasks` diff only shows the expected VSO / Keycloak Secret
  materialization removals.

- [x] 2026-07-23: Completed the first Phase 1 slice.
  Removed the shared `vso` role from `playbooks/bootstrap.yml` and
  `playbooks/site.yml`, and replaced Keycloak's VSO-backed DB / realm-admin
  sync with direct namespace `Secret` applies in
  `roles/keycloak/tasks/main.yml`. Local validation in Vagrant:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check`
  and `... playbooks/bootstrap.yml --syntax-check` both passed.

- [x] 2026-07-23: Completed Phase 0 step 2 in
  `roles/common/tasks/copy_openbao_ca_secret.yml`.
  Added a guard so "Apply CA secret in target namespace" only runs when
  `(_common_ca_secret_info.resources | default([]) | length) > 0`, plus a debug
  message when the source secret is missing. Local validation in Vagrant:
  `ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check`
  and `... playbooks/bootstrap.yml --syntax-check` both passed.

---

## Phase 0 — Baseline + small prerequisite fix

1. Capture baselines:
   ```bash
   cd ansible
   ansible-playbook -i inventories/openshift playbooks/site.yml --list-tasks > /tmp/base-site-p0.txt
   ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --list-tasks > /tmp/base-bootstrap-p0.txt
   ```
2. `roles/common/tasks/copy_openbao_ca_secret.yml`: guard "Apply CA secret in
   target namespace" with
   `when: (_common_ca_secret_info.resources | default([]) | length) > 0` plus a
   `debug` message for the skip. (Generic hardening; remaining callers after
   Phase 1 — cert_manager, envoy_proxy — run after OpenBao exists, so a skip there
   signals a real fault, now legibly instead of as an index error.)

## Phase 1 — Remove VSO; playbook-materialized Secrets

Design: OpenBao remains the audited source of truth for every credential. The
playbook (as `tex26-automation`) writes the derived Kubernetes Secret itself,
immediately after writing the KV entry. No operator, no CRDs, no sync loop.

1. **Delete**: `roles/vso/`, `charts/vso-hardened/`,
   `roles/readiness_check/tasks/check_vso.yml` (+ its include and
   `readiness_check_vso_*` vars), all `vso_*` vars in both inventories, the
   `VSO_CHART_*` env plumbing, and the `vso` role entries in **both**
   `playbooks/bootstrap.yml` and `playbooks/site.yml`.
   bootstrap.yml is now: env_guard → automation_rbac → preflight. Update its
   header comment (VSO was one of its stated reasons to exist; the remaining
   reasons — namespaces, SA grants, the three privileged bindings — stand).
2. **Keycloak DB secret** (`roles/keycloak/tasks/main.yml`): the role already
   generates creds and reads/writes `{{ keycloak_openbao_db_path }}` KV
   (~lines 55–83). Replace the VSO hop (~lines 200–245: VaultConnection/VaultAuth/
   VaultStaticSecret applies + "Wait for keycloak-db-secret to be synced by VSO")
   with a direct `kubernetes.core.k8s` Secret apply (`no_log`, values from the same
   facts that were written to KV). Delete templates `vaultconnection.yaml.j2`,
   `vaultauth.yaml.j2`, `vaultstaticsecret.yaml.j2`,
   `vaultstaticsecret_realm_admin.yaml.j2`.
3. **Realm-admin secret**: same treatment as the DB secret.
4. **Rotator removed** (`roles/keycloak/tasks/rotator.yml`,
   `realm_admin_rotator.yaml.j2`, its CronJob/SA/Role, `keycloak_rotator_*` vars).
   Verified dependency chain — both legs die in this phase:
   (a) the CronJob authenticates to OpenBao by **k8s auth role
   `keycloak_rotator_openbao_k8s_role`**, created only in `consumer_wiring.yml`
   (deleted in step 5); (b) it writes the new password to OpenBao KV at
   `keycloak_openbao_realm_admin_path` and **VSO** performed the last hop into the
   namespace Secret — without it a rotation silently strands every Secret consumer
   (Keycloak keeps the new password, the Secret keeps the old one).
   Rotation is out of scope — document "to rotate: re-run
   `site.yml --tags keycloak`" in `doc/operations.md`.
5. **`roles/openbao/tasks/consumer_wiring.yml`: delete the file** and its import
   in `openbao/tasks/main.yml`. Every block in it exists to give VSO (or the
   rotator, or headlamp/delve — deleted in Phase 2) a Kubernetes-auth path into
   OpenBao. The cert-manager policy/role live in `configure.yml` and are untouched.
   Also remove the now-unused `keycloak_vso_sa_name` / `keycloak_openbao_policy_name`
   / `keycloak_openbao_k8s_role` / rotator / headlamp / delve wiring vars from the
   OpenShift inventory (added earlier this session; most die here — keep only
   `keycloak_openbao_db_path` / `keycloak_openbao_realm_admin_path`, still used by
   the KV writes).
6. **`roles/automation_rbac/defaults/main.yml`**: drop the `secrets.hashicorp.com`
   rule from `automation_rbac_namespace_rules` (preflight count adjusts itself —
   grants and checks expand from the same matrix).
7. Kubernetes-auth in OpenBao (`configure.yml`) **stays**: cert-manager's vault
   issuer still authenticates that way, and the `openbao-tokenreview` CRB remains
   required. Do not remove k8s-auth enablement.

Recapture baselines after this phase (`/tmp/base-*-p1.txt`).

## Phase 2 — Delete k3s-only roles and playbooks

Delete these role directories, their entries in `playbooks/site.yml`, and listed residue:

| Role | Also remove |
|---|---|
| `k3s` | `k3s_audit_enabled` refs; `playbooks/teardown_k3s_workloads.yml` (below) |
| `kernel_tuning` | — |
| `system_update` | — |
| `host_dependencies` | — |
| `headlamp` | `headlamp_*` vars; `readiness_check_headlamp_*`; `check_headlamp.yml` |
| `envoy_gateway` | `edge_gateway_*` vars; `common/tasks/resolve_edge_gateway_ip.yml`, `common/tasks/lookup_gateway_service.yml` + every call site (openbao_oidc hostAlias chain — see Phase 4 unknown) |
| `delve` | `delve_*` vars; `charts/delve/`; registry pull-secret comment refs. Re-add later as an OCP-native role |
| `trust_manager` | `trust_manager_enabled`, `use_declarative_ca_distribution` + every `when:` testing it |

Playbooks:
- Delete `playbooks/teardown_k3s_workloads.yml` and `roles/cert_manager/tasks/teardown.yml`
  (helm-uninstalls the **shared** cert-manager — must never exist on this branch).
- Add `playbooks/teardown_openshift.yml`: confirm-gated (`teardown_confirm`), run as
  cluster-admin. Deletes: the 5 `tex26-*` namespaces; ClusterRole+CRB
  `tex26-automation`; CRB `openbao-tokenreview`; ClusterIssuers
  `tex26-openbao-pki-internal|-external`; Role/RoleBinding pairs
  `tex26-automation-ca-writer` + `cert-manager-tokenrequest` (ns `cert-manager`)
  and `tex26-automation-root-ca-reader` (ns `kube-public`); the armory-written CA
  secret in ns `cert-manager`. **Hard rule: never helm-uninstall or mutate the
  shared cert-manager install.** (VSO handling: none needed — Phase 1 removed it
  before anything was ever deployed.)

## Phase 3 — Collapse the platform selectors

Keep only the OCP branch, delete the variable and tautological `when:`s:

| Variable | Keep | Delete |
|---|---|---|
| `target_platform` | (gone) | all 6 `== 'k3s'` gates in site.yml; the assert in `keycloak/tasks/main.yml:16` |
| `edge_kind` | `route` / `route_envoy` | `httproute` branches in `openbao/tasks/route.yml`, keycloak HTTPRoute apply, `readiness_check/tasks/main.yml`; `*/templates/httproute.yaml.j2`; `common/tasks/apply_backend_ca_configmap.yml` **iff** grep shows no remaining caller |
| `armory_scheduler_kind` | `cronjob` | systemd/host-script halves of `openbao/tasks/audit_rotate.yml`, `keycloak/tasks/admin_events_prune.yml`; systemd tasks in `openbao/tasks/teardown.yml` |
| `internal_https_caller_mode` | `port_forward` | `cluster_ip` branch in `common/tasks/prepare_internal_https_caller_dns.yml` |
| `keycloak_operator_install_method` | `none` | operator/manifest install paths in keycloak main.yml; `keycloak.yaml.j2`; `keycloak_k8s_resources_base_url`; operator tasks in `keycloak/tasks/teardown.yml`. Refactor `deploy_operatorless.yml`: realm body moves from `realmimport.yaml.j2` lift-out to a direct `realm.json.j2`; delete `realmimport.yaml.j2` |
| `keycloak_workload_kind` | `deployment` | any other branch |
| `kubectl_bin` | keep var, default `oc` | the `k3s kubectl` default; grep-fix stray hardcoded `k3s kubectl` |
| `k3s_kubeconfig_path` | rename `armory_kubeconfig_path` everywhere (incl. bootstrap.yml `KUBECONFIG:`) | the alias line in the inventory |

## Phase 4 — Inventory collapse + per-role residue

- Delete `inventories/development/` entirely. `inventories/openshift/` remains (no rename).
- Move now-only-possible values into role defaults (`postgres-openshift.yaml.j2`
  becomes the only `postgres.yaml.j2`; `keycloak_pg_image`; `openbao_disable_mlock`;
  `openbao_scc_name`). Keep cluster facts in inventory (apps domain, hostnames,
  `tex26-*` namespaces, storage class, labels, break-glass/watcher toggles,
  `keycloak_openbao_*_path` KV paths).
- **openbao**: delete `openbao_firewall_*` + firewalld task; `openbao_node_port`;
  the "UI host resolves to gateway IP" `/etc/hosts` task + `openbao_ingress_ip_effective`.
- **cert_manager**: delete `install.yml`, helm/chart vars, `certmanager_install_enabled`
  (reuse-only is the only mode); keep `rbac.yml` + `issuer.yml`.
- **readiness_check**: delete `check_k3s.yml`, `check_host.yml`, `check_gateway.yml`,
  `check_trace_boundary.yml` (Gateway-API variant) + their toggles; keep
  `check_trace_boundary_envoy.yml`, openbao/keycloak/helm checks.
- **openbao_oidc — the one genuine unknown**: the Envoy-Gateway data-plane lookup +
  StatefulSet hostAlias patch/pod-recreate chain looks k3s-only (public Route hosts
  should resolve from pods via ordinary DNS on OCP). **Verify how
  `openbao_oidc_resolver_host` is set for OCP before deleting; if ambiguous, flag to
  Cliff — do not guess.**
- **common**: delete helpers left with zero callers (candidates:
  `resolve_edge_gateway_ip.yml`, `lookup_gateway_service.yml`,
  `apply_backend_ca_configmap.yml`); keep `bind_scc.yml`, `apply_certificate.yml`,
  `copy_openbao_ca_secret.yml`, `write_ca_file_from_secret.yml`,
  `prepare_internal_https_caller*.yml`, `stop_port_forwards.yml`,
  `load_openbao_*_token.yml`.
- **helm**: delete dnf-install path + `helm_package_*` vars; keep version check +
  diff-plugin install.
- **automation_rbac**: default kubeconfig off `/etc/rancher/k3s/k3s.yaml`.
- **filter_plugins/edge_network.py**: delete if grep shows k3s-only usage.
- **scripts/capture_run_snapshot.sh**: remove k3s references.

## Phase 5 — Hygiene

- Add `ansible/ansible.cfg` (default inventory, `interpreter_python=auto_silent`);
  fix `INJECT_FACTS_AS_VARS` deprecations (`ansible_env.HOME` →
  `ansible_facts.env.HOME`, `ansible_user_id` → `ansible_facts.user_id`).
- Retitle plays ("Base configuration for local Fedora VM", "…k3s control plane").
- **Comment scrub**: rewrite comments that explain OCP choices by contrast with k3s
  (envoy_proxy defaults/main.yml header, openbao route.yml, site.yml role comments,
  inventory prose). Keep genuinely historical rationale in `doc/decisions/`, not in
  task files. This step is what makes the strict §V grep gate passable.
- `ansible-lint`: fix findings introduced by this work only (handoff §9 stands).
- Docs: README deploy flow; `doc/architecture.md`; `doc/operations.md` gains the
  manual-rotation runbook (Phase 1.4) and `teardown_openshift.yml`; a
  `doc/decisions/` note recording: VSO removed (playbook-materialized secrets,
  rotation out of scope) and "steer by inventory" superseded.

## §V — Validation gate (after every phase)

```bash
cd ansible
ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --syntax-check
ansible-playbook -i inventories/openshift playbooks/site.yml --list-tasks > /tmp/now-site.txt
diff /tmp/base-site-p<prev>.txt /tmp/now-site.txt      # every disappearance must be explained by this phase's table
ansible-playbook -i inventories/openshift playbooks/site.yml --check      # failed=0 (templating oracle only)
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --check # failed=0
# include_tasks blindness compensation: no file may be referenced that no longer exists
grep -rn "include_tasks\|import_tasks\|tasks_from" roles/ playbooks/ --include="*.yml" \
  | grep -oP "(include_tasks|import_tasks|tasks_from)[:=]?\s*\K[\w./]+\.yml" | sort -u \
  | while read f; do find roles -name "$(basename $f)" | grep -q . || echo "MISSING: $f"; done
```

Final gates (after Phase 5; must return nothing outside `doc/`):
```bash
grep -rn "k3s" ansible/ --include="*.yml" --include="*.j2" --include="*.cfg"
grep -rn "target_platform\|edge_kind\|httproute\|BackendTLSPolicy" ansible/ --include="*.yml" --include="*.j2"
grep -rn "headlamp\|delve\|vso\|VaultStaticSecret\|VaultAuth\|VaultConnection\|secrets.hashicorp.com" ansible/ --include="*.yml" --include="*.j2"
grep -rn "systemd\|firewalld" ansible/roles/ --include="*.yml"
grep -rn "dnf" ansible/roles/ --include="*.yml"   # expected survivor: openssl install in openbao/install.yml (controller provisioning) — everything else must be justified
```

## Downstream notes / risks

- **Garrison**: `doc/agentstack-keycloak-reqs-for-garrison.md` and the future
  garrison conversion may have assumed VSO-delivered secrets. Its `tex26-agent-plat`
  namespace was also listed in `registry_pull_secret_namespaces` plans. Flag VSO's
  removal in the garrison planning doc before conversion starts.
- **Rotation posture** is now: playbook re-run only. If that ever becomes
  unacceptable, the recorded alternatives are (a) reinstate VSO, or (b) an
  in-cluster job that writes the Secret directly (needs a scoped secret-write
  grant). Decision deferred deliberately.
- Merge-back to `main` for ansible content is abandoned; k3s lives on `main`.
- The openbao_oidc hostAlias chain (Phase 4) is the only flagged unknown — verify,
  don't guess.
