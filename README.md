# Project Armory

Project Armory is an Ansible-driven reference deployment for a hardened,
audit-ready OpenShift footprint with:

- OpenBao as the secrets and PKI source of truth
- cert-manager issuance from OpenBao ClusterIssuers
- Keycloak as the OIDC identity provider
- Envoy-based edge routing for Keycloak and OpenBao
- Optional in-cluster OCI registry

A companion project (project-garrison) can integrate with this platform's
identity and secrets foundation.

## Documentation

| Document | Contents |
|---|---|
| [doc/architecture.md](doc/architecture.md) | Component map, role order, secrets flow, PKI/trust chain, OIDC topology |
| [doc/operations.md](doc/operations.md) | Runbook: deploy, readiness, credentials, audit log, break-glass, teardown, troubleshooting |
| [doc/security.md](doc/security.md) | Credential model, TLS matrix, audit logging, demo-vs-production gaps |
| [doc/configuration.md](doc/configuration.md) | `.env`, inventory/group_vars toggles, role-default override points |
| [doc/decisions/](doc/decisions/) | Decision records |
| [AGENTS.md](AGENTS.md) | Conventions for agents/contributors |

## Environment requirements

Project Armory targets an OpenShift cluster. This repo is commonly developed and
validated from a Fedora 44 workstation and local Ansible checks. Clone the repo
to `~/project-armory` or `/opt/project-armory` and use that path consistently.

Runtime prerequisites:

- `ansible-core`
- `kubernetes.core` collection
- `helm`
- `helm-diff` plugin (managed idempotently by the `helm` role)
- Access to an OpenShift kubeconfig for the target cluster

Install Ansible collections:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

## Quickstart (Fedora 44 workstation workflow)

From the workstation:

```bash
cd ~/project-armory
# or: cd /opt/project-armory
cp .env.openshift.example .env    # first run only
set -a; source .env; set +a
cd ansible

# One-time privileged setup (cluster-admin context)
ansible-playbook playbooks/bootstrap.yml

# Main deployment (scoped automation account)
ansible-playbook playbooks/site.yml

# Optional local run snapshot (audit artifact, not backup)
bash scripts/capture_run_snapshot.sh
```

## Retrieve generated credentials

Credentials are generated during deployment and persisted in OpenBao.
The playbook materializes required Kubernetes Secrets directly (no VSO sync
controller).

Examples from the workstation:

```bash
# Realm admin password (Keycloak namespace from openshift inventory default)
cd ~/project-armory
set -a; source .env; set +a
cd ansible
oc get secret -n tex26-oidc keycloak-realm-admin -o jsonpath='{.data.password}' | base64 -d; echo

# Keycloak bootstrap admin username/password
oc get secret -n tex26-oidc keycloak-bootstrap-admin -o jsonpath='{.data.username}' | base64 -d; echo
oc get secret -n tex26-oidc keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo

# Keycloak database password
oc get secret -n tex26-oidc keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Authoritative source of truth remains OpenBao KV paths configured by the
`keycloak` role.

## OpenBao UI login

OpenBao UI is exposed behind the Envoy/Route edge. Login uses OIDC through
Keycloak (realm `armory`):

1. In OpenBao UI, choose OIDC auth.
2. Keep namespace/role blank unless your environment defines custom values.
3. Sign in with a realm user mapped to OpenBao policies (`admin`, `operator`,
   or `viewer` depending on your provisioning data).

## Common commands

All commands below assume execution in `~/project-armory/ansible` or
`/opt/project-armory/ansible` with `.env` sourced.

```bash
# Local validation gates
ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --syntax-check
ansible-playbook -i inventories/openshift playbooks/site.yml --check
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --check

# Lint
ansible-lint -c .ansible-lint playbooks/site.yml playbooks/bootstrap.yml roles

# Targeted reruns
ansible-playbook playbooks/site.yml --tags keycloak_install
ansible-playbook playbooks/site.yml --tags openbao

# Destructive teardown (cluster-admin only)
ansible-playbook playbooks/teardown_openshift.yml -e teardown_confirm=true
```

For full operational workflows, see [doc/operations.md](doc/operations.md).

## Repository layout

```
ansible/
  inventories/      OpenShift inventory and group_vars
  playbooks/        bootstrap.yml, site.yml, readiness_check.yml, teardown_openshift.yml
  roles/            component roles in deployment order
  scripts/          helper scripts (snapshot, utility helpers)
doc/                architecture, operations, security, configuration, decisions
```
