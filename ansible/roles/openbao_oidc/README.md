# openbao_oidc role

## Purpose
Configure OpenBao UI OIDC login against Keycloak after Keycloak is available.

## What it does

1. Provisions/updates the Keycloak `openbao` OIDC client.
2. Ensures a `groups` protocol mapper on that client.
3. Persists the effective client secret to OpenBao KV (`secret/openbao/ui-oidc`) using the provisioner token.
4. Configures OpenBao `auth/oidc/config` and `auth/oidc/role/armory-ui` using the root token.
5. Patches the OpenBao StatefulSet with a host alias for public-issuer DNS resolution from inside the pod.

## Notes

- This role is intended to run after `keycloak` in `playbooks/site.yml`.
- It is gated by `openbao_ui_enabled` and `keycloak_enabled`.
- Sensitive tasks honor `ARMORY_LOG_NOLOG` redaction behavior.
