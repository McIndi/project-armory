# ADR-008: OpenTofu Vault provider over shell scripts for Vault configuration

**Status:** Accepted

## Context

Vault configuration (PKI mounts, roles, auth methods, policies) was initially
implemented as `pki-setup.sh` — a bash script with idempotency guards. As the scope
of Vault configuration grew (AppRole, per-service policies, wrapped secret_id
generation), the shell script approach had increasing limitations:

- Idempotency logic is hand-rolled and error-prone.
- Shell scripts do not integrate with OpenTofu state — no drift detection, no plan
  preview, no structured outputs.
- Adding new configuration requires extending the script with more guard logic.
- Output values (role_id, wrapped tokens) must be captured manually.

The `hashicorp/vault` Terraform provider (compatible with both Vault and OpenBao)
manages Vault resources declaratively with full state tracking.

## Decision

Replace `pki-setup.sh` with a dedicated `vault-config/` OpenTofu module using the
`hashicorp/vault` provider. All Vault configuration — PKI hierarchy, auth methods,
policies, AppRole roles — is expressed as OpenTofu resources.

`pki-setup.sh` is deleted once `vault-config/` is validated.

## Consequences

- Vault configuration is declarative, idempotent by nature, and benefits from
  `tofu plan` before applying.
- Drift between desired and actual Vault state is detectable and correctable with
  `tofu apply`.
- The provider requires a live, unsealed Vault to apply — creating a two-phase
  dependency: `vault/` must be applied and the operator must complete the init/unseal
  key ceremony before `vault-config/` can run. This is inherent to the architecture,
  not a flaw.
- Per-service Vault resources (policies, AppRole roles) live in each service's own
  module, keeping service concerns self-contained.
