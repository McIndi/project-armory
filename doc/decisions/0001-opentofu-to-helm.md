# 0001 — Remove OpenTofu; drive Helm releases directly

Status: implemented
Source: [handoffs/migration_opentofu_to_helm.md](../handoffs/migration_opentofu_to_helm.md)

## Context

OpenTofu was used only as a thin wrapper around `helm_release` — no data
sources, modules, remote state, or outputs. It added a second state store
(`terraform.tfstate`) on top of Helm's own in-cluster release state; the two
disagreed on re-runs, and the playbooks spent ~150 lines reconciling drift.

## Decision

Remove OpenTofu entirely. Deploy Helm releases with
`helm upgrade --install` via `ansible.builtin.command`, values rendered to a
temp file per role. Chosen over `kubernetes.core.helm` to stay
dependency-free (see [0006](0006-defer-kubernetes-core.md)).

## Consequences

One source of release truth (Helm). The drift-fighting cleanup tasks are
gone. Cost: hand-written `changed_when` logic on command tasks instead of
module-native change reporting.
