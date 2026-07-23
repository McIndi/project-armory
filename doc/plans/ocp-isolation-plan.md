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
