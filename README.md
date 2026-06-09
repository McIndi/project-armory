# Project Armory

Project Armory is an open-source reference architecture for running AI agents safely inside regulated enterprises. It wires together the controls a Fortune 100 security team will actually ask about: identity (Keycloak OIDC, all the way down to the k3s API server), secrets and PKI (OpenBao + Vault Secrets Operator + cert-manager), RBAC, TLS-everywhere ingress, and an audit-ready agent runtime (BeeAI Agent Stack, a Linux Foundation project). Armory uses only open-source components, provisioned end-to-end with Ansible and OpenTofu. Clone it, stand it up in a VM, and use it as the foundation for your own secure agent platform.

## Structure

- `inventories/development/hosts.yml`: local inventory targeting `localhost`
- `playbooks/site.yml`: top-level playbook
- `roles/env_guard`: preflight role that verifies required env vars are loaded
- `roles/system_update`: role that runs `dnf` update
- `roles/helm`: role that installs Helm
- `roles/k3s`: role that installs and configures `k3s` with Keycloak OIDC authentication for the Kubernetes API server
- `roles/openbao`: role that installs and configures OpenBao for secret management and PKI
- `roles/cert_manager`: role that installs cert-manager and OpenBao-backed ClusterIssuers
- `roles/trust_manager`: role that installs trust-manager and declarative CA bundle distribution
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

# Only run trust-manager install and Bundle sync tasks
ansible-playbook playbooks/site.yml --tags trust_manager

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

## TLS Standards

- Internal service callers must use service FQDN endpoints (`<service>.<namespace>.svc.cluster.local`) rather than short names or raw IPs.
- Ingress backend protocol and service port must match service TLS mode (for Keycloak ingress, HTTPS upstream on port `8443`).
- Internal HTTPS callers must use explicit CA bundles that include the OpenBao root CA and the relevant issuer CA.
- `roles/common/tasks/prepare_internal_https_caller.yml` is the shared helper for internal caller DNS override and trust-bundle bootstrap.
- `roles/readiness_check` now includes strict TLS trust validation checks (explicit CA path + certificate verification) for Keycloak internal OIDC and Headlamp ingress endpoints.

## TLS Rollout Toggles

Use the following toggles for staged rollout and fast rollback:

- `use_declarative_ca_distribution`: when `true`, consumer roles use trust-manager-managed CA target Secrets instead of per-role secret copy tasks.
- `keycloak_pg_tls_enabled`: when `true`, Keycloak uses verify-full TLS for PostgreSQL (`sslmode=verify-full`) and Postgres serves TLS.
- `ingress_http_policy`: `redirect-only` (default compatibility) or `disabled` (close HTTP listener exposure path).

Recommended enablement sequence:

1. Enable `trust_manager_enabled: true` while keeping `use_declarative_ca_distribution: false`.
2. Validate Bundle target Secrets, then set `use_declarative_ca_distribution: true`.
3. Enable `keycloak_pg_tls_enabled: true` in non-prod first.
4. Set `ingress_http_policy: disabled` only after readiness checks pass for that profile.

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
# Keycloak master admin (OpenBao-generated bootstrap account)
# Source of truth is OpenBao at secret/keycloak/bootstrap-admin; the Secret below
# is materialized from it and consumed by spec.bootstrapAdmin at CR creation.
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Realm armory admin (username: admin) — THIS is the Headlamp login.
# Source of truth is OpenBao secret/keycloak/realm-admin; VSO mirrors it into the
# keycloak-realm-admin Secret (refreshAfter 60s), so just read the Secret:
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-realm-admin -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-realm-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Fallback (read OpenBao directly, e.g. before VSO has synced):
vagrant ssh -c "TOK=\$(sudo ansible-vault decrypt --vault-password-file /opt/openbao/.vault-pass --output - /opt/openbao/init-keys.yml | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)[\"root_token\"])'); BAO=\$(sudo k3s kubectl get svc -n openbao openbao -o jsonpath='{.spec.clusterIP}'); sudo k3s kubectl run baoq-\$RANDOM --rm -i --restart=Never --image=curlimages/curl -n openbao --quiet -- -sk -H \"X-Vault-Token: \$TOK\" https://\$BAO:8200/v1/secret/data/keycloak/realm-admin | python3 -c 'import sys,json;d=json.load(sys.stdin)[\"data\"][\"data\"];print(\"username:\",d[\"username\"]);print(\"password:\",d[\"password\"])'"

# Keycloak DB credentials synced by VSO
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

## Credential Map

| Purpose | Where |
|---|---|
| Keycloak master admin (console `/admin` only) | OpenBao `secret/keycloak/bootstrap-admin` -> secret `keycloak-bootstrap-admin` (ns `keycloak`), keys `username` and `password` |
| Realm `armory` admin — **Headlamp login** (username `admin`) | OpenBao `secret/keycloak/realm-admin` -> VSO -> secret `keycloak-realm-admin` (ns `keycloak`), key `password` |
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
- Password: OpenBao `secret/keycloak/realm-admin`, mirrored by VSO into the `keycloak-realm-admin` Secret (ns `keycloak`). See "Retrieve Generated Credentials" above.

#### Automatic password rotation

The realm `admin` password is rotated hands-off by the `keycloak-realm-admin-rotate`
CronJob (ns `keycloak`, ~monthly, `keycloak_realm_admin_rotation_schedule`). It
authenticates to Keycloak with a dedicated service-account client
(`realm-admin-rotator`, realm-management `manage-users` — not the master admin),
resets the user, and writes the new value to OpenBao; VSO propagates it to the
`keycloak-realm-admin` Secret within ~60s. Existing Headlamp sessions keep working
(tokens live to expiry); only your next login needs the refreshed password.

Trigger an immediate rotation:

```bash
vagrant ssh -c "sudo k3s kubectl create job -n keycloak rotate-now-\$RANDOM --from=cronjob/keycloak-realm-admin-rotate"
```

Disable rotation by setting `keycloak_realm_admin_rotation_enabled: false`.

## Teardown

```bash
cd /vagrant/project-armory/ansible
ansible-playbook playbooks/teardown_k3s_workloads.yml -e teardown_confirm=true
```

This teardown removes Keycloak workload resources first, then VSO, ingress, and OpenBao workload state.
