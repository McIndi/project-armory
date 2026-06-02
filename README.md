# Ansible Project

This Ansible project is intended to be run inside the Fedora VM from `/vagrant/ansible`.
Configuration is environment-driven via `/vagrant/.env` (copied from `.env.example`).

## Structure

- `inventories/development/hosts.yml`: local inventory targeting `localhost`
- `playbooks/site.yml`: top-level playbook
- `roles/env_guard`: preflight role that verifies required env vars are loaded
- `roles/system_update`: role that runs `dnf` update
- `roles/k3s`: role that installs and configures `k3s` with SELinux, firewalld, and Keycloak OIDC authentication for the Kubernetes API server
- `roles/openbao`: role that installs and configures OpenBao for secret management
- `roles/nginx_ingress`: role that installs and configures nginx ingress controller with cert-manager TLS
- `roles/beeai_agentstack_tofu`: role that deploys the BeeAI Agent Stack Helm chart directly with Helm (Keycloak, PostgreSQL, SeaweedFS, API, UI)
- `roles/headlamp`: role that deploys Headlamp Kubernetes dashboard with Keycloak OIDC, OpenBao PKI, and Kubernetes RBAC; also configures k3s OIDC for API server token validation
- `roles/readiness_check`: post-deployment validation role that checks all components are ready

## Run

```bash
cd /vagrant
# cp .env.example .env  # first time only
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

## Run Only Specific Tasks

```bash
# Only run dnf update tasks
cd /vagrant
set -a; source .env; set +a
test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"

cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook playbooks/site.yml --tags dnf_update

# Only run k3s setup tasks
ansible-playbook playbooks/site.yml --tags k3s

# Only run BeeAI Agent Stack deploy tasks (Helm-native flow)
ansible-playbook playbooks/site.yml --tags beeai_install

# Only run BeeAI firewall tasks (open 8333, 8334, 8336 by default)
ansible-playbook playbooks/site.yml --tags beeai_firewall

# Only run the Keycloak OIDC audience fix (re-applies after chart upgrades overwrite config)
ansible-playbook playbooks/site.yml --tags beeai_keycloak_fix

# Only run Headlamp deploy (OIDC client, PKI, Helm chart, RBAC, k3s OIDC config)
ansible-playbook playbooks/site.yml --tags headlamp

# Only apply/update Headlamp RBAC ClusterRoleBinding
ansible-playbook playbooks/site.yml --tags headlamp_rbac

# Only re-configure k3s OIDC settings (re-writes CA file and restarts k3s)
ansible-playbook playbooks/site.yml --tags k3s_oidc

# Only run readiness checks
ansible-playbook playbooks/readiness_check.yml
```

## Notes

- The configuration uses local connection mode (`ansible_connection: local`).
- Privilege escalation and runtime defaults are set through `.env` using `ANSIBLE_*` variables.
- The `env_guard` role fails fast if `ARMORY_ENV_SOURCED` is missing or invalid.
- `/vagrant` is world-writable on most Vagrant guests, so using environment-driven config avoids relying on local `ansible.cfg` discovery.
- The VSO deployment path now requires a hardened VSO Helm chart (fork) with explicit kube-rbac-proxy TLS cert/key support. In `.env`, either set `BEEAI_VSO_CHART_PATH` to a local chart directory in this repo, or set `BEEAI_VSO_CHART_REPO`, `BEEAI_VSO_CHART_NAME`, and `BEEAI_VSO_CHART_VERSION` for a published chart, before running `--tags beeai_install`.

## Sensitive Output

By default, sensitive task output remains redacted (`no_log`).

- Keep redaction enabled (default):

```bash
export ARMORY_LOG_NOLOG=false
```

- Disable redaction for deep troubleshooting (prints sensitive values):

```bash
export ARMORY_LOG_NOLOG=true
```

Only set `ARMORY_LOG_NOLOG=true` in tightly controlled environments and rotate exposed credentials after use.

## Failure Context

Most larger task flows are wrapped in `block` and `rescue` sections. When a task in one of those flows fails, the role reports:

- the logical section that failed
- the failing task name
- the Ansible failure message

## Retrieve Generated Credentials

All secrets are generated once by the OpenBao role, stored in OpenBao KV, and synced into Kubernetes Secrets by Vault Secrets Operator (VSO). Re-runs reuse existing values — no credential rotation on redeploy unless the secret is manually deleted from OpenBao first.

```bash
# Show BeeAI UI login password (username: admin)
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.admin_password}' | base64 -d; echo"

# Show Headlamp login password (same admin user, same beeai-credentials secret)
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
| Headlamp dashboard login | `admin` | Same as BeeAI UI (shared Keycloak realm) | OpenBao `secret/beeai/credentials` -> k8s secret `beeai-credentials` |
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
   <vagrant_vm_ip> <ARMORY_PUBLIC_DOMAIN>
   ```

   Replace `<vagrant_vm_ip>` with your Vagrant VM's IP address and `<ARMORY_PUBLIC_DOMAIN>` with the domain from `.env` (default: `armory.local`).

2. Retrieve the admin password:

   ```bash
   # From your host machine (requires vagrant SSH access)
   vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.admin_password}' | base64 -d; echo"
   ```

### URL and Credentials

| Item | Value |
|------|-------|
| **URL** | `ARMORY_PUBLIC_BASE_URL` from `.env` (default: `https://armory.local`) |
| **Username** | `admin` |
| **Password** | See command above to retrieve from VM |

## Access Headlamp Kubernetes Dashboard

Headlamp is deployed as part of the stack to provide a modern Kubernetes dashboard with visibility into k3s and BeeAI components. It is integrated with:

- **OIDC authentication via Keycloak** (same realm as BeeAI)
- **PKI/TLS via OpenBao** (cert-manager issues ingress certs)
- **nginx ingress** for external HTTPS access
- **Plugin manager** enabled by default (with official `cert-manager` plugin)
- **Kubernetes RBAC** — the `admin` user is granted `cluster-admin` via a ClusterRoleBinding
- **k3s OIDC** — the k3s API server is configured to validate Keycloak-issued JWTs directly; Headlamp passes the ID token to the Kubernetes API on every request

### Headlamp Access URL

- **URL:** `https://$ARMORY_HEADLAMP_HOST` (default `https://headlamp.armory.local`)
- **OIDC Issuer:** `$ARMORY_PUBLIC_BASE_URL/realms/agentstack` (default `https://armory.local/realms/agentstack`)

### How Authentication Works

1. Click **Sign In** on the Headlamp login screen.
2. Headlamp redirects to Keycloak at `$ARMORY_PUBLIC_BASE_URL/realms/agentstack`.
3. Log in with `admin` and the password from `beeai-credentials` (see [Retrieve Generated Credentials](#retrieve-generated-credentials)).
4. Keycloak issues a JWT; Headlamp stores it as a browser cookie and forwards it as a Bearer token on every Kubernetes API request.
5. The k3s API server validates the JWT against the Keycloak OIDC issuer (configured during the headlamp role deployment) and maps the `preferred_username` claim to the Kubernetes user identity `$ARMORY_PUBLIC_BASE_URL/realms/agentstack#admin`.
6. The ClusterRoleBinding `headlamp-admin` grants that identity `cluster-admin` access.

### Prerequisites

1. Add these entries to your hosts file (see BeeAI UI section above for details):
   ```
   <vagrant_vm_ip> <ARMORY_PUBLIC_DOMAIN>
   <vagrant_vm_ip> <ARMORY_HEADLAMP_HOST>
   ```
2. Trust the Armory Root CA (see instructions above).

### Login Credentials

| Item | Value |
|------|-------|
| **URL** | `https://$ARMORY_HEADLAMP_HOST` (default: `https://headlamp.armory.local`) |
| **Username** | `admin` |
| **Password** | Same as BeeAI UI — retrieve with the command below |

```bash
vagrant ssh -c "sudo k3s kubectl get secret -n agentstack beeai-credentials -o jsonpath='{.data.admin_password}' | base64 -d; echo"
```

### Features

- Out-of-the-box visibility into k3s workloads, nodes, and BeeAI namespaces
- Plugin manager enabled (default: `cert-manager` plugin)
- Helm UI enabled for managing releases (if authorized)

See `ansible/roles/headlamp/README.md` for advanced configuration and plugin extension.

## Agent Stack CLI and Authentication Setup

This section documents the recommended end-to-end flow for using the Agent Stack CLI against this deployment.

### 1. Prerequisites

1. Ensure host name resolution for `$ARMORY_PUBLIC_DOMAIN` points to the VM IP.
2. Ensure the platform is deployed and reachable at `$ARMORY_PUBLIC_BASE_URL`.
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

The deployment uses a private PKI chain for `$ARMORY_PUBLIC_DOMAIN`. Trust the CA on clients that run `agentstack`.

#### Export CA from VM (authoritative signer)

```bash
vagrant ssh -c "k3s kubectl get secret -n openbao openbao-ca -o jsonpath='{.data.ca\.crt}' | base64 -d" > armory-ca.pem
```

#### Optional: Export the cert currently served by ingress (for diagnostics)

```bash
# Exports the certificate chain presented by the endpoint to a local file.
# In this setup, this is typically a single leaf cert unless your ingress secret includes intermediates.
openssl s_client -connect headlamp.armory.local:443 -servername headlamp.armory.local -showcerts </dev/null 2>/dev/null  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > headlamp-served-chain.pem
```

#### Verify CA fingerprint before trust (recommended)

```bash
openssl x509 -in armory-ca.pem -noout -fingerprint -sha256 -subject -dates
```

If multiple `Armory Root CA` certs already exist on your workstation from prior rebuilds, remove old ones first so the browser does not select a stale trust anchor.

#### Trust CA on Windows (Current User)

```powershell
certutil -addstore -f Root .\armory-ca.pem
```

#### (Windows) List existing Armory roots and remove stale entries

```powershell
# List
Get-ChildItem Cert:\CurrentUser\Root |
   Where-Object { $_.Subject -eq 'CN=Armory Root CA' } |
   Select-Object Subject, Thumbprint, NotBefore, NotAfter

# Remove one stale thumbprint (replace THUMBPRINT)
certutil -delstore Root THUMBPRINT
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

## Communication Audit

Let me check all the communication paths systematically — ingress, service-to-service, and OpenBao/VSO connections.

Here's the complete picture across every communication path:

---

## TLS Status by Communication Path

### ✅ Encrypted (TLS)
| Path | Protocol | Notes |
|------|----------|-------|
| Client → nginx ingress | HTTPS/443 | TLS terminated at ingress using `armory-tls` cert from OpenBao PKI |
| nginx → Keycloak (OIDC) | HTTPS | `armory.local/realms` routed via ingress with TLS |
| agentstack-ui → OIDC issuer | HTTPS | `OIDC_PROVIDER_ISSUER=https://armory.local/realms/agentstack`, with private CA mounted at `/etc/armory-ca/ca.crt` |
| agentstack-server → external OIDC | HTTPS | `AUTH__OIDC__EXTERNAL_ISSUER=https://armory.local/realms/agentstack` |
| metrics-server | HTTPS/10250 | TLS always on for kubelet metrics |
| cert-manager webhook | HTTPS/443 | Standard cert-manager behaviour |
| VSO metrics | HTTPS/8443 | |
| ingress-nginx admission | HTTPS/443 | |

### ⚠️ Unencrypted (plain HTTP) — internal cluster only
| Path | Protocol | Notes |
|------|----------|-------|
| VSO → OpenBao | **HTTPS** `https://openbao.openbao.svc.cluster.local:8200` | Uses the OpenBao internal service TLS certificate and CA trust secret |
| agentstack-server → Keycloak (in-cluster) | **HTTP** `http://keycloak:8336/realms/agentstack` | Intentional — the Keycloak patch sets `KC_HOSTNAME_STRICT=false` specifically to allow this HTTP in-cluster path |
| agentstack-server → PostgreSQL | **Plain** `postgresql+psycopg://...@postgresql:5432` | Standard unencrypted PostgreSQL; in-cluster only |
| agentstack-server → SeaweedFS S3 | **HTTP** `http://seaweedfs-all-in-one:9009` | S3-compatible endpoint, in-cluster only |
| otel-collector → agentstack-server | **HTTP** `http://agentstack-server-svc:8333` | Telemetry collection, in-cluster only |


**Common Issues:**
- **Pods in CrashLoopBackOff**: Check pod logs for startup errors (database not ready, credentials missing, etc.)
- **Pods in Pending**: Check node resources (`kubectl top nodes`) or PVC status (`kubectl get pvc -n agentstack`)
- **Endpoints empty**: Service selectors don't match pod labels; check `kubectl describe svc <svc_name> -n agentstack`
- **Ingress rules not matching**: Verify hostname in ingress matches `armory.local` and TLS certificate is valid

