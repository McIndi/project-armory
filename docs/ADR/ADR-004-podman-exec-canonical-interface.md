# ADR-004: podman exec as canonical CLI interface

**Status:** Accepted

## Context

Vault operations (init, unseal, status checks, manual cert issuance) require a CLI.
The Vault/OpenBao CLI can be installed on the host, but this creates a dependency on
the host environment — the correct version must be installed, `VAULT_ADDR` and
`VAULT_CACERT` must be configured, and the setup differs across operating systems.

The OpenBao container image bundles the `bao` binary and has the correct environment
variables pre-configured (`VAULT_ADDR`, `VAULT_CACERT`, `BAO_ADDR`, `BAO_CACERT`).

## Decision

Use `podman exec armory-vault bao <command>` as the canonical way to interact with
Vault from the host. No host CLI installation is required or documented as a
prerequisite.

`tofu output` provides helper outputs (`init_command`, `unseal_command_example`) that
are pre-formatted as `podman exec` commands.

## Consequences

- Zero host CLI dependencies — works identically on any machine that can run Podman.
- The container must be running to execute any CLI command. Commands cannot be run
  against a stopped or sealed Vault without starting the container first.
- Users who prefer a host CLI can still install it; the README documents how to set
  `VAULT_ADDR` and `VAULT_CACERT` for host CLI use.
