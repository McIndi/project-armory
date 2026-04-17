# ADR-005: World-readable TLS artifacts

**Status:** Accepted

## Context

Vault's container entrypoint drops privileges to an internal `openbao` user (UID 100)
before reading configuration and TLS files. In rootless Podman, container UIDs are
mapped through the host user's subuid range — UID 100 inside the container maps to a
subuid on the host that does not match the file owner (the user running `tofu apply`).

Several approaches were considered:

- **`BAO_SKIP_ROOT_DROP`** — OpenBao-specific env var to skip privilege drop. Rejected
  because it couples the solution to OpenBao-specific behaviour that may change and
  does not work with HashiCorp Vault.
- **`user:` directive in compose** — Podman-specific `:U` flag rewrites file ownership.
  Rejected for the same portability reason.
- **Restrictive permissions with ACLs** — Complex, OS-specific, not portable.
- **World-readable files** — Simple, portable across Docker/Podman, rootless/rootful.

## Decision

Set all TLS artifacts to world-readable permissions:

| File | Permission |
|------|------------|
| `config/vault.hcl` | `0644` |
| `tls/ca.crt` | `0444` |
| `tls/vault.crt` | `0444` |
| `tls/vault.key` | `0444` |

Directories are set to `0755` (config, tls) or `0777` (data, logs) so the container
user can traverse and write as needed.

## Consequences

- Works identically with Docker, Podman (rootless and rootful), and any OCI runtime
  without engine-specific flags.
- `vault.key` (the server TLS private key) is readable by any local user on the host.
  On a single-user machine this is an acceptable trade-off. On a shared host it is a
  meaningful exposure — restrict access to `deploy_dir` at the OS level.
- This is documented in the Security Trade-offs section of the README.
