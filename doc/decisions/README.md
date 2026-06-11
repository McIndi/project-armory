# Decision Records

Short records of architecturally significant decisions. One file per
decision, numbered, never rewritten — a reversal gets a new record that
supersedes the old one.

Records 0001–0003 were written retrospectively (2026-06-11) from the plan
documents now archived in [../handoffs/](../handoffs/), which contain the
full analysis.

| # | Decision | Status |
|---|---|---|
| [0001](0001-opentofu-to-helm.md) | Remove OpenTofu; drive Helm releases directly | implemented |
| [0002](0002-standalone-keycloak.md) | Standalone Keycloak (operator + Postgres StatefulSet); Agent Stack moves out | implemented |
| [0003](0003-trust-manager-ca-distribution.md) | Declarative CA distribution via trust-manager | implemented |
| [0004](0004-declarative-audit-device.md) | OpenBao audit device via server config, not API | implemented |
| [0005](0005-track-latest-upstream.md) | Track latest upstream during development; pin only at ship time | policy |
| [0006](0006-defer-kubernetes-core.md) | Keep `command`-module kubectl/helm; defer `kubernetes.core` | deferred decision |
| [0007](0007-scoped-provisioner-token.md) | Scoped provisioner token replaces root token for automation | accepted, not yet implemented |
