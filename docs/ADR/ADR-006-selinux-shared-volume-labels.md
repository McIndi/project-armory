# ADR-006: Shared SELinux volume labels (:z)

**Status:** Accepted

## Context

On SELinux-enabled hosts (Fedora, RHEL, etc.), Podman volume mounts require an SELinux
label to allow container access to host files. Two options exist:

- **`:Z` (private)** — Applies a unique Multi-Category Security (MCS) label to the
  files. Each new container gets a different MCS label, and relabels the host files to
  match. If the container is recreated (e.g., by `tofu apply`), the new container's MCS
  label differs from the running container's, causing access denial. During testing this
  caused the running `armory-vault` container to lose access to its own data directory
  when a test container was briefly started with `:Z` on the same path.
- **`:z` (shared)** — Applies a shared SELinux type label without an MCS restriction.
  Any container can access the files. Labels survive container recreation.

## Decision

Use `:z` (shared label) on all volume mounts.

## Consequences

- Volume mounts survive container recreation without SELinux access failures.
- The shared label means any container on the system with access to the path can read
  the files — the MCS isolation layer is absent. This is consistent with the
  world-readable permission decision (ADR-005); both trade per-container isolation for
  operational reliability on a single-user host.
- On hosts without SELinux, the `:z` flag is ignored — no negative effect.
