# 0008 - Staged `kubernetes.core` migration restores idempotency

Status: accepted (stage plan approved 2026-06-17)
Source: [../handoffs/kubernetes-core-idempotency-plan.md](../handoffs/kubernetes-core-idempotency-plan.md)
Supersedes: [0006](0006-defer-kubernetes-core.md) wholesale-only migration clause

## Context

The current `command`-based `helm upgrade --install` and `kubectl apply` pattern
causes run-to-run churn and hides true idempotency behind stdout parsing.
Remaining churn is concentrated in Helm release revisions and the Keycloak
operator/apply path. The repository now prioritizes restoring no-op reruns over
maintaining a fully dependency-free Ansible control plane.

## Decision

Adopt `kubernetes.core` in staged, per-role increments rather than a wholesale
switch. Transitional mixed mode is explicitly allowed while the migration is in
progress.

Accept runtime dependencies required for the module path:
- `kubernetes.core` Ansible collection (unpinned during development)
- Python `kubernetes` library for `kubernetes.core.k8s*`
- Helm `diff` plugin for accurate `kubernetes.core.helm` no-op detection

Use an explicit module auth contract for all `kubernetes.core.k8s`,
`kubernetes.core.k8s_info`, and `kubernetes.core.helm` tasks:
- pass `kubeconfig: "{{ <role>_kubeconfig_path }}"` on each task, pointing at a
  kubeconfig **readable by the unprivileged runtime user** (`vagrant`)
- the runtime kubeconfig is a copy of `/etc/rancher/k3s/k3s.yaml` placed at
  `/home/vagrant/.kube/config` (owner `vagrant`, mode `0600`) by the `k3s` role

**Why not `become: true` (corrected 2026-06-17):** the original contract said to
add `become: true` when unprivileged. That does **not** work for these modules.
`kubernetes.core` reads file arguments such as `kubeconfig` in a controller-side
**action plugin** that runs as the unprivileged login user *before* privilege
escalation — so a root-owned `0600` kubeconfig fails with `[Errno 13] Permission
denied` even under global `ANSIBLE_BECOME=True` (proven in Stage 1: the legacy
`helm` *command* task read the same path fine as root, but the migrated
`kubernetes.core.helm` task did not). The fix is a runtime-user-readable
kubeconfig, not escalation. (Alternative considered and rejected for the hardened
posture: `--write-kubeconfig-mode 0644`, which exposes cluster-admin credentials
to every local user.)

Residual `command` use remains allowed where there is no clean module mapping:
`rollout restart`, `rollout status`, `create token`, `cluster-info`, and
`exec` (unless replaced with `k8s_exec` in a targeted follow-up).

## Consequences

Migration can be validated role-by-role with smaller blast radius and faster
rollback points. During transition, code conventions are mixed by design, with
new Kubernetes apply/read tasks preferring `kubernetes.core` modules and
legacy command tasks retained only for the documented allowlist or untouched
roles pending migration.
