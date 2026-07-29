# 0011 — Abandon "steer by inventory, never fork roles"; `ocp-deployment` targets OpenShift only

Status: implemented (2026-07-2x, OpenShift isolation plan)

## Context

The `ocp-deployment` branch originally followed a rule carried over from
`main`: **steer by inventory, never fork roles.** Nearly all platform
behavior lived in `ansible/inventories/openshift/group_vars/all.yml` via
selector variables (`target_platform`, `edge_kind`, `armory_scheduler_kind`,
`internal_https_caller_mode`, `armory_privileged_tasks`,
`keycloak_operator_install_method`, `kubectl_bin`, and others), and role task
files stayed textually identical to `main` so the branch would keep merging
cleanly. Preference was always a `when:` guard or a variable over deleting or
rewriting a task.

This bought clean merges with `main` at the cost of permanent complexity: every
role carried both its k3s and OpenShift paths side by side, dead k3s-only
roles (`k3s`, `kernel_tuning`, `system_update`, `host_dependencies`,
`headlamp`, `envoy_gateway`, `delve`) stayed gated off rather than removed,
and selector variables had to be threaded through code that would only ever
see one branch of the condition on this deployment.

## Decision

**Abandon the rule for `ocp-deployment`.** This branch now targets
**only** the OpenShift deployment of project-armory — dual-platform support
and merge-cleanliness with `main` are deliberately given up. K3s-only roles,
playbooks, selector variables, and every `when:` branch that existed solely
to skip OpenShift-irrelevant behavior are deleted outright rather than gated.
Task files are rewritten to describe OpenShift behavior directly instead of
by contrast with k3s — including in comments, which are scrubbed of
k3s-relative phrasing (e.g. "Get k3s cluster CA" → "Get cluster CA";
`kube-root-ca.crt` exists on OpenShift too, only the label was wrong).

This is a one-way door for this branch: reintroducing k3s support later means
either reverting to `main`'s inventory-steered design or re-adding the
deleted roles/selectors from scratch. That tradeoff was accepted because the
branch's actual purpose — an OpenShift-only deployment of project-armory —
was never going to need k3s again, and the ongoing cost of carrying both
paths (in every role, every inventory, every doc) outweighed the value of a
merge path that would not be used.

## Consequences

The branch is smaller and its OpenShift behavior is no longer conditional —
what's in the tree is what runs, with no gated-off dead code to reason past.
`doc/plans/ocp-isolation-plan.md` §V's k3s burn-down grep (`grep -rn "k3s"`
across `ansible/` for `*.yml`, `*.j2`, `*.cfg`, expecting zero hits) is the
objective proof this held. Going forward, `main` remains the dual-platform
codebase; `ocp-deployment` is not intended to merge back into it, and any
future k3s-relevant fix made on `main` will need to be manually ported to
this branch if it still applies.
