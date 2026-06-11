# Project Armory

An Ansible-based reference architecture for a hardened, audit-ready platform
on a single Fedora VM: k3s with OIDC authentication, OpenBao for secrets and
PKI, Vault Secrets Operator, cert-manager and trust-manager for certificate
issuance and CA distribution, ingress-nginx, Keycloak as the identity
provider, and Headlamp as the cluster UI. All components are open source.
It is built as a demonstration: one VM, one command, every credential
generated and stored centrally, TLS on every path, and an audit trail for
secret access.

A companion project (project-garrison) deploys an AI agent runtime against
this platform's Keycloak; armory itself is the identity and secrets
foundation.

## Documentation

| Document | Contents |
|---|---|
| [doc/architecture.md](doc/architecture.md) | Component map, role order, secrets flow, PKI/trust chain, OIDC topology |
| [doc/operations.md](doc/operations.md) | Runbook: deploy, readiness, credentials, audit log, rotation, break-glass, teardown, troubleshooting |
| [doc/security.md](doc/security.md) | Credential model, TLS matrix, audit logging, demo-vs-production gaps |
| [doc/configuration.md](doc/configuration.md) | `.env`, group_vars toggles, role-default override points |
| [doc/decisions/](doc/decisions/) | Decision records (why things are the way they are) |
| [AGENTS.md](AGENTS.md) | Conventions for agents/contributors working in the repo |

## Quickstart

Host prerequisites: Vagrant with a provider, this repo cloned.

```bash
vagrant up
vagrant ssh
```

Inside the VM:

```bash
cd /vagrant
cp .env.example .env            # first time only; defaults work for the demo
set -a; source .env; set +a
cd "${ARMORY_ANSIBLE_ROOT}"

ansible-playbook playbooks/site.yml             # full deploy (~10–15 min)
ansible-playbook playbooks/readiness_check.yml  # validate
```

To use the web UIs, add hosts-file entries on your workstation for
`armory.local` and `headlamp.armory.local` pointing at the VM IP, and trust
the Armory Root CA. Then:

- Keycloak: `https://armory.local/realms/armory/.well-known/openid-configuration`
- Headlamp: `https://headlamp.armory.local` (login `admin`; password below)

## Retrieve generated credentials

All credentials are generated during deployment and stored in OpenBao —
nothing is printed to the console (`no_log`) and nothing is committed to the
repo. Retrieving them is part of setup, not an optional step. VSO mirrors
each value into a Kubernetes Secret, which is the easiest place to read it
(run from the workstation):

```bash
# Realm admin — the Headlamp login (username: admin)
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-realm-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Keycloak master bootstrap admin — Keycloak admin console (/admin) only
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Keycloak database credentials
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

| Purpose | OpenBao path (source of truth) | k8s Secret (ns `keycloak`) |
|---|---|---|
| Realm `armory` admin — Headlamp login | `secret/keycloak/realm-admin` | `keycloak-realm-admin` |
| Keycloak master admin (console only) | `secret/keycloak/bootstrap-admin` | `keycloak-bootstrap-admin` |
| Keycloak DB | `secret/keycloak/db` | `keycloak-db-secret` |

Note: the realm admin password rotates automatically (~monthly), so re-read
it if a login fails. Reading OpenBao directly (e.g. before VSO has synced)
and rotation details: [doc/operations.md](doc/operations.md#retrieve-generated-credentials).

## Repository layout

```
ansible/
  playbooks/        site.yml (deploy), readiness_check.yml, teardown_k3s_workloads.yml
  roles/            one role per component; execution order in doc/architecture.md
  inventories/      development inventory (localhost) + group_vars toggles
charts/
  vso-hardened/     locally maintained VSO chart with kube-rbac-proxy TLS
doc/                architecture, operations, security, configuration, decisions, archived handoffs
```

## Common commands

All inside the VM with `.env` sourced, from `${ARMORY_ANSIBLE_ROOT}`:

```bash
ansible-playbook playbooks/site.yml --tags openbao      # targeted re-run (all roles are tagged)
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
ansible-playbook playbooks/teardown_k3s_workloads.yml -e teardown_confirm=true   # destructive
```

Full command reference and troubleshooting: [doc/operations.md](doc/operations.md).
