# 0005 — Track latest upstream during development; pin at ship time

Status: policy (2026-06-11)

## Context

Several chart/component versions default to "latest" (`openbao_chart_version`,
`certmanager_chart_version`, `nginx_ingress_chart_version`,
`trust_manager_chart_version`, `k3s_version`). When OpenBao v2.4 broke the
API-based audit-device enable ([0004](0004-declarative-audit-device.md)),
version pinning was proposed as the remedy.

## Decision

During development, deliberately track the latest supported upstream
versions. Breakage caused by upstream security improvements is signal — the
correct response is to fix forward to the new supported behavior, not to pin
into the deprecated one or use legacy escape hatches. Version pinning is a
reproducibility step taken once, at the end of the project, together with a
documented upgrade procedure (tracked in the backlog).

## Consequences

A rebuild may break when upstream moves; that is accepted and treated as
work to absorb promptly. In exchange, the architecture demonstrates current
best practice rather than a frozen snapshot of it.
