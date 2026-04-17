# ADR-014: Conditional mlock for OpenBao compatibility

**Status:** Accepted

## Context

HashiCorp Vault uses `mlock` (via the `IPC_LOCK` capability) to prevent secrets from
being swapped to disk. The `disable_mlock` directive in `vault.hcl` controls this
behaviour.

OpenBao v2.0+ removed mlock support entirely. If `disable_mlock = false` is present
in the config, OpenBao v2+ logs an error and fails to start. If `disable_mlock = true`
is present, it is silently ignored (or may also produce a warning in some versions).
HashiCorp Vault expects the directive to be present and respects it.

This creates an incompatibility: a config that works for HashiCorp Vault breaks
OpenBao, and vice versa if the directive is absent.

## Decision

Make the `disable_mlock` directive conditional in `vault.hcl.tpl`:

```hcl
%{ if disable_mlock ~}
disable_mlock = true
%{ endif ~}
```

The directive is only emitted when `disable_mlock = true`. When `false` (the default),
the directive is absent entirely — which is the correct behaviour for both OpenBao
(which ignores mlock) and HashiCorp Vault on systems with `IPC_LOCK` available.

The `IPC_LOCK` capability is added to the container only when `disable_mlock = false`,
keeping the capability absent when it would have no effect.

## Consequences

- Config is valid for both OpenBao and HashiCorp Vault without modification.
- Users on systems without `IPC_LOCK` (some WSL2 configurations) set
  `disable_mlock = true` in `terraform.tfvars`, which emits the directive and drops
  the capability.
- The divergence between OpenBao and HashiCorp Vault on this behaviour is documented
  in the README variable reference and this ADR as a known fork divergence point.
