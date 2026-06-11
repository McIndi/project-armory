# 0006 — Keep command-module kubectl/helm; defer kubernetes.core

Status: deferred decision (revisit after current security work lands)
Source: [handoffs/migration_opentofu_to_helm.md](../handoffs/migration_opentofu_to_helm.md) §2,
[../simplification-opportunities.md](../simplification-opportunities.md) #2

## Context

All Kubernetes objects are applied via `k3s kubectl` `command` tasks and
Helm via `helm upgrade --install`, with hand-written `changed_when` stdout
matching (~31 apply tasks, ~54 stdout greps, 9 helm calls at last count).
The `kubernetes.core` collection would give real idempotency, diff
reporting, and dict-based Helm values, at the cost of adding the collection
plus `python3-kubernetes` to the VM.

## Decision

Stay dependency-free for now. The OpenTofu removal ([0001](0001-opentofu-to-helm.md))
chose the command-module idiom to avoid new dependencies; the migration doc
flagged `kubernetes.core` as the follow-up "once the tofu removal is
proven". It is proven; the migration remains the largest single
maintainability win but touches every role, so it is sequenced **after** the
security items (provisioner token, etc.) rather than alongside them.

## Consequences

Until migrated, new tasks follow the existing idiom (see AGENTS.md). The
brittle stdout-based `changed_when` pattern remains a known cost. When the
migration happens it should be wholesale, not mixed per-role.
