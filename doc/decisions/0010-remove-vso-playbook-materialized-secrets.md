# 0010 — Remove Vault Secrets Operator; playbook materializes Secrets directly

Status: implemented (2026-07-24, Phase 1 of the OpenShift isolation plan)

## Context

The k3s design ran the Vault Secrets Operator (VSO) — `VaultConnection` /
`VaultAuth` / `VaultStaticSecret` CRs synced OpenBao KV entries into
Kubernetes Secrets for Keycloak's DB and realm-admin credentials, and a
CronJob-based rotator periodically wrote fresh passwords to OpenBao and
depended on VSO for the last hop into the namespace Secret.

Two problems surfaced once this branch targeted OpenShift specifically:

1. **The originally planned Phase-0 split (install VSO, wire it up later) was
   unworkable.** VSO's hardened chart mounts the kube-rbac-proxy TLS secret as
   a pod volume and its install waits on rollout — splitting install from
   wiring stalls bootstrap in `ContainerCreating`.
2. **The rotator's dependency chain only half-survives an OpenShift port.**
   It authenticates to OpenBao via a k8s-auth role created in
   `roles/openbao/tasks/consumer_wiring.yml`, and writes the new password to
   OpenBao KV — but VSO performs the actual sync into the namespace Secret.
   Without VSO, a rotation would silently strand every Secret consumer:
   OpenBao holds the new password, the Secret still holds the old one.

## Decision

**Remove VSO entirely.** OpenBao remains the audited source of truth for
every credential. The playbook (running as `tex26-automation`) writes the
derived Kubernetes Secret itself, immediately after writing the same value to
the OpenBao KV entry — no operator, no CRDs, no sync loop, one fewer moving
part on a platform where nothing about VSO's hardened-chart assumptions had
been re-validated.

**Rotation-driven secret sync is out of scope.** The rotator CronJob, its
`realm_admin_rotator.yaml.j2` template, its SA/Role, and every
`keycloak_rotator_*` var are deleted along with it — there is no remaining
mechanism to keep OpenBao and the Secret in sync after the fact. To rotate a
credential: re-run `ansible-playbook playbooks/site.yml --tags keycloak`,
which regenerates the value and rewrites both OpenBao and the Secret
together. This is documented as the manual-rotation runbook in
`doc/operations.md`.

`roles/openbao/tasks/consumer_wiring.yml` is deleted in full — every block in
it existed only to give VSO (or the rotator, or headlamp/delve, all removed
elsewhere in this same isolation effort) a Kubernetes-auth path into OpenBao.
Kubernetes auth in OpenBao itself is **not** removed: cert-manager's Vault
issuer still authenticates that way, and the `openbao-tokenreview`
ClusterRoleBinding remains required.

## Consequences

`roles/vso/`, `charts/vso-hardened/`,
`roles/readiness_check/tasks/check_vso.yml`, and every `vso_*` /
`VSO_CHART_*` reference across both inventories and env plumbing are gone.
`playbooks/bootstrap.yml` is now env_guard → automation_rbac → preflight
only — VSO install was one of its stated reasons to exist; the remaining
reasons (namespaces, SA grants, the three privileged bindings) stand
unchanged. `automation_rbac_namespace_rules` drops its
`secrets.hashicorp.com` grant (the preflight permission count adjusts itself,
since grants and checks expand from the same matrix).

Credentials are only as fresh as the last playbook run — there is no
continuous reconciliation. Given this cluster is dedicated to a single
project (not multi-tenant, see the migration handoff), and rotation was
already a manual, deliberate act rather than a background process, this
tradeoff was accepted rather than re-solved on OpenShift.
