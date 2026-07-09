# Project Armory

An Ansible-based reference architecture for a hardened, audit-ready platform
on a single Fedora VM: k3s with OIDC authentication, OpenBao for secrets and
PKI, Vault Secrets Operator, cert-manager and trust-manager for certificate
issuance and CA distribution, Envoy Gateway (Gateway API edge), Keycloak as the identity
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

## Virtual machine requirements

The platform is deployed by Ansible onto a single Fedora VM. How you create that
VM is your choice; it must meet the following spec before you run
`playbooks/site.yml`.

**Resources** (single control-plane node):

| Resource | Requirement |
|---|---|
| vCPUs | 8 |
| Memory | 16 GB |
| Disk | 60 GB |
| OS | Fedora 44 (x86_64) |
| Network | a routable IP reachable from your workstation (for the web UIs) |

`playbooks/site.yml` now installs project host dependencies via the
`host_dependencies` role (`ansible`, `ansible-lint`, `yamllint`, `python3-pip`,
`git`, `curl`, and `python3-kubernetes`).

**Runtime prerequisites** required by the `kubernetes.core` Ansible modules:

- `kubernetes.core` collection — `ansible-galaxy collection install -r ansible/requirements.yml`
- `helm-diff` plugin — installed idempotently by the `helm` role, required for
  `kubernetes.core.helm` no-op detection

Helm, k3s, and all platform components are installed by `ansible-playbook
playbooks/site.yml`.

## Quickstart


```bash
vagrant up
vagrant ssh
```

Inside the VM:

```bash
cd /vagrant
# cp .env.example .env            # first time only; defaults work for the demo
# Clean up log files (except .empty) from previous runs
find ./log -type f ! -name ".empty" -delete
set -a; source .env; set +a
cd "${ARMORY_ANSIBLE_ROOT}"

ansible-playbook playbooks/site.yml             # full deploy (~10–15 min)
bash scripts/capture_run_snapshot.sh            # Create a snapshot of the current state (for audit, not for backup)
```

To use the web UIs, add hosts-file entries on your workstation for
`armory.local`, `headlamp.armory.local`, and `openbao.armory.local` pointing
at the VM IP, and trust the Armory Root CA. Then:

- Keycloak: `https://armory.local/`
- Headlamp: `https://headlamp.armory.local` (login `admin`; password below)
- OpenBao UI: `https://openbao.armory.local` — see [OpenBao UI login](#openbao-ui-login) below

## Retrieve generated credentials

All credentials are generated during deployment and stored in OpenBao —
nothing is printed to the console (`no_log`) and nothing is committed to the
repo. Retrieving them is part of setup, not an optional step. VSO mirrors
each value into a Kubernetes Secret, which is the easiest place to read it
(run from the workstation):

```bash
# Realm admin — the Headlamp login (username: admin)
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-realm-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Realm operator / viewer — also valid for OpenBao UI login
# (username is printed with each password)
vagrant ssh -c "TOK=\$(sudo ansible-vault decrypt --vault-password-file /opt/openbao/.vault-pass --output - /opt/openbao/provisioner-token.yml | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)[\"provisioner_token\"])'); BAO=\$(sudo k3s kubectl get svc -n openbao openbao -o jsonpath='{.spec.clusterIP}'); for U in operator viewer; do echo \"==> \$U\"; sudo k3s kubectl run baoq-\$RANDOM --rm -i --restart=Never --image=curlimages/curl -n openbao --quiet -- -sk -H \"X-Vault-Token: \$TOK\" https://\$BAO:8200/v1/secret/data/keycloak/realm-users/\$U | python3 -c 'import sys,json;d=json.load(sys.stdin)[\"data\"][\"data\"];print(\"username:\",d[\"username\"]);print(\"password:\",d[\"password\"])'; done"

# Keycloak master bootstrap admin — Keycloak admin console (/admin) only
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.username}' | base64 -d; echo"
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Keycloak database credentials
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

| Purpose | OpenBao path (source of truth) | k8s Secret (ns `keycloak`) |
|---|---|---|
| Realm `armory` admin — Headlamp and OpenBao UI login | `secret/keycloak/realm-admin` | `keycloak-realm-admin` |
| Realm `armory` operator — OpenBao UI login | `secret/keycloak/realm-users/operator` | — |
| Realm `armory` viewer — OpenBao UI login | `secret/keycloak/realm-users/viewer` | — |
| Keycloak master admin (console only) | `secret/keycloak/bootstrap-admin` | `keycloak-bootstrap-admin` |
| Keycloak DB | `secret/keycloak/db` | `keycloak-db-secret` |

Note: the realm admin password rotates automatically (~monthly), so re-read
it if a login fails. Reading OpenBao directly (e.g. before VSO has synced)
and rotation details: [doc/operations.md](doc/operations.md#retrieve-generated-credentials).

## OpenBao UI login

To log in to the [OpenBao UI](https://openbao.armory.local):

1. **Method**: Select **OIDC**. The OpenBao instance is configured with Keycloak
   (realm `armory`) as the OIDC provider; you will be redirected to Keycloak
   to authenticate.
2. **Namespace**: Leave blank (uses root/default namespace; OpenBao here runs
   open-source with no namespace isolation).
3. **Role**: Leave blank to use the default OIDC role. Your effective
   permissions are determined by your Keycloak group membership:

| Keycloak group | OpenBao policy scope |
|---|---|
| `armory-admins` | admin (full access) |
| `armory-operators` | operator (manage secrets/PKI) |
| `armory-viewers` | viewer (metadata/list only) |
| (none of the above) | `default` (baseline only) |

4. **Credentials**: Log in with your realm `armory` user (`admin`, `operator`,
   or `viewer`) and the password retrieved above.

## Automation credentials

Day-to-day Ansible automation uses a scoped periodic OpenBao token named
`ansible-provisioner`, minted by the openbao role and stored at
`/opt/openbao/provisioner-token.yml` (Ansible-vault encrypted with
`/opt/openbao/.vault-pass`).

Scope is defined in `ansible/roles/openbao/tasks/provisioner_token.yml`:

- create/read/update on `secret/data/keycloak/*` and `secret/data/headlamp/*`
- read on `pki-ext/ca/pem`
- read+sudo on `sys/audit` (read-only listing; cannot enable/disable devices)
- lookup-self/renew-self only for token maintenance

Consumer ACL policies and Kubernetes auth roles are written at bootstrap by
the openbao role with the root token (`consumer_wiring.yml`). The provisioner
token has no `sys/policies/acl/*` or `auth/kubernetes/role/*` capabilities,
so it cannot author policy or bind identities.

Residual blast radius: the provisioner token can read and overwrite the app
secrets it provisions, including `secret/data/keycloak/bootstrap-admin`.
This is expected for its provisioning role.

OpenBao root token usage is reserved for bootstrap and break-glass only.
Break-glass access paths:

- decrypt `/opt/openbao/init-keys.yml` on the VM
- read `secret/openbao/init` from OpenBao KV

If the provisioner token is missing or invalid, re-mint with:

```bash
ansible-playbook playbooks/site.yml --tags openbao
```

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

## Refreshing the `delve:latest` image

The `delve-web`, `delve-worker`, and migrate Job workloads use `imagePullPolicy: Always` with `ghcr.io/mcindi/delve:latest`. Because the tag is mutable, k3s will re-resolve the image digest whenever new pods are created; you only need to restart the workloads so they pick up the current upstream image.

From the VM:

```bash
vagrant ssh
export KUBECONFIG=<delve_kubeconfig_path>   # for example: /etc/rancher/k3s/k3s.yaml

# Force fresh pulls for the web and worker deployments
k3s kubectl rollout restart deployment/delve-web deployment/delve-worker -n delve

# Watch them come up on the new image
k3s kubectl rollout status deployment/delve-web -n delve
k3s kubectl rollout status deployment/delve-worker -n delve
```

If the image update includes a schema or migration change, re-run the migrate Job as well. The simplest path is to re-apply the Ansible deploy, which re-triggers the Helm hook:

```bash
ansible-playbook ... --tags delve
# or rerun the delve role from the project-armory playbook root
```

In most cases, a rollout restart is enough for the web and worker deployments. No manual `crictl rmi`, image pre-pull, or Helm upgrade is needed; `Always` causes each new pod to resolve `ghcr.io/mcindi/delve:latest` against the registry instead of using a cached digest.

If your environment overrides the defaults, verify `delve_kubeconfig_path` and `delve_namespace` in `ansible/roles/delve/defaults/main.yml` before running the commands above.