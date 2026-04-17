# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for Project Armory.
Each ADR documents a significant decision, the context that drove it, and the
consequences — including trade-offs accepted.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](ADR-001-openbao-opentofu-standins.md) | OpenBao and OpenTofu as open-source standins | Accepted |
| [ADR-002](ADR-002-three-tier-pki-hierarchy.md) | Three-tier PKI hierarchy | Accepted |
| [ADR-003](ADR-003-ecdsa-p384-keys.md) | ECDSA P-384 for all cryptographic keys | Accepted |
| [ADR-004](ADR-004-podman-exec-canonical-interface.md) | podman exec as canonical CLI interface | Accepted |
| [ADR-005](ADR-005-world-readable-tls-artifacts.md) | World-readable TLS artifacts | Accepted |
| [ADR-006](ADR-006-selinux-shared-volume-labels.md) | Shared SELinux volume labels | Accepted |
| [ADR-007](ADR-007-no-host-port-publishing.md) | No host port publishing | Accepted |
| [ADR-008](ADR-008-opentofu-vault-provider.md) | OpenTofu Vault provider over shell scripts | Accepted |
| [ADR-009](ADR-009-vault-agent-sidecar.md) | Vault Agent sidecar for service identity | Accepted |
| [ADR-010](ADR-010-response-wrapping-secret-id.md) | Response wrapping for AppRole secret_id delivery | Accepted |
| [ADR-011](ADR-011-separate-opentofu-modules.md) | Separate OpenTofu modules per concern | Accepted |
| [ADR-012](ADR-012-local-tfstate-demo-limitation.md) | Local tfstate accepted as demo limitation | Accepted |
| [ADR-013](ADR-013-raft-integrated-storage.md) | Raft integrated storage | Accepted |
| [ADR-014](ADR-014-conditional-mlock.md) | Conditional mlock for OpenBao compatibility | Accepted |
| [ADR-015](ADR-015-pytest-integration-testing.md) | pytest + hvac for end-to-end integration testing | Accepted |
| [ADR-016](ADR-016-webserver-vault-agent-sidecar.md) | Webserver service — Vault Agent sidecar for certificate delivery | Accepted |

## Format

Each ADR follows the Nygard format: **Context** → **Decision** → **Consequences**.
