# 0004 — OpenBao audit device via server config, not API

Status: implemented (2026-06-11)
Source: [handoffs/openbao-audit-device-handoff.md](../handoffs/openbao-audit-device-handoff.md)

## Context

The audit device was first implemented as `sys/audit` API calls from
Ansible. OpenBao v2.4+ rejects API-driven audit device creation (HTTP 400):
upstream considers it unsafe, since a `file` device can write arbitrary
paths and a `socket` device arbitrary sockets. A legacy escape hatch exists
(`unsafe_allow_api_audit_creation`) but is explicitly named unsafe.

## Decision

Declare the device in the OpenBao server config (an `audit "file" "file"`
stanza in `roles/openbao/templates/values.yaml.j2`), reconciled by OpenBao
at startup and on SIGHUP. Do not use the unsafe flag. Storage is a dedicated
PVC (`auditStorage` in the Helm chart); rotation is a host systemd timer
that renames the log and sends SIGHUP.

## Consequences

Idempotency is inherent (no enable tasks in Ansible). The device exists from
first boot. This incident also produced the versioning policy in
[0005](0005-track-latest-upstream.md): tracking latest upstream surfaced the
unsafe pattern instead of freezing it in place.
