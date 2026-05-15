# Ansible Project

This Ansible project is intended to be run inside the Fedora VM from `/vagrant/ansible`.
Configuration is environment-driven via `/vagrant/.env` (copied from `.env.example`).

## Structure

- `inventories/development/hosts.yml`: local inventory targeting `localhost`
- `playbooks/site.yml`: top-level playbook
- `roles/env_guard`: preflight role that verifies required env vars are loaded
- `roles/system_update`: role that runs `dnf` update
- `roles/opentofu`: role that installs the `opentofu` package
- `roles/k3s`: role that installs and configures `k3s` with SELinux and firewalld
- `roles/helm`: role that installs the `helm` package
- `roles/openbao`: role that installs and configures OpenBao for secret management
- `roles/nginx_ingress`: role that installs and configures nginx ingress controller
- `roles/beeai_agentstack_tofu`: role that uses OpenTofu to deploy the BeeAI Agent Stack Helm chart
- `roles/readiness_check`: post-deployment validation role that checks all components are ready

## Run

```bash
cd /vagrant
cp .env.example .env  # first time only
set -a; source .env; set +a
test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"
echo "Return code: $?"
cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook playbooks/site.yml
```

## Syntax Check

```bash
cd /vagrant
set -a; source .env; set +a
test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"

cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook --syntax-check playbooks/site.yml
```

## Linting

Linting configuration files are kept in `ansible/.ansible-lint` and `ansible/.yamllint`.

### Install Lint Tools

```bash
cd /vagrant
python3 -m pip install --user ansible-lint yamllint
```

### Run ansible-lint

```bash
cd /vagrant/ansible
ansible-lint -c .ansible-lint playbooks/site.yml roles/
```

### Run yamllint

```bash
cd /vagrant/ansible
yamllint -c .yamllint .
```

### Run Both (quick workflow)

```bash
cd /vagrant/ansible
ansible-lint -c .ansible-lint playbooks/site.yml roles/
yamllint -c .yamllint .
```

## Run Readiness Check (Post-Deployment)

After the full deployment completes, verify all components are ready:

```bash
cd /vagrant
set -a; source .env; set +a
test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"

cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook playbooks/readiness_check.yml
```

This runs only the preflight environment guard plus the readiness role. Use `playbooks/site.yml --tags readiness_check` only if you specifically want to run readiness checks through the main playbook entrypoint. The readiness playbook outputs a summary table showing component status (pass/warn/fail) and indicates whether the environment is ready for use. Run with `ARMORY_BUILD_DEBUG=true` for detailed per-check diagnostics.

## Run Only Specific Tasks

```bash
# Only run dnf update tasks
cd /vagrant
set -a; source .env; set +a
test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"

cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook playbooks/site.yml --tags dnf_update

# Only run OpenTofu install tasks
ansible-playbook playbooks/site.yml --tags tofu_install

# Only run k3s setup tasks
ansible-playbook playbooks/site.yml --tags k3s

# Only run Helm install tasks
ansible-playbook playbooks/site.yml --tags helm_install

# Only run BeeAI Agent Stack deploy tasks (via OpenTofu + Helm provider)
ansible-playbook playbooks/site.yml --tags beeai_install

# Only run BeeAI firewall tasks (open 8333, 8334, 8336 by default)
ansible-playbook playbooks/site.yml --tags beeai_firewall

# Only run the Keycloak OIDC audience fix (re-applies after chart upgrades overwrite config)
ansible-playbook playbooks/site.yml --tags beeai_keycloak_fix

# Only run readiness checks
ansible-playbook playbooks/readiness_check.yml
```

## Notes

- The configuration uses local connection mode (`ansible_connection: local`).
- Privilege escalation and runtime defaults are set through `.env` using `ANSIBLE_*` variables.
- The `env_guard` role fails fast if `ARMORY_ENV_SOURCED` is missing or invalid.
- `/vagrant` is world-writable on most Vagrant guests, so using environment-driven config avoids relying on local `ansible.cfg` discovery.

## Debug Mode

Set `ARMORY_BUILD_DEBUG=true` in `/vagrant/.env` when you want task-level execution context during a run.

```bash
cd /vagrant
set -a; source .env; set +a
export ARMORY_BUILD_DEBUG=true

cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook playbooks/site.yml
```

By default, sensitive task output remains redacted (`no_log`) even when debug mode is enabled.

- Keep redaction enabled (default):

```bash
export ARMORY_LOG_NOLOG=false
```

- Disable redaction for deep troubleshooting (prints sensitive values):

```bash
export ARMORY_LOG_NOLOG=true
```

Only set `ARMORY_LOG_NOLOG=true` in tightly controlled environments and rotate exposed credentials after use.

With debug mode enabled, roles emit a short companion debug task after each operational task. Those messages are intended to answer a few operator questions quickly:

- which task just ran
- whether it executed or was skipped
- whether it changed anything
- simple status details such as exit code, HTTP status, object counts, or presence checks

The debug output is designed to avoid printing secret values. It reports booleans and status metadata instead of passwords, tokens, keys, or raw secret payloads.

## Failure Context

Most larger task flows are wrapped in `block` and `rescue` sections. When a task in one of those flows fails, the role reports:

- the logical section that failed
- the failing task name
- the Ansible failure message

If you hit a role failure, rerun with `ARMORY_BUILD_DEBUG=true` first. That gives you the nearest companion debug output before the failure plus the section-level rescue context after it.

## Retrieve Generated Credentials

All secrets are generated once by the OpenBao role, stored in OpenBao KV, and synced into Kubernetes Secrets by Vault Secrets Operator (VSO). Re-runs reuse existing values.

```bash
# Show BeeAI UI login password (username: admin)
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.admin_password}' | base64 -d; echo"

# Show PostgreSQL admin password (username: postgres)
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.pg_admin_password}' | base64 -d; echo"

# Show PostgreSQL app user password (username: agentstack-user)
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.pg_user_password}' | base64 -d; echo"

# Show SeaweedFS secret
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.seaweedfs_secret}' | base64 -d; echo"

# Show encryption key
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-encryption-key -o jsonpath='{.data.value}' | base64 -d; echo"

# Show Keycloak admin console password (username: admin, at :31288)
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack keycloak-secret -o jsonpath='{.data.admin-password}' | base64 -d; echo"
```

## Credential Map

| Credential | Username | How Generated | Where Stored |
|---|---|---|---|
| BeeAI UI login | `admin` | OpenBao role (token_urlsafe, persisted) | OpenBao `secret/beeai/credentials` -> k8s secret `beeai-credentials` |
| Keycloak admin console | `admin` | Chart (random) | k8s secret `keycloak-secret` |
| PostgreSQL admin | `postgres` | OpenBao role (token_urlsafe, persisted) | OpenBao `secret/beeai/credentials` -> k8s secret `beeai-credentials` |
| PostgreSQL app user | `agentstack-user` | OpenBao role (token_urlsafe, persisted) | OpenBao `secret/beeai/credentials` -> k8s secret `beeai-credentials` |
| SeaweedFS S3 secret | `agentstack-admin-user` | OpenBao role (token_urlsafe, persisted) | OpenBao `secret/beeai/credentials` -> k8s secret `beeai-credentials` |
| Encryption key | n/a | OpenBao role (generated once, persisted) | OpenBao `secret/beeai/encryption-key` -> k8s secret `beeai-encryption-key` |
| JWT key pair | n/a | Chart (auto-gen if empty) | k8s secret `agentstack-secret` |
| NextAuth secret | n/a | Chart (auto-gen if empty) | k8s secret `agentstack-secret` |

## Access BeeAI Agent Stack UI

### Prerequisites

1. Add this entry to your **hosts file**:
   - **Windows**: `C:\Windows\System32\drivers\etc\hosts`
   - **Linux/Mac**: `/etc/hosts`

   ```
   <vagrant_vm_ip> armory.local
   ```

   Replace `<vagrant_vm_ip>` with your Vagrant VM's IP address (e.g., `192.168.56.10`).

2. Retrieve the admin password:

   ```bash
   # From your host machine (requires vagrant SSH access)
   vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.admin_password}' | base64 -d; echo"
   ```

### URL and Credentials

| Item | Value |
|------|-------|
| **URL** | `https://armory.local` |
| **Username** | `admin` |
| **Password** | See command above to retrieve from VM |

## Agent Stack CLI and Authentication Setup

This section documents the recommended end-to-end flow for using the Agent Stack CLI against this deployment.

### 1. Prerequisites

1. Ensure host name resolution for `armory.local` points to the VM IP.
2. Ensure the platform is deployed and reachable at `https://armory.local`.
3. Run commands from the host unless noted as VM-only.

### 2. Install Agent Stack CLI

#### Windows (PowerShell)

```powershell
uv python install --quiet --python-preference=only-managed --no-bin 3.14
uv tool install --refresh --force --python-preference=only-managed --python=3.14 agentstack-cli
agentstack self install
agentstack self version -v
```

#### Linux/macOS

```bash
uv python install --quiet --python-preference=only-managed --no-bin 3.14
uv tool install --refresh --force --python-preference=only-managed --python=3.14 agentstack-cli
agentstack self install
agentstack self version -v
```

### 3. Export and Trust the Armory Root CA

The deployment uses a private PKI chain for `armory.local`. Trust the CA on clients that run `agentstack`.

#### Export CA from VM

```bash
vagrant ssh -c "curl -s http://127.0.0.1:32200/v1/pki/ca/pem" > armory-ca.pem
```

#### Trust CA on Windows (Current User)

```powershell
certutil -addstore -f Root .\armory-ca.pem
```

#### Trust CA on Fedora VM (system-wide)

```bash
sudo cp armory-ca.pem /etc/pki/ca-trust/source/anchors/armory-ca.pem
sudo update-ca-trust
```

### 4. Verify OIDC and API Reachability

```bash
curl -vk https://armory.local/realms/agentstack/.well-known/openid-configuration
curl -vk https://armory.local/api/
```

Expected:
- OIDC discovery returns `200` with JSON.
- `/api/` may redirect, but should be reachable through the same host.

### 5. Recommended Login: Interactive User Login

Use this for normal operator usage:

```bash
agentstack server login https://armory.local --auth-server https://armory.local/realms/agentstack
```

When prompted, authenticate with the seeded user (`admin`) and password from `beeai-credentials`.

### 6. Optional Login: OAuth Client Credentials

Use this for automation/service-account style workflows.

#### 6.1 Get Keycloak admin password (VM)

```bash
KC_ADMIN_PASSWORD="$(sudo k3s kubectl get secret -n agentstack keycloak-secret -o jsonpath='{.data.admin-password}' | base64 -d)"
```

#### 6.2 Discover Keycloak internal service endpoint (VM)

```bash
KC_SVC_IP="$(sudo k3s kubectl get svc -n agentstack keycloak -o jsonpath='{.spec.clusterIP}')"
KC_SVC_PORT="$(sudo k3s kubectl get svc -n agentstack keycloak -o jsonpath='{.spec.ports[0].port}')"
```

#### 6.3 Obtain short-lived admin API token (VM)

```bash
KC_TOKEN="$(curl -s "http://$KC_SVC_IP:$KC_SVC_PORT/realms/master/protocol/openid-connect/token" \
   -d client_id=admin-cli \
   -d username=admin \
   -d password="$KC_ADMIN_PASSWORD" \
   -d grant_type=password | jq -r '.access_token // empty')"
```

#### 6.4 Find the CLI client and inspect whether it is confidential (VM)

```bash
CLI_UUID="$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
   "http://$KC_SVC_IP:$KC_SVC_PORT/admin/realms/agentstack/clients?clientId=agentstack-cli" \
   | jq -r '.[0].id // empty')"

curl -s -H "Authorization: Bearer $KC_TOKEN" \
   "http://$KC_SVC_IP:$KC_SVC_PORT/admin/realms/agentstack/clients/$CLI_UUID" \
   | jq '{clientId, publicClient, serviceAccountsEnabled}'
```

If `publicClient` is `true`, the client has no secret by design. Use interactive login or create a dedicated confidential client.

If `publicClient` is `false`, fetch its secret:

```bash
KC_TOKEN="$(curl -s "http://$KC_SVC_IP:$KC_SVC_PORT/realms/master/protocol/openid-connect/token" \
   -d client_id=admin-cli \
   -d username=admin \
   -d password="$KC_ADMIN_PASSWORD" \
   -d grant_type=password | jq -r '.access_token // empty')"

CLI_SECRET="$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
   "http://$KC_SVC_IP:$KC_SVC_PORT/admin/realms/agentstack/clients/$CLI_UUID/client-secret" \
   | jq -r '.value // empty')"
```

#### 6.5 Login with client credentials

```bash
agentstack server login https://armory.local \
   --auth-server https://armory.local/realms/agentstack \
   --client-id agentstack-cli \
   --client-secret "$CLI_SECRET"
```

### 7. Security Notes

1. Do not commit client secrets, tokens, or passwords to the repository.
2. Treat any secret pasted into chat or logs as exposed and rotate it.
3. Keycloak admin tokens are intentionally short-lived; refresh before admin API calls.

### Troubleshooting 503 Service Unavailable

If you get a 503 error when accessing the UI, the nginx ingress cannot reach the backend services. Use these commands from the Vagrant VM to diagnose:

```bash
# SSH into the VM first
vagrant ssh

# 1. Check if all BeeAI pods are Running
sudo k3s kubectl get pods -n agentstack

# 2. Check service status and endpoints
sudo k3s kubectl get svc -n agentstack
sudo k3s kubectl get endpoints -n agentstack

# 3. Inspect the nginx ingress configuration
sudo k3s kubectl get ingress -n agentstack
sudo k3s kubectl describe ingress agentstack-ui -n agentstack

# 4. Check nginx ingress controller logs for routing errors
sudo k3s kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50

# 5. Check specific service pod logs
# For the main API server (adjust selector based on actual pod labels)
sudo k3s kubectl logs -n agentstack -l app=agentstack-server --tail=50

# For Keycloak (identity provider)
sudo k3s kubectl logs -n agentstack -l app.kubernetes.io/name=keycloak --tail=50

# For PostgreSQL
sudo k3s kubectl logs -n agentstack -l app.kubernetes.io/name=postgresql --tail=50

# 6. Test connectivity from inside the cluster
sudo k3s kubectl run -it --rm debug --image=alpine --restart=Never -- sh
  # Inside the pod:
  apk add curl
  curl -k https://agentstack:3000/  # UI service
  curl -k https://agentstack:8080/  # API service
  exit

# 7. Check HPA (if enabled) and resource constraints
sudo k3s kubectl describe hpa -n agentstack

# 8. Verify the Helm release status
sudo helm list -n agentstack
sudo helm status agentstack -n agentstack
```

**Common Issues:**
- **Pods in CrashLoopBackOff**: Check pod logs for startup errors (database not ready, credentials missing, etc.)
- **Pods in Pending**: Check node resources (`kubectl top nodes`) or PVC status (`kubectl get pvc -n agentstack`)
- **Endpoints empty**: Service selectors don't match pod labels; check `kubectl describe svc <svc_name> -n agentstack`
- **Ingress rules not matching**: Verify hostname in ingress matches `armory.local` and TLS certificate is valid
