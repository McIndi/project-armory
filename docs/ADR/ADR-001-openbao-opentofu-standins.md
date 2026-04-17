# ADR-001: OpenBao and OpenTofu as open-source standins

**Status:** Accepted

## Context

Project Armory needs a production-grade secrets manager and an infrastructure-as-code
tool. HashiCorp Vault and Terraform are the industry-standard choices, but HashiCorp
changed their licensing model (BSL) in 2023, creating uncertainty for open-source and
client environments. The project is also intended to be delivered to clients who may
have their own licensing preferences or constraints.

## Decision

Use **OpenBao** (Vault fork) and **OpenTofu** (Terraform fork) as the default runtime.
Structure the code so that switching to HashiCorp Vault and Terraform requires changing
exactly four variables in `terraform.tfvars`:

```hcl
image_registry = "docker.io/hashicorp"
image_name     = "vault"
image_tag      = "1.18.3"
vault_binary   = "vault"
```

No structural changes to the module are needed for the swap.

## Consequences

- The project is fully open-source and carries no BSL obligations in its default form.
- Clients who require HashiCorp Vault (support contract, enterprise features) can switch
  with minimal friction.
- The fork divergence must be tracked. OpenBao v2+ made breaking changes (dropped mlock
  support — see ADR-014) that have no equivalent in HashiCorp Vault. Further divergence
  is expected over time.
- API and configuration compatibility is maintained at present but is not guaranteed
  indefinitely.
