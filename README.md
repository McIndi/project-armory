# Ansible Project

This Ansible project is intended to be run inside the Fedora VM from `/vagrant/ansible`.
Configuration is environment-driven via `/vagrant/.env` (copied from `.env.example`).

## Structure

- `inventories/development/hosts.yml`: local inventory targeting `localhost`
- `playbooks/site.yml`: top-level playbook
- `roles/env_guard`: preflight role that verifies required env vars are loaded
- `roles/system_update`: role that runs `dnf` update
- `roles/helm`: role that installs Helm
- `roles/k3s`: role that installs and configures `k3s` with Keycloak OIDC authentication for the Kubernetes API server
- `roles/openbao`: role that installs and configures OpenBao for secret management and PKI
- `roles/nginx_ingress`: role that installs and configures ingress-nginx and cert-manager TLS
- `roles/vso`: role that installs Vault Secrets Operator
- `roles/keycloak`: role that deploys standalone Keycloak (operator + realm import + DB secret sync)
- `roles/headlamp`: role that deploys Headlamp with Keycloak OIDC and Kubernetes RBAC
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
# Only run k3s setup tasks
ansible-playbook playbooks/site.yml --tags k3s

# Only run OpenBao tasks
ansible-playbook playbooks/site.yml --tags openbao

# Only run VSO install tasks
ansible-playbook playbooks/site.yml --tags vso_install

# Only run Keycloak install tasks
ansible-playbook playbooks/site.yml --tags keycloak_install

# Only run Headlamp deploy tasks
ansible-playbook playbooks/site.yml --tags headlamp_install

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
- The VSO deployment path requires a hardened VSO Helm chart with explicit kube-rbac-proxy TLS cert/key support. Configure `VSO_CHART_PATH` or the `VSO_CHART_REPO`/`VSO_CHART_NAME`/`VSO_CHART_VERSION` tuple in `.env`.

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

## Retrieve Generated Credentials

The deployment uses Keycloak plus OpenBao/VSO. Re-runs reuse existing values unless secrets are intentionally rotated.

```bash
# Keycloak master admin (operator bootstrap account)
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Realm armory admin password (username: admin) is stored in OpenBao at:
# secret/keycloak/realm-admin (key: password)

# Keycloak DB credentials synced by VSO
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

## Credential Map

| Purpose | Where |
|---|---|
| Keycloak master admin | secret `keycloak-initial-admin` (ns `keycloak`), keys `username` and `password` |
| Realm `armory` admin (Headlamp login) | OpenBao `secret/keycloak/realm-admin`, key `password` |
| Keycloak DB | OpenBao `secret/keycloak/db` -> VSO -> secret `keycloak-db-secret` |

## Access Keycloak and Headlamp

### Prerequisites

1. Add entries to your hosts file:
   - `<vagrant_vm_ip> <ARMORY_PUBLIC_DOMAIN>`
   - `<vagrant_vm_ip> <ARMORY_HEADLAMP_HOST>`
2. Trust the private Armory Root CA on your host.

### URLs

- Keycloak realm discovery: `https://armory.local/realms/armory/.well-known/openid-configuration`
- Headlamp: `https://headlamp.armory.local`

### Headlamp login

- Username: `admin`
- Password: value stored at OpenBao `secret/keycloak/realm-admin` (also synced by role workflows where configured)

## Teardown

```bash
cd /vagrant/project-armory/ansible
ansible-playbook playbooks/teardown_k3s_workloads.yml -e teardown_confirm=true
```

This teardown removes Keycloak workload resources first, then VSO, ingress, and OpenBao workload state.
