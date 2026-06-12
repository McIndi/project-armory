# 0007 — Scoped provisioner token replaces root token for automation

Status: accepted, implemented (plan ready 2026-06-11; executed 2026-06-12)
Source: [../handoffs/openbao-provisioner-token-handoff.md](../handoffs/openbao-provisioner-token-handoff.md)

## Context

Ansible authenticates every OpenBao call with the root token decrypted from
disk. In-cluster consumers already follow least privilege (per-consumer
policies via Kubernetes auth); the automation itself does not, and audit log
entries for automation are indistinguishable root activity.

## Decision

The openbao role (which legitimately needs root for bootstrap) mints a
periodic orphan service token bound to an `ansible-provisioner` policy
scoped to the exact paths the keycloak, headlamp, and readiness_check roles
touch. The token is stored Ansible-Vault-encrypted like the init keys,
validated and renewed on every run, and re-minted with root if invalid.
Root becomes bootstrap + break-glass only. Kubernetes auth was rejected for
Ansible because it runs on the VM host, not in a pod.

## Consequences

Automation gets its own identity in the audit log and a bounded blast
radius. Adds one more encrypted artifact under `/opt/openbao/` sharing the
existing `.vault-pass` (co-location caveat unchanged). Implementation
details, policy text, and validation matrix are in the handoff document;
once executed, move that document to [handoffs/](../handoffs/) and update
this record to "implemented".
