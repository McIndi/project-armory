# ADR-013: Raft integrated storage

**Status:** Accepted

## Context

Vault requires a storage backend for persisting encrypted secrets and cluster state.
Options include:

- **Consul** — HashiCorp's original recommended backend. Adds a significant operational
  dependency (a separate Consul cluster to deploy and maintain).
- **External databases** (PostgreSQL, MySQL, etc.) — Supported but adds another
  service dependency.
- **Raft integrated storage** — Vault manages its own consensus-based storage
  internally. No external dependencies. Supported for production use since Vault 1.4.

## Decision

Use **Raft integrated storage** with a single node. Data is persisted to `deploy_dir/data`
on the host, mounted into the container.

## Consequences

- No external storage dependency — the entire deployment is self-contained.
- Single-node Raft is not highly available. If the container stops, Vault is
  unavailable until restarted and unsealed.
- Scaling to HA requires a multi-node Raft cluster — each node gets its own container
  and data directory, and `performance_multiplier` and peer configuration must be set.
  This is a future concern; the single-node setup provides a clear upgrade path.
- Raft data is included in `tofu destroy` cleanup (the entire `deploy_dir` is removed).
  This is intentional for a demo — a production deployment would back up the data
  directory before any destructive operation.
