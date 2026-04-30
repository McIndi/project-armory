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
- The Wazuh module seeds Vault KV v2 secret `kv/wazuh/oidc` during apply.
- Set `TF_VAR_wazuh_oidc_client_secret` and `TF_VAR_wazuh_cookie_secret` before deployment.

## Keycloak account and client setup

When using `rebuild.sh`, Keycloak bootstrap for Wazuh is automated by `services/keycloak/`.
The imported `armory` realm already contains:

1. Group `wazuh-operators`
2. Confidential client `wazuh-dashboard`
3. Redirect URI `https://127.0.0.1:8550/oauth2/callback`
4. Web origin `https://127.0.0.1:8550`
5. Demo user `wazuh-operator` in `wazuh-operators`

## Vault secret for oauth2-proxy

The module writes these values to Vault KV v2 path `kv/wazuh/oidc` during `tofu apply`.

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=~/projects/project-armory/vault/ca-bundle.pem
export VAULT_TOKEN=<ROOT_TOKEN>
export TF_VAR_wazuh_operator_username=wazuh-operator
export TF_VAR_wazuh_operator_password=<WAZUH_OPERATOR_PASSWORD>
export TF_VAR_wazuh_oidc_client_secret=<KEYCLOAK_CLIENT_SECRET>
export TF_VAR_wazuh_cookie_secret=<32_BYTE_BASE64>

tofu apply -auto-approve
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
