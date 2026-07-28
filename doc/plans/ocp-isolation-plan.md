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

## Current position (2026-07-27)

Phases 0–4 complete; **Phase 5 is in progress**.
**Next work: Phase 5 slice 6** (stabilize ansible-lint completion capture and
close any lint findings introduced by this branch only).
Objective progress metric is the k3s burn-down grep in §V — it now returns zero
hits under `ansible/` for `*.yml`, `*.j2`, and `*.cfg`.

## Progress log

- [x] 2026-07-28: Follow-up corrections after review of the Phase 5 slice 5
  README/architecture refresh.
  Addressed two README loose ends and one architecture completeness gap:
  replaced the misleading `${KEYCLOAK_NAMESPACE:-tex26-oidc}` examples with
  concrete `tex26-oidc` namespace usage in credential retrieval commands (the
  documented env var was never wired in `.env`), removed the stale `charts/`
  repository-layout row now that the directory is empty, and restored the
  OpenShift-specific edge rationale in `doc/architecture.md` by explicitly
  documenting Route `reencrypt` fronting, HAProxy trace-boundary limits, and
  the deliberate Route -> in-namespace Envoy two-hop design. This was a
  docs-only correction slice; no Ansible task graph or runtime behavior changed.

- [x] 2026-07-27: Completed a Phase 5 slice 5 documentation refresh for
  top-level architecture/deploy guidance.
  Rewrote `README.md` and `doc/architecture.md` to match the current
  OpenShift-only shape: removed stale k3s/VSO/headlamp/delve/trust-manager
  narratives, replaced the old role graph with the live
  `env_guard -> helm -> openbao -> cert_manager -> keycloak -> openbao_oidc -> envoy_proxy -> registry? -> readiness_check`
  flow, switched teardown references to `playbooks/teardown_openshift.yml`, and
  documented direct playbook-materialized Secrets (no VSO sync loop). Local
  Vagrant validation remained clean: `site.yml` and `bootstrap.yml`
  syntax-check passed; `--list-tasks` snapshots
  (`/tmp/now-site-step23.txt` -> `/tmp/now-site-step24.txt`,
  `/tmp/now-bootstrap-step23.txt` -> `/tmp/now-bootstrap-step24.txt`) were both
  empty diffs; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`. `ansible-lint` was retried with an explicit
  timeout and still did not produce a stable pass/fail summary in this VM
  (it consistently reaches collection install + syntax-check and then exits with
  a multiprocessing semaphore warning), so lint stabilization remains the next
  slice.

- [x] 2026-07-27: Follow-up corrections after review of the Phase 5
  operations/configuration doc refresh.
  Fixed two factual doc bugs in `doc/operations.md` by replacing the
  nonexistent env var `ARMORY_KEYCLOAK_HOST` with the real
  `ARMORY_PUBLIC_DOMAIN` reference, and replacing the nonexistent
  `keycloak_oidc` tag with the real `openbao_oidc` tag in both the targeted
  rerun commands and troubleshooting guidance. Also completed the previously
  open stale-row cleanup in `doc/configuration.md` by removing deleted
  component rows (`VSO_*`, Headlamp, trust-manager, k3s/OIDC selectors,
  realm-admin-rotator toggles, operator-version wording) and replacing them
  with current OpenShift-only knobs (`armory_privileged_tasks`,
  `armory_apps_domain`, `keycloak_public_base_url`,
  `openbao_audit_rotate_cron_schedule`, `keycloak_deployment_name`,
  `keycloak_admin_events_prune_*`).

- [x] 2026-07-27: Completed a Phase 5 slice 4 documentation refresh in
  `doc/operations.md` (manual-rotation + OpenShift teardown runbook updates).
  Removed stale k3s/VSO/headlamp/trust-manager workflow commands from the
  targeted rerun section, rewrote the readiness summary to match current checks,
  updated access and credential-retrieval guidance to OpenShift-only
  `kubectl`/`vagrant ssh default -c` commands, replaced the removed
  realm-admin rotator workflow with the manual `site.yml --tags keycloak_install`
  runbook, switched OpenBao audit rotation guidance from host `systemd` to the
  in-cluster `openbao-audit-rotate` CronJob, replaced teardown usage with
  `playbooks/teardown_openshift.yml -e teardown_confirm=true`, and refreshed the
  TLS troubleshooting note to CA-secret copy behavior. Validation in Vagrant:
  `site.yml` and `bootstrap.yml` syntax-check passed; `--list-tasks` snapshots
  (`/tmp/now-site-step22.txt` -> `/tmp/now-site-step23.txt`,
  `/tmp/now-bootstrap-step22.txt` -> `/tmp/now-bootstrap-step23.txt`) were both
  empty diffs; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`. Attempted `ansible-lint` remains an open item:
  in this VM it repeatedly stalled around collection/setup output (including
  `--offline`), so the lint-pass capture is deferred to the next slice.

- [x] 2026-07-27: Follow-up cleanup after the Phase 5 comment scrub review.
  Removed the stale Headlamp references left in comments/docs under
  `ansible/roles/{keycloak,openbao,readiness_check}` and the `openbao`
  provisioner-token policy comment, then removed the remaining dead edge-gateway
  rows from `doc/configuration.md` (`ARMORY_EDGE_GATEWAY_IP`,
  `ARMORY_EDGE_GATEWAY_INTERFACE`) so the documentation no longer mentions the
  deleted selector family at all. Validation in Vagrant stayed clean: the
  earlier `site.yml` / `bootstrap.yml` syntax-check and `--check` results still
  stand, and the follow-up greps for `headlamp` under `ansible/` and
  `edge_gateway_(ip|interface|excluded_cidrs|excluded_ifname_patterns)` in
  `doc/configuration.md` both returned no matches.

- [x] 2026-07-27: Completed Phase 5 slice 3 (comment scrub + stale prose cleanup).
  Rewrote stale k3s-by-contrast comments into direct OpenShift behavior prose
  across the known remaining Ansible sites: OpenShift inventory header and
  controller/CLI/storage notes (`inventories/openshift/group_vars/all.yml`),
  Envoy edge rationale header (`roles/envoy_proxy/defaults/main.yml`), Keycloak
  realm/admin-prune/deployment comments
  (`roles/keycloak/defaults/main.yml`,
  `roles/keycloak/templates/{admin-events-prune-cronjob,keycloak-deployment}.yaml.j2`),
  and OpenBao defaults/break-glass/audit rotation comments
  (`roles/openbao/defaults/main.yml`, `roles/openbao/tasks/{main,break_glass_mirror,break_glass_restore}.yml`,
  `roles/openbao/templates/audit-rotate-cronjob.yaml.j2`). Also renamed the
  OpenBao Kubernetes auth CA retrieval task/variable from k3s-specific naming
  to neutral naming in `roles/openbao/tasks/configure.yml`
  (`Get cluster CA certificate`, `_cluster_ca_cert`) with no behavioral change.
  Removed the stale deleted-variable row
  `edge_gateway_excluded_ifname_patterns` from `doc/configuration.md`.
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  `--list-tasks` diff (`/tmp/now-site-step21.txt` -> `/tmp/now-site-step22.txt`)
  showed only the expected task-name label rename, while
  `bootstrap.yml --list-tasks` diff
  (`/tmp/now-bootstrap-step21.txt` -> `/tmp/now-bootstrap-step22.txt`) was empty;
  `--check` recaps for both playbooks were `failed=0` after exporting `.env`
  with `set -a`; and `grep -R -n --include=*.yml --include=*.j2 --include=*.cfg k3s ansible/`
  returned no matches.

- [x] 2026-07-27: Completed Phase 5 slice 2 (`keycloak_cr_name` rename pass).
  Renamed `keycloak_cr_name` to `keycloak_deployment_name` across the live
  Keycloak role path (`roles/keycloak/defaults/main.yml`,
  `roles/keycloak/tasks/{main,deploy_operatorless,teardown}.yml`, and
  `roles/keycloak/templates/keycloak-deployment.yaml.j2`) so the variable name
  now matches the concrete workload kind. Renamed readiness-check's deployment
  selector to `readiness_check_keycloak_deployment_name` and rewired
  `roles/readiness_check/tasks/check_keycloak.yml` to use it. Updated the
  Keycloak role variable table in `roles/keycloak/README.md` accordingly.
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  `--list-tasks` diffs (`/tmp/now-site-step20.txt` ->
  `/tmp/now-site-step21.txt`, `/tmp/now-bootstrap-step20.txt` ->
  `/tmp/now-bootstrap-step21.txt`) were empty; and `--check` recaps for both
  playbooks were `failed=0` after exporting `.env` with `set -a`.

- [x] 2026-07-27: Post-slice follow-up cleanup after Phase 4 slice 7 review.
  Rewrote the misleading header in
  `roles/keycloak/templates/postgres.yaml.j2` so it no longer describes itself
  as a sibling to a removed k3s template, and updated
  `roles/keycloak/README.md` to remove the stale `local-path PVC` wording from
  the `keycloak_pg_storage_size` variable row.

- [x] 2026-07-27: Completed Phase 4 slice 7 (OpenShift-only defaults fold-in
  + snapshot script cleanup).
  Collapsed now-only-possible OpenShift values into role defaults by setting
  `keycloak_pg_image` in `roles/keycloak/defaults/main.yml` to
  `quay.io/sclorg/postgresql-16-c9s`, deleting
  `keycloak_pg_manifest_template`, and making
  `roles/keycloak/tasks/main.yml` render `postgres.yaml.j2` directly. Replaced
  `roles/keycloak/templates/postgres.yaml.j2` with the former OpenShift-safe
  manifest and deleted `roles/keycloak/templates/postgres-openshift.yaml.j2`.
  Moved OpenBao OpenShift posture into defaults
  (`openbao_disable_mlock: true`, `openbao_scc_name: nonroot-v2`) and removed
  those inventory overrides from
  `inventories/openshift/group_vars/all.yml` along with removed
  `keycloak_pg_*` override lines. Updated
  `scripts/capture_run_snapshot.sh` to drop `k3s`-specific command paths and
  use `kubectl`/`helm` with `KUBECONFIG` (plus optional `KUBECTL_BIN`) so it no
  longer carries stale k3s assumptions. Validation in Vagrant: `site.yml` and
  `bootstrap.yml` syntax-check passed; `--list-tasks` diffs
  (`/tmp/now-site-step19.txt` -> `/tmp/now-site-step20.txt` and
  `/tmp/now-bootstrap-step19.txt` -> `/tmp/now-bootstrap-step20.txt`) were
  empty; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`. Grep checks confirmed no remaining
  `inventories/development` or `k3s` references in
  `scripts/capture_run_snapshot.sh`, and no remaining Ansible references to
  `keycloak_pg_manifest_template` / `postgres-openshift.yaml.j2`.

- [x] 2026-07-27: Completed Phase 5 slice 1 (Ansible hygiene start).
  Added `ansible/ansible.cfg` with default OpenShift inventory
  (`inventories/openshift`) and `interpreter_python=auto_silent`, and replaced
  deprecated injected-fact usages in
  `inventories/openshift/group_vars/all.yml`
  (`ansible_env.HOME` -> `ansible_facts.env.HOME`, `ansible_user_id` ->
  `ansible_facts.user_id`). Also added `!ansible/ansible.cfg` to
  `.gitignore` so the new config is tracked. Validation in Vagrant: `site.yml` and
  `bootstrap.yml` syntax-check passed; `site.yml --list-tasks` diff
  (`/tmp/now-site-step18.txt` -> `/tmp/now-site-step19.txt`) was empty;
  `bootstrap.yml --list-tasks` diff
  (`/tmp/now-bootstrap-step18.txt` -> `/tmp/now-bootstrap-step19.txt`) was
  empty; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`.

- [x] 2026-07-27: Completed Phase 4 slice 6 (delete `inventories/development/`).
  Removed the two remaining development inventory files,
  `ansible/inventories/development/hosts.yml` and
  `ansible/inventories/development/group_vars/all.yml`, and repointed
  `.env.example` at the OpenShift inventory so the repo no longer ships a dead
  default inventory path. Validation in Vagrant: `site.yml` and
  `bootstrap.yml` syntax-check passed; `site.yml --list-tasks` diff was empty;
  `bootstrap.yml --list-tasks` diff was empty; and `--check` recaps for both
  playbooks were `failed=0` after exporting `.env` with `set -a`.

- [x] 2026-07-27: Cleaned up the now-stale live documentation references to
  the deleted development inventory. Updated `AGENTS.md` and
  `doc/configuration.md` to point at the OpenShift inventory's
  `group_vars/all.yml` instead. The Phase 5 comment-scrub item in
  `ansible/inventories/openshift/group_vars/all.yml` was intentionally left
  untouched for the later comment phase.

- [x] 2026-07-27: Completed Phase 4 slice 5 (helm dnf path).
  Removed the host-package install path from `roles/helm/tasks/main.yml`
  (deleted the `Ensure Helm is installed` dnf task and its gate), removed
  now-dead package defaults from `roles/helm/defaults/main.yml`
  (`helm_package_install_enabled`, `helm_package_name`, and
  `helm_package_state`), removed the obsolete OpenShift inventory override
  `helm_package_install_enabled` from
  `inventories/openshift/group_vars/all.yml`, and updated
  `roles/helm/README.md` to document validation + `helm-diff` behavior only.
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  `site.yml --list-tasks` diff (`/tmp/now-site-step17.txt` ->
  `/tmp/now-site-step18.txt`) showed only expected removal of `helm : Ensure
  Helm is installed`; `bootstrap.yml --list-tasks` diff
  (`/tmp/now-bootstrap-step17.txt` -> `/tmp/now-bootstrap-step18.txt`) was
  empty; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`. Static include/import target existence
  gate returned no missing task files, and a fresh k3s burn-down snapshot was
  captured after this slice.

- [x] 2026-07-27: Completed Phase 4 slice 4 (cert_manager install path).
  Deleted `roles/cert_manager/tasks/install.yml`, removed the install import
  from `roles/cert_manager/tasks/main.yml`, and removed now-dead
  install/Helm chart defaults from `roles/cert_manager/defaults/main.yml`
  (`certmanager_install_enabled`, `certmanager_tofu_work_dir`,
  `certmanager_chart_repo`, `certmanager_chart_name`,
  `certmanager_chart_version`, `certmanager_tofu_timeout_seconds`, and
  `certmanager_tofu_chart_values`). Also removed obsolete
  `certmanager_install_enabled` inventory overrides from both
  `inventories/openshift/group_vars/all.yml` and
  `inventories/development/group_vars/all.yml`, and updated
  `roles/cert_manager/README.md` to document reuse-only behavior.
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  `site.yml --list-tasks` diff (`/tmp/now-site-step16.txt` ->
  `/tmp/now-site-step17.txt`) showed only expected removal of the four
  cert-manager install tasks; `bootstrap.yml --list-tasks` snapshot was
  recaptured to `/tmp/now-bootstrap-step17.txt` with no observed delta; and
  `--check` recaps for both playbooks were `failed=0` after exporting `.env`
  with `set -a`.

- [x] 2026-07-27: Completed Phase 4 slice 3 (openbao firewall/NodePort
  residue removal).
  Deleted the dead firewalld cleanup task from
  `roles/openbao/tasks/install.yml`; removed the now-unused legacy defaults
  `openbao_node_port`, `openbao_firewall_manage`, and `openbao_firewall_zone`
  from `roles/openbao/defaults/main.yml`; removed the obsolete OpenShift
  inventory override/comment block for `openbao_firewall_manage` from
  `inventories/openshift/group_vars/all.yml`; and removed the matching stale
  variable docs from `roles/openbao/README.md`.
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  fresh task snapshots were captured to `/tmp/now-site-step16.txt` and
  `/tmp/now-bootstrap-step16.txt` and grepping those snapshots found no
  remaining "legacy OpenBao firewall" task entry; and `--check` recaps for
  both playbooks were `failed=0` after exporting `.env` with `set -a`.

- [x] 2026-07-26: Completed Phase 4 slice 2 (`edge_gateway_*` family and
  resolver chain removal).
  Deleted the edge-IP resolver chain end-to-end: removed the pre-task include of
  `common/tasks/resolve_edge_gateway_ip.yml` from both
  `playbooks/site.yml` and `playbooks/readiness_check.yml`; deleted
  `roles/common/tasks/resolve_edge_gateway_ip.yml`; removed the coupled OpenBao
  UI host-mapping tasks and `openbao_ingress_ip_effective` from
  `roles/openbao/tasks/install.yml`; removed
  `edge_gateway_ip_resolution_enabled` from OpenShift inventory; removed the
  dead development inventory `edge_gateway_*` block; and deleted both
  now-orphaned filter plugins (`ansible/filter_plugins/edge_network.py` and
  `ansible/roles/common/filter_plugins/edge_network.py`).
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  `site.yml --list-tasks` diff (`/tmp/now-site-step14.txt` ->
  `/tmp/now-site-step15.txt`) showed only expected task removals (resolver
  include + the two OpenBao ingress-IP mapping tasks);
  `bootstrap.yml --list-tasks` diff
  (`/tmp/now-bootstrap-step14.txt` -> `/tmp/now-bootstrap-step15.txt`) was
  empty; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`. Targeted grep gates found no remaining
  Ansible references to `resolve_edge_gateway_ip.yml`,
  `edge_gateway_ip_resolution_enabled`, `openbao_ingress_ip_effective`,
  `armory_ip_in_any_cidr`, `edge_gateway_ip_resolved`, or the deleted
  `edge_gateway_*` vars.

- [x] 2026-07-26: Completed Phase 4 slice 1 (readiness_check k3s/host/gateway
  removal).
  Deleted `roles/readiness_check/tasks/check_host.yml`,
  `roles/readiness_check/tasks/check_k3s.yml`, and
  `roles/readiness_check/tasks/check_gateway.yml`; removed the three matching
  includes from `roles/readiness_check/tasks/main.yml`; dropped the associated
  readiness toggles/defaults (`readiness_check_{host,k3s,gateway}_enabled`,
  `readiness_check_required_packages`, gateway label/namespace vars,
  `readiness_check_ingress_probe_ip`, and
  `readiness_check_ingress_firewall_zone`) from
  `roles/readiness_check/defaults/main.yml`; and removed the now-dead OpenShift
  inventory overrides for those toggles from
  `inventories/openshift/group_vars/all.yml`.
  Validation in Vagrant: `site.yml` and `bootstrap.yml` syntax-check passed;
  `site.yml --list-tasks` diff (`/tmp/now-site-step13.txt` ->
  `/tmp/now-site-step14.txt`) showed only the expected removal of the three
  readiness includes; `bootstrap.yml --list-tasks` diff
  (`/tmp/now-bootstrap-step13.txt` -> `/tmp/now-bootstrap-step14.txt`) was
  empty; and `--check` recaps for both playbooks were `failed=0` after
  exporting `.env` with `set -a`.

- [x] 2026-07-24: Completed a Phase 3 kubeconfig-selector cleanup slice
  (`k3s_kubeconfig_path` -> `armory_kubeconfig_path`).
  Removed the legacy alias line from
  `inventories/openshift/group_vars/all.yml`, switched
  `playbooks/bootstrap.yml` and `playbooks/teardown_openshift.yml` to direct
  `armory_kubeconfig_path` usage, and updated remaining role defaults
  (`automation_rbac`, `cert_manager`, `common`, `envoy_proxy`, `keycloak`,
  `openbao`, `openbao_oidc`, `readiness_check`, `registry`) so they no longer
  default through `k3s_kubeconfig_path`. Also renamed
  `readiness_check_k3s_kubeconfig` to `readiness_check_kubeconfig_path` and
  rewired `roles/readiness_check/tasks/main.yml` accordingly.
  Local Vagrant validation passed for `playbooks/site.yml` and
  `playbooks/bootstrap.yml` syntax-check plus `--check` (`failed=0` in both
  recaps). The `site.yml --list-tasks` diff against `/tmp/now-site-step12.txt`
  still showed the previously expected Keycloak operator/CR removal set,
  indicating step12 was stale relative to the already-completed Keycloak
  collapse; `/tmp/now-site-step13.txt` and `/tmp/now-bootstrap-step13.txt` are
  the new snapshots for subsequent diffs.

- [x] 2026-07-24: Completed the remaining Phase 3 Keycloak collapse slice.
  Finished the `keycloak_operator_install_method` / `keycloak_workload_kind`
  cleanup by deleting the temporary `realmimport.yaml.j2` scaffolding,
  deleting the operator-era `keycloak.yaml.j2` template, collapsing
  `roles/keycloak/tasks/main.yml` to the operatorless Deployment path only,
  and making `deploy_operatorless.yml` consume the new direct
  `roles/keycloak/templates/realm.json.j2` realm body template. Also removed
  the now-dead operator selector vars from the OpenShift inventory and the
  readiness-check Keycloak workload selector, and updated teardown/comments to
  match the deployment-only shape. Local Vagrant validation passed again for
  `playbooks/site.yml` and `playbooks/bootstrap.yml` syntax-check plus
  `--check` (`failed=0`), and the task-list diff showed only the expected
  Keycloak operator/CR/realm-import task removals.

- [x] 2026-07-24: Advanced the remaining Phase 3 Keycloak refactor with a
  low-risk realm-body transition slice in the operatorless path.
  Added a new direct `roles/keycloak/templates/realm.json.j2` canonical realm
  body template and switched
  `roles/keycloak/tasks/deploy_operatorless.yml` to render/import from it, while
  adding an explicit local safety assertion that compares the new direct JSON
  render to the legacy `realmimport.yaml.j2` lift-out output and fails fast on
  any byte drift. This implements the requested cheap guard for the highest-risk
  part of the remaining Keycloak work (Secret-fed `--import-realm` payload)
  without touching live-cluster state or claiming the full
  `keycloak_operator_install_method` selector collapse complete yet.
  Local Vagrant validation passed (`playbooks/site.yml` and
  `playbooks/bootstrap.yml` syntax-check and `--check`, both `failed=0`).

- [x] 2026-07-24: Corrected a post-Phase-2 regression where
  `ansible/roles/envoy_gateway/defaults/main.yml` had been accidentally
  resurrected in commit `eb24a2e` after the role-tree deletion in `f6d8911`.
  Deleted the orphaned defaults file again so no partial `envoy_gateway` role
  remains on disk, and updated
  `roles/readiness_check/defaults/main.yml` to stop reading deleted
  `envoy_gateway_*` trace/firewall vars, using the live `envoy_proxy_*`
  trace defaults instead. Local Vagrant validation passed for
  `playbooks/site.yml` and `playbooks/bootstrap.yml` (`--syntax-check` and
  `--check`, both `failed=0`), and the task-list diff
  (`/tmp/now-site-step11.txt` -> `/tmp/now-site-step12.txt`) was empty for
  both playbooks as expected for inert-code cleanup. Remaining `envoy_gateway`
  mentions under `ansible/` are doc-only comments/README text, to be handled
  in the later comment scrub.

- [x] 2026-07-24: Completed the Phase 3 `internal_https_caller_mode`
  selector collapse to the OpenShift-only port-forward path.
  Removed the dead ClusterIP branch from
  `roles/common/tasks/prepare_internal_https_caller_dns.yml`, removed
  `internal_https_caller_mode` gating from
  `roles/common/tasks/stop_port_forwards.yml`, and deleted the now-obsolete
  selector vars/comments from both inventories plus
  `roles/common/defaults/main.yml`. Local validation passed for
  `playbooks/site.yml` and `playbooks/bootstrap.yml` (`--syntax-check` and
  `--check`, both `failed=0`). Task-list diff
  (`/tmp/now-site-step10.txt` -> `/tmp/now-site-step11.txt`) showed only the
  expected removal of the two ClusterIP helper tasks in the two include call
  sites (no `bootstrap.yml` delta), and static include/import target checks
  found no missing referenced files.
  Next intended Phase 3 slice: collapse `keycloak_operator_install_method`
  to the `none` / operatorless Keycloak path.

- [x] 2026-07-24: Completed the Phase 2 `envoy_gateway` role-tree deletion.
  Deleted the complete `roles/envoy_gateway/` tree (defaults, meta, tasks,
  templates, and README). This closes the last k3s-only role directory that
  remained on disk after its `site.yml` entry had already been removed, and it
  removes the final source of `httproute`/`Gateway`-centric leftovers from the
  Ansible tree. Local Vagrant validation passed again for `site.yml` and
  `bootstrap.yml` syntax checks plus `--check` (`failed=0` in both recaps);
  the `site.yml` and `bootstrap.yml` task-list snapshots were unchanged from
  step 9, as expected for an unreferenced role-tree removal. Next intended
  Phase 3 slice remains `internal_https_caller_mode` collapse in
  `roles/common/tasks/prepare_internal_https_caller_dns.yml`.

- [x] 2026-07-24: Completed the flagged `openbao_oidc` hostAlias /
  edge-gateway lookup resolution slice.
  Removed the OpenBao OIDC hostAlias patch/restart/re-unseal chain from
  `roles/openbao_oidc/tasks/oidc_config.yml` and deleted the now-orphaned
  helper `roles/common/tasks/lookup_gateway_service.yml` plus obsolete
  `openbao_oidc` defaults that only fed that path. This removes dead code and
  the moving dependency on the already-deleted `envoy_gateway` role
  artifacts, but it does not prove the OpenBao pod can hairpin to the public
  Keycloak issuer host; that operational assumption is now recorded in the
  migration handoff §7 list before further selector collapse work.
  Local Vagrant validation passed for `site.yml` and `bootstrap.yml`
  (`--syntax-check` and `--check`, both `failed=0`), and `site.yml`
  task-list diff (`/tmp/now-site-step8.txt` -> `/tmp/now-site-step9.txt`)
  showed only the expected removal of gateway lookup + hostAlias/recreate
  tasks and the dependent unseal tasks in this role path, with no
  `bootstrap.yml` task delta.
  Next intended slice: collapse `internal_https_caller_mode` to OCP-only
  `port_forward` behavior in
  `roles/common/tasks/prepare_internal_https_caller_dns.yml`.

- [x] 2026-07-24: Completed a Phase 3 selector-collapse slice
  (`target_platform` removal in current OCP-only paths).
  Removed the last `target_platform`-driven `site.yml` gate by deleting the
  `envoy_gateway` role entry from `playbooks/site.yml`, removed the now-dead
  Keycloak platform assert block from `roles/keycloak/tasks/main.yml`, and
  removed the obsolete `target_platform` vars/comments from both inventories
  (`inventories/openshift/group_vars/all.yml` and
  `inventories/development/group_vars/all.yml`). Local Vagrant validation
  passed for `site.yml` and `bootstrap.yml` syntax checks; list-task diff
  (`/tmp/now-site-step7.txt` -> `/tmp/now-site-step8.txt`) showed only the
  expected removal of `envoy_gateway` tasks plus the deleted Keycloak assert,
  with no `bootstrap.yml` task delta; and `--check` passed for both playbooks
  (`site.yml failed=0`, `bootstrap.yml failed=0`). A repo grep now finds no
  remaining `target_platform` references under `ansible/`.
  Next intended Phase 3 slice remains the explicit `openbao_oidc` hostAlias /
  edge-gateway lookup verification called out as the only unknown before that
  chain can be safely deleted.

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

## Phase 3 — Collapse the platform selectors — ✅ COMPLETE (2026-07-24)

All eight selector rows collapsed to their OCP value and the variable deleted.
Verified: no `target_platform`, `edge_kind`, `armory_scheduler_kind`,
`internal_https_caller_mode`, `keycloak_operator_install_method`,
`keycloak_workload_kind`, or `k3s_kubeconfig_path` remain anywhere in `ansible/`;
`kubectl_bin` defaults to `oc`. Follow-on hygiene in Phase 5 then renamed
`keycloak_cr_name` to `keycloak_deployment_name` without changing behavior.

Record of what each row became (for audit; do not re-do):

| Variable | Outcome |
|---|---|
| `target_platform` | gone; `envoy_gateway` role + Keycloak assert deleted |
| `edge_kind` | gone; both `route.yml` files + `httproute.yaml.j2` + `apply_backend_ca_configmap.yml` deleted; live edge is `envoy_proxy/templates/routes.yaml.j2` |
| `armory_scheduler_kind` | gone; CronJob-only; host-timer scripts + systemd teardown removed |
| `internal_https_caller_mode` | gone; port-forward is unconditional |
| `keycloak_operator_install_method` / `keycloak_workload_kind` | gone; `keycloak.yaml.j2` + `realmimport.yaml.j2` deleted; realm body now `realm.json.j2` (YAML source → `to_json`) |
| `kubectl_bin` | default now `oc` |
| `k3s_kubeconfig_path` | renamed `armory_kubeconfig_path` across ~11 roles + `bootstrap.yml`/`teardown_openshift.yml`; k3s fallback path removed |

## Phase 4 — Residue sweep (k3s code + inventory collapse) — ✅ COMPLETE (2026-07-27)

> **Reality check (2026-07-24):** the four selector *families* are gone, but ~90
> `k3s` hits remain — most are comments (Phase 5), but several are **live k3s
> code still on disk**, inert only because an `_enabled` toggle is false on OCP.
> Track progress by the objective burn-down, not by "the selector is gone":
> ```bash
> grep -rc "k3s" ansible/ --include="*.yml" --include="*.j2" | grep -v ':0' | sort -t: -k2 -rn
> ```
> Phase 4 drives the *code* hits to zero; Phase 5 drives the *comment* hits to zero.

**Already done opportunistically during Phase 3 (do not re-do):**
- `common/tasks/apply_backend_ca_configmap.yml` — deleted (edge_kind slice).
- `common/tasks/lookup_gateway_service.yml` — deleted (hostAlias slice).
- `readiness_check/tasks/check_trace_boundary.yml` (Gateway-API variant) — deleted.
- **openbao_oidc hostAlias/gateway-lookup "unknown" — RESOLVED.** The chain was
  dead on OCP (gated on a Service that only `envoy_gateway` created) and is
  deleted. The *operational* question it papered over — can the OpenBao pod
  hairpin to the public Keycloak issuer — is now recorded as handoff §7 #10 with
  the in-namespace-Envoy fallback. No code action remains; do not reintroduce.
- `readiness_check` trace vars already repointed `envoy_gateway_* → envoy_proxy_*`.

**Remaining — suggested slice order (one commit each, §V gate between):**

1. **readiness_check k3s/host/gateway checks (biggest live-code chunk).**
   Delete `check_k3s.yml` (~114 lines), `check_host.yml`, `check_gateway.yml`;
   remove their three `include_tasks` from `readiness_check/tasks/main.yml`
   (lines ~22/26/44) and the `readiness_check_{host,k3s,gateway}_enabled` toggles
   + `readiness_check_k3s_*` / `readiness_check_gateway_*` / `_ingress_firewall_zone`
   / `_ingress_probe_ip` defaults. Drop `k3s`/`host` from any default component
   list. This clears ~48 of the k3s hits in one slice.

2. **The `edge_gateway_*` family (fully dead now, but still invoked).**
   Delete `common/tasks/resolve_edge_gateway_ip.yml` and its **two** invocation
   sites (`playbooks/site.yml` pre_tasks, `playbooks/readiness_check.yml`);
   remove `edge_gateway_ip_resolution_enabled` (both inventories); delete the
   openbao "Resolve effective gateway IP …" + "UI host resolves to gateway IP"
   tasks in `openbao/tasks/install.yml` and `openbao_ingress_ip_effective`;
   delete `readiness_check_ingress_probe_ip`. Then delete **both** copies of the
   filter plugin (`ansible/filter_plugins/edge_network.py` and
   `ansible/roles/common/filter_plugins/edge_network.py` — its only consumer was
   `resolve_edge_gateway_ip.yml`'s `armory_ip_in_any_cidr`; grep-confirm first).

3. **openbao firewall/NodePort residue.** Delete the firewalld task in
   `openbao/tasks/install.yml`, `openbao_firewall_*` and `openbao_node_port`
   defaults. (`openbao_firewall_manage: false` is already set in the OCP
   inventory; this removes the mechanism it disables.)

4. **cert_manager install path.** Delete `cert_manager/tasks/install.yml`, its
   helm/chart vars, and `certmanager_install_enabled` (reuse-only is the only
   mode). Keep `rbac.yml` + `issuer.yml`. Remove the `install.yml` import from
   `cert_manager/tasks/main.yml`.

5. **helm dnf path.** Delete the dnf-install task + `helm_package_*` vars in the
   `helm` role; keep the version check + diff-plugin install.

6. **Delete `inventories/development/` entirely.** This is the k3s inventory;
   removing it clears a large block of remaining k3s hits at once. (Confirm no
   tooling references it — grep `inventories/development` across repo + scripts.)

7. **Move now-only-possible values into role defaults.** Rename
   `postgres-openshift.yaml.j2` → `postgres.yaml.j2` (delete the old k3s one if
   any remains) and drop the `keycloak_pg_manifest_template` override; fold
   `keycloak_pg_image`, `openbao_disable_mlock`, `openbao_scc_name` into defaults.
   Keep genuine cluster facts in the inventory (apps domain, hostnames, `tex26-*`
   namespaces, storage class, labels, break-glass/watcher toggles,
   `keycloak_openbao_*_path`).
- **scripts/capture_run_snapshot.sh**: remove k3s references (can ride any slice).

## Phase 5 — Hygiene

- Add `ansible/ansible.cfg` (default inventory, `interpreter_python=auto_silent`);
  fix `INJECT_FACTS_AS_VARS` deprecations (`ansible_env.HOME` →
  `ansible_facts.env.HOME`, `ansible_user_id` → `ansible_facts.user_id`).
- Play retitle: `site.yml` play 1 already renamed to "Base configuration for
  OpenShift deployment" (and the second k3s-control-plane play was merged out in
  Phase 2). Nothing left here unless another play name surfaces.
- Rename `keycloak_cr_name` → `keycloak_deployment_name` — ✅ complete
  (2026-07-27); behavior unchanged (`keycloak-service` remains derived from
  the deployment name).
- **Comment scrub (this is what makes the final `grep -rn "k3s"` gate pass).**
  After Phase 4, the remaining k3s hits are all comments — rewrite them to
  describe OCP behavior directly rather than by contrast with k3s. Known sites:
  `envoy_proxy/defaults` header, `keycloak-deployment.yaml.j2`,
  `postgres-openshift.yaml.j2`, `admin-events-prune-cronjob.yaml.j2`,
  `audit-rotate-cronjob.yaml.j2`, `openbao/defaults` + break-glass task headers,
  `openbao/tasks/configure.yml` "Get k3s cluster CA" (rename to "cluster CA" —
  `kube-root-ca.crt` exists on OCP, the task is correct, only the label is wrong),
  `helm` role headers, `cert_manager/defaults`, OCP inventory prose. Keep genuine
  historical rationale in `doc/decisions/`, not in task files.
- `ansible/inventories/openshift/group_vars/all.yml:9` — header comment still
  reads "Deltas from inventories/development are grouped and justified"; that
  inventory was deleted in slice 6. Rewrite to describe the OCP inventory on
  its own terms, not as a diff against the removed k3s inventory.
- `doc/configuration.md:50` — documents `edge_gateway_excluded_ifname_patterns`
  as a live tunable; the variable was deleted in slice 2. Drop the row (or
  replace it if a genuine OCP-relevant successor exists).
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
diff /tmp/prev-site.txt /tmp/now-site.txt   # vs the PREVIOUS slice's snapshot; every disappearance explained by this slice
ansible-playbook -i inventories/openshift playbooks/site.yml --check      # failed=0 (templating oracle only)
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --check # failed=0
# include_tasks blindness compensation: no file may be referenced that no longer exists
grep -rn "include_tasks\|import_tasks\|tasks_from" roles/ playbooks/ --include="*.yml" \
  | grep -oP "(include_tasks|import_tasks|tasks_from)[:=]?\s*\K[\w./]+\.yml" | sort -u \
  | while read f; do find roles -name "$(basename $f)" | grep -q . || echo "MISSING: $f"; done
```

Three cheap checks that catch the failure modes the gates above miss (all three
have produced findings this run — orphan files, resurrected files, garbled
comments are invisible to Ansible's own tooling):
```bash
find roles -type d -empty                          # empty role skeletons after a deletion
git log --stat -1                                  # did this commit touch ONLY what the slice intended?
grep -rc "k3s" ansible/ --include="*.yml" --include="*.j2" | grep -v ':0' | sort -t: -k2 -rn  # burn-down
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
