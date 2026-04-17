# ADR-007: No external port publishing for Vault

**Status:** Accepted

## Context

Vault listens on ports 8200 (API/UI) and 8201 (cluster). Initially both were published
to all interfaces (`ports: ["8200:8200", "8201:8201"]`). As the architecture evolved,
two concerns arose:

1. Services communicate with Vault via the compose network — no host-side mapping needed
   for service-to-service traffic.
2. Host admin tools (OpenTofu Vault provider, vault CLI) do need to reach the Vault API
   to configure it — specifically the `vault-config/` module and the `podman exec`
   interface.

Port 8201 is for Raft cluster peer communication. In a single-node deployment no
inter-node traffic occurs — publishing it serves no purpose.

## Decision

Bind port 8200 to **localhost only** (`127.0.0.1:8200:8200`). The cluster port 8201 is
not published.

Within the compose network, services reach Vault at `https://armory-vault:8200`. From
the host, admin tools reach Vault at `https://127.0.0.1:8200`. External machines on
the network cannot reach the Vault API.

The `api_port` and `cluster_port` variables were removed — ports 8200 and 8201 are
hardcoded as container-internal bind addresses in `vault.hcl`.

## Consequences

- Vault is unreachable from external machines without explicitly changing the port
  binding to `0.0.0.0:8200:8200`.
- Host admin tools (`vault-config/` OpenTofu module, browser UI, host CLI) work
  without modification.
- All service-to-service Vault traffic stays within the compose network.
- The distinction between "localhost-only" and "no publishing" is meaningful: this
  decision reduces external attack surface while preserving local operability.
