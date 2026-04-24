# Operations Guide

> **Keep this file up to date.** Whenever a new phase is added, a command changes,
> a port shifts, or a new env var is required, update the relevant section here.
> This is the canonical reference for destroying, rebuilding, and exploring the stack.

---

## Destroy Everything

Run in order — later modules depend on Vault being alive for clean AppRole revocation.

```bash
cd ~/projects/project-armory

export TF_VAR_vault_token=<ROOT_TOKEN>

tofu destroy -auto-approve -chdir=services/agent/
tofu destroy -auto-approve -chdir=services/keycloak/
tofu destroy -auto-approve -chdir=services/postgres/
tofu destroy -auto-approve -chdir=services/webserver/   # if deployed

tofu destroy -auto-approve -chdir=vault-config/
tofu destroy -auto-approve -chdir=vault/

# Remove host deploy directories
# (rootless Podman owns some files — podman unshare handles UID remapping)
podman unshare rm -rf /opt/armory 2>/dev/null || rm -rf /opt/armory
sudo mkdir -p /opt/armory && sudo chown $USER:$USER /opt/armory

# Clear stale state so the next apply starts clean
rm -f vault/terraform.tfstate vault/terraform.tfstate.backup
rm -f vault-config/terraform.tfstate vault-config/terraform.tfstate.backup
rm -f services/agent/terraform.tfstate services/agent/terraform.tfstate.backup
rm -f services/postgres/terraform.tfstate services/postgres/terraform.tfstate.backup
rm -f services/keycloak/terraform.tfstate services/keycloak/terraform.tfstate.backup
rm -f services/webserver/terraform.tfstate services/webserver/terraform.tfstate.backup
```

---

## Rebuild from Scratch

### Phase 1 — Vault

```bash
cd ~/projects/project-armory/vault
cp example.tfvars terraform.tfvars   # edit api_addr/tls_san_ip if needed
tofu init && tofu apply -auto-approve
```

### Phase 2 — Key ceremony (once only per deployment)

```bash
# Init — prints Unseal Key and Root Token. Save both in a password manager.
podman exec armory-vault bao operator init -key-shares=1 -key-threshold=1

# Unseal
podman exec armory-vault bao operator unseal <UNSEAL_KEY>

# Confirm active
podman exec armory-vault bao status
```

> Vault must be unsealed after every restart. Root Token is only needed for
> OpenTofu operations — operators use OIDC.

### Phase 3 — Configure Vault

```bash
cd ~/projects/project-armory/vault-config
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init && tofu apply -auto-approve
```

**Optional: Consolidate CA certificates**

To create a single `ca-bundle.pem` that includes both the Vault server TLS CA and all PKI CAs, re-apply with the `vault_tls_cacert_path` variable:

```bash
cd ~/projects/project-armory/vault-config
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu apply -var "vault_tls_cacert_path=/opt/armory/vault/tls/ca.crt" -auto-approve
```

After this, use `vault/ca-bundle.pem` as the single trust anchor for all Armory services (`VAULT_CACERT`, `--cacert`, system trust store, etc.). Skip this step if you prefer to keep `/opt/armory/vault/tls/ca.crt` separate for Vault-only connectivity.

### Phase 4 — PostgreSQL

```bash
cd ~/projects/project-armory/services/postgres
cp example.tfvars terraform.tfvars
tofu init && tofu apply -auto-approve

# Verify
podman exec armory-postgres psql -U postgres -c "\du"
podman exec armory-postgres psql -U postgres -c "\l"
```

### Phase 5 — Enable database roles (re-apply vault-config)

```bash
cd ~/projects/project-armory/vault-config
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu apply -auto-approve -var database_roles_enabled=true
```

### Phase 6 — Keycloak

```bash
cd ~/projects/project-armory/services/keycloak
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init && tofu apply -auto-approve

# Wait for healthy (~60s)
podman ps --filter name=armory-keycloak
```

### Phase 7 — Configure Keycloak realm (manual, browser)

Admin credentials are in Vault:

```bash
export VAULT_ADDR=https://127.0.0.1:8200

# If you consolidated the CA bundle (Phase 3 optional step):
export VAULT_CACERT=~/projects/project-armory/vault/ca-bundle.pem

# If using separate CAs (default Phase 3):
export VAULT_CACERT=/opt/armory/vault/tls/ca.crt

podman exec -e VAULT_TOKEN=<ROOT_TOKEN> armory-vault \
  bao kv get kv/keycloak/admin
```

Navigate to `https://127.0.0.1:8444/admin`, then:

1. Create realm **`armory`**
2. Create group **`vault-operators`**, add your operator user

**Client `vault`** — confidential, used by Vault OIDC auth method:

3. Create OIDC client **`vault`** — Client authentication: ON (note the client secret)
4. Add **Group Membership** protocol mapper → token claim name `groups`

**Client `agent-cli`** — public, used by `cli.py` (Authorization Code + PKCE):

5. Create OIDC client **`agent-cli`** — Client authentication: OFF (public client)
6. Standard Flow: enabled; Direct Access Grants: **disabled** (blocks password grant)
7. Under **Advanced** → PKCE Code Challenge Method: **S256**
8. Valid Redirect URIs: `http://127.0.0.1:18080/callback`
9. Web Origins: `http://127.0.0.1:18080`
10. Add the same Group Membership mapper → token claim name `groups`

### Phase 8 — Enable OIDC auth (three-step ceremony, do not skip steps)

```bash
cd ~/projects/project-armory/vault-config
export TF_VAR_vault_token=<ROOT_TOKEN>

# Step 1: enable OIDC alongside userpass
tofu apply -auto-approve \
  -var database_roles_enabled=true \
  -var oidc_enabled=true \
  -var oidc_client_id=vault \
  -var 'oidc_client_secret=<SECRET_FROM_KEYCLOAK>'

# Step 2: verify OIDC login works (opens browser)
podman exec armory-vault bao login -method=oidc role=operator

# Step 3: retire userpass — only after step 2 succeeds
tofu apply -auto-approve \
  -var database_roles_enabled=true \
  -var oidc_enabled=true \
  -var oidc_client_id=vault \
  -var 'oidc_client_secret=<SECRET>' \
  -var userpass_enabled=false
```

> Never run Step 3 before Step 2. Removing userpass before OIDC is verified working
> locks you out of Vault. Recovery: restart Vault with the root token from the key
> ceremony and re-enable userpass.

### Phase 9 — Agent

```bash
# Enable the agent AppRole in vault-config
cd ~/projects/project-armory/vault-config
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu apply -auto-approve \
  -var agent_enabled=true \
  -var database_roles_enabled=true \
  -var oidc_enabled=true \
  -var oidc_client_id=vault \
  -var 'oidc_client_secret=<SECRET>'

# Issue wrapped credentials to disk
cd ~/projects/project-armory/services/agent
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init && tofu apply -auto-approve

# Start the agent API (new terminal)
cd ~/projects/project-armory/services/agent/agent
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

export VAULT_ADDR=https://127.0.0.1:8200
export ARMORY_CACERT=~/projects/project-armory/vault/ca-bundle.pem
export APPROLE_DIR=/opt/armory/agent/approle
export KEYCLOAK_URL=https://127.0.0.1:8444
export OIDC_CLIENT_ID=agent-cli
export POSTGRES_HOST=armory-postgres
export POSTGRES_DB=app

.venv/bin/python api.py
```

> **Single-use secret_id:** The `wrapped_secret_id` is consumed once at API startup.
> Requests handled by that running API process reuse the same Vault token.
> Re-run `tofu apply` in `services/agent/` when starting a new API process that no
> longer has a valid startup token.

> **API restart note:** If startup fails with a wrapping token error, issue a fresh
> wrapped secret by re-running `tofu apply` in `services/agent/`, then restart `api.py`.

> **Postgres hostname:** `armory-postgres` only resolves on `armory-net`. If running
> the agent on the host, add a `/etc/hosts` entry or run it inside a container on
> `armory-net` (Phase 2 containerization).

---

## Poking Around

### Check what's running

```bash
podman ps --format "table {{.Names}}\t{{.Status}}"
```

### Vault status and audit log

```bash
export VAULT_ADDR=https://127.0.0.1:8200

# If you consolidated the CA bundle (Phase 3 optional step):
export VAULT_CACERT=~/projects/project-armory/vault/ca-bundle.pem

# If using separate CAs (default Phase 3):
export VAULT_CACERT=/opt/armory/vault/tls/ca.crt

podman exec armory-vault bao status

# Audit log — tail in a dedicated terminal
tail -f /opt/armory/vault/logs/audit.log | python3 -m json.tool
```

### Operator login to Vault (confirms OIDC is working)

```bash
podman exec armory-vault bao login -method=oidc role=operator
```

### Submit a task (full chain — watch audit log at the same time)

```bash
cd ~/projects/project-armory/services/agent/agent
.venv/bin/python cli.py --query "SELECT current_user, now() AS ts"
```

The response `request_id` correlates the agent application log with the Vault audit
log entries for that specific task invocation.

### Inspect the agent policy

```bash
podman exec -e VAULT_TOKEN=<ROOT_TOKEN> armory-vault bao policy read agent
```

### Watch dynamic DB credentials being created and revoked

```bash
# Terminal 1 — filtered audit log
tail -f /opt/armory/vault/logs/audit.log \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        path = e.get('request', {}).get('path', '')
        if 'database' in path or 'revoke' in path:
            print(json.dumps(e, indent=2))
    except: pass
"

# Terminal 2 — submit a task
.venv/bin/python cli.py --query "SELECT usename, valuntil FROM pg_user"
```

### Verify Keycloak is issuing tokens correctly

```bash
curl -s --cacert ~/projects/project-armory/vault/ca-bundle.pem \
  https://127.0.0.1:8444/realms/armory/.well-known/openid-configuration \
  | python3 -m json.tool | grep -E "issuer|token_endpoint|jwks"
```

### Webserver (optional — Phase 4)

```bash
# Deploy
cd ~/projects/project-armory/services/webserver
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init && tofu apply -auto-approve

# Verify
curl -s --cacert ~/projects/project-armory/vault/ca-bundle.pem \
  https://127.0.0.1:8443/ | head -5
```

---

## Integration Tests

The test suite automates Phases 1–3 and optionally Phase 4 (webserver). Run:

```bash
cd ~/projects/project-armory
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/pytest tests/ -v
```

Leave the environment running after tests (useful for manual exploration):

```bash
ARMORY_NO_TEARDOWN=1 .venv/bin/pytest tests/ -v
```

See `tests/conftest.py` for the full fixture lifecycle.
