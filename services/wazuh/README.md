# services/wazuh

Wazuh SIEM service module for Project Armory.

This module deploys:

- `wazuh-manager` for event ingestion and security analytics
- `vault-agent` sidecar to render TLS material and OIDC secrets from Vault
- `oauth2-proxy` in front of Wazuh API, integrated with Keycloak OIDC
- `observer` sidecar that emits JSON health/perf telemetry for Vault, Keycloak, and PostgreSQL

## What this monitors

- Vault health (`/v1/sys/health`) and Vault audit log (`/opt/armory/vault/logs/audit.log`)
- Keycloak readiness (`/health/ready`)
- PostgreSQL TCP reachability on `armory-postgres:5432`

The observer writes JSON events into:

- `/opt/armory/wazuh/observer/armory-observer.log`

Wazuh ingests these signals as local files to provide cross-service observability.

## Prerequisites

- Vault, vault-config, PostgreSQL, and Keycloak should already be deployed.
- Keycloak OIDC realm should exist (`armory` by default).
- Vault KV v2 secret should exist at `kv/wazuh/oidc` with:
  - `client_secret`
  - `cookie_secret` (32-byte base64 value)

## Keycloak account and client setup

1. Log in to Keycloak admin console (`https://127.0.0.1:8444/admin`).
2. Open realm `armory`.
3. Create group `wazuh-operators`.
4. Create a confidential client (default ID: `wazuh-dashboard`).
5. Set redirect URI to `https://127.0.0.1:8550/oauth2/callback`.
6. Set web origin to `https://127.0.0.1:8550`.
7. Ensure `groups` claim is present in tokens (group membership mapper).
8. Create users and add them to `wazuh-operators`.

## Vault secret for oauth2-proxy

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=~/projects/project-armory/vault/ca-bundle.pem
export VAULT_TOKEN=<ROOT_TOKEN>

bao kv put kv/wazuh/oidc \
  client_secret=<KEYCLOAK_CLIENT_SECRET> \
  cookie_secret=<32_BYTE_BASE64>
```

## Deploy

```bash
cd services/wazuh
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init && tofu apply -auto-approve
```

## Access

- Direct Wazuh API: `https://127.0.0.1:55000`
- Keycloak-protected endpoint: `https://127.0.0.1:8550`
