# trust_manager role

## Purpose
Install trust-manager and manage declarative CA bundle distribution for internal
TLS consumers.

## What this role does
1. Installs trust-manager via Helm.
2. Enables secret targets for Bundle resources.
3. In declarative mode (`use_declarative_ca_distribution: true`), applies Bundle
   resources that copy OpenBao CA material into target namespaces as Secrets.

## Key variables
- `trust_manager_enabled`: enable/disable this role from site orchestration.
- `use_declarative_ca_distribution`: switch consumers from manual CA copy to
  trust-manager managed target Secrets.
- `trust_manager_internal_ca_target_namespaces`: namespaces that receive the
  internal CA target secret.
- `trust_manager_internal_ca_target_secret_name`: secret name expected by
  consumers (e.g., VaultConnection and cert-manager ClusterIssuer references).

## Security note
Secret targets require trust-manager secret-target support. This role enables it
with `secretTargets.enabled=true`.
