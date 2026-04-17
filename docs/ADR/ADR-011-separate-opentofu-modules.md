# ADR-011: Separate OpenTofu modules per concern

**Status:** Accepted

## Context

The system has three distinct lifecycle phases with different cadences and actors:

1. **Infrastructure deployment** — Deploy the Vault container. Changes rarely. Requires
   host access and a Podman runtime.
2. **Vault configuration** — Configure PKI, auth methods, policies. Changes when new
   services are added or security policy changes. Requires a running, unsealed Vault.
3. **Service deployment** — Deploy individual services. Changes frequently as services
   are iterated. Each service has its own Vault resources (policy, AppRole).

Placing all three in one OpenTofu module means every `tofu apply` re-evaluates all
resources, and a mistake in a service module can affect the Vault deployment.

## Decision

Structure the project as separate OpenTofu modules with independent state:

```
vault/           # Phase 1: deploy Vault container
vault-config/    # Phase 2: configure Vault (PKI, AppRole, base policies)
services/<name>/ # Phase 3: per-service deployment (one module per service)
```

Each module has its own `terraform.tfstate`. Modules are applied in order but are
otherwise independent.

## Consequences

- A service can be destroyed and redeployed without touching Vault or its config.
- Vault can be redeployed (e.g., to upgrade the image) without affecting service
  configurations.
- The three-phase apply sequence is a required operational procedure and must be
  documented clearly.
- There is no automatic dependency enforcement between modules — the operator is
  responsible for applying in the correct order. Applying `vault-config/` against a
  stopped Vault will fail with a connection error, not a helpful dependency message.
- This structure maps cleanly to a team model: a platform team owns `vault/` and
  `vault-config/`; service teams own `services/<name>/`.
