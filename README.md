# Project Armory

A production-oriented infrastructure project building a cryptographic backbone for secrets management, PKI, and sensitive data storage. The foundation is a Vault deployment that all other services integrate with for certificate issuance, dynamic database credentials, and OIDC-backed operator login.

Currently using [OpenBao](https://openbao.org) and [OpenTofu](https://opentofu.org) as open-source standins. The code is structured for a clean swap to HashiCorp Vault and Terraform when required for client environments.

> **Demo / local environment:** This project is a single-user learning environment. Two intentional limitations apply to all deployments: `terraform.tfstate` stores TLS private keys in plaintext on disk, and `vault.key` is world-readable by all local users. These trade-offs are [documented in detail below](#security-trade-offs) (see also [ADR-012](docs/ADR/ADR-012-local-tfstate-demo-limitation.md) and [ADR-005](docs/ADR/ADR-005-world-readable-tls-artifacts.md)). **Do not use this configuration on a shared host or as a production baseline without first migrating to remote encrypted state and tightening host permissions.**

---

## Repository Layout

```
project-armory/
├── vault/                    # OpenTofu module — deploys Vault via podman compose
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf               # TLS generation, config rendering, container lifecycle
│   ├── outputs.tf
│   ├── example.tfvars
│   └── templates/
│       ├── vault.hcl.tpl     # Vault server config (raft storage, TLS listener, audit)
│       └── compose.yml.tpl
├── vault-config/             # OpenTofu module — configures Vault (PKI, secrets engines, auth)
│   ├── versions.tf
│   ├── variables.tf
│   ├── pki.tf                # Three-tier PKI hierarchy (root, internal, external CAs)
│   ├── auth.tf               # AppRole + userpass auth methods (userpass toggleable)
│   ├── policies.tf           # ACL policies: operator, kv_admin, kv_reader_keycloak, keycloak_db, app_db
│   ├── audit.tf              # Audit device note (OpenBao 2.x: declared in vault.hcl, not API)
│   ├── kv.tf                 # KV v2 mount + Keycloak admin bootstrap secret
│   ├── database.tf           # Database secrets engine: Postgres connection, static + dynamic roles
│   ├── oidc.tf               # OIDC auth method backed by Keycloak (toggled by oidc_enabled)
│   ├── outputs.tf
│   └── example.tfvars
├── services/
│   ├── webserver/            # OpenTofu module — nginx + Vault Agent sidecar
│   │   ├── main.tf           # Vault policy, AppRole, dir scaffolding, compose deploy
│   │   ├── templates/
│   │   │   ├── agent.hcl.tpl       # Vault Agent: AppRole + pkiCert
│   │   │   ├── nginx.conf.tpl
│   │   │   └── compose.yml.tpl
│   │   └── ...
│   ├── postgres/             # OpenTofu module — PostgreSQL container
│   │   ├── main.tf           # Dir scaffolding, config rendering, podman compose deploy
│   │   ├── templates/
│   │   │   ├── compose.yml.tpl     # pg_isready healthcheck, armory-net
│   │   │   └── init.sql.tpl        # Creates databases, vault_mgmt role, template roles
│   │   └── ...
│   └── keycloak/             # OpenTofu module — Keycloak + Vault Agent sidecar
│       ├── main.tf           # Vault policy, AppRole (PKI + DB + KV policies), compose deploy
│       ├── templates/
│       │   ├── agent.hcl.tpl       # Vault Agent: pkiCert + DB static-creds + KV admin
│       │   └── compose.yml.tpl     # vault-agent + keycloak services
│       └── ...
├── tests/                    # End-to-end integration test suite
│   ├── conftest.py           # Session fixtures: full lifecycle management
│   ├── test_tls.py
│   ├── test_pki.py
│   ├── test_auth.py
│   ├── test_webserver.py
│   └── requirements.txt
└── docs/
    ├── ADR/                  # Architecture Decision Records (ADR-001 through ADR-018)
    └── pki_workflows.md      # Cryptographic material custody reference
```

---

## Requirements

| Tool | Minimum version | Notes |
|---|---|---|
| [OpenTofu](https://opentofu.org/docs/intro/install/) | 1.8.0 | `tofu` must be on `$PATH` |
| [Podman](https://podman.io/docs/installation) | 4.0 | `podman` must be on `$PATH` |
| [podman-compose](https://github.com/containers/podman-compose) | 1.0 | `podman compose` plugin or `podman-compose` |
| Linux kernel | — | `IPC_LOCK` for mlock; set `disable_mlock = true` if unavailable (some WSL2 setups) |

The Vault/OpenBao CLI is **not** required on the host — `tofu output` prints ready-to-run `init` and `unseal` commands. If you do have the CLI installed, set `VAULT_CACERT` to the generated CA path.

---

## Deployment

Deployment is a multi-phase process. Each phase has its own OpenTofu module and state file. **Modules must be applied in order** — later modules depend on earlier ones being in place.

### 0. One-time host prerequisite

```bash
sudo mkdir -p /opt/armory
sudo chown $USER:$USER /opt/armory
```

Skip if you set `deploy_dir` to a path you already own (e.g. `~/armory/vault`).

---

### Phase 1 — Deploy Vault

```bash
cd vault/
cp example.tfvars terraform.tfvars   # edit api_addr / tls_san_ip if needed
tofu init
tofu apply
```

OpenTofu generates TLS certificates, writes the Vault server config, and starts the container.

---

### Phase 2 — Key ceremony (once only)

```bash
# Initialise — prints Unseal Key and Root Token
podman exec armory-vault bao operator init -key-shares=1 -key-threshold=1

# Unseal
podman exec armory-vault bao operator unseal <UNSEAL_KEY>
```

Save the **Unseal Key** and **Root Token** in a password manager. These cannot be recovered. Vault must be unsealed after every restart.

---

### Phase 3 — Configure Vault

```bash
cd vault-config/
cp example.tfvars terraform.tfvars   # first time only
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init
tofu apply
```

Configures PKI hierarchy, AppRole auth, userpass operator account, KV v2 engine (with Keycloak admin credential), Database secrets engine (Postgres connection pre-configured but not yet verified), and all ACL policies. A `vault/ca-bundle.pem` is written for trust store import.

> The Database engine connection has `verify_connection = false` — Vault accepts the
> configuration without contacting Postgres. The connection is validated the first time
> a credential is actually requested (when Keycloak starts).

---

### Phase 4 — Deploy the webserver (optional demo)

```bash
cd services/webserver/
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init
tofu apply
```

nginx on port 8443 with a Vault Agent sidecar for TLS certificate issuance. Reachable at `https://127.0.0.1:8443`.

> Rootless Podman cannot bind to privileged ports (< 1024). Port 8443 is used instead of 443.

---

### Phase 5 — Deploy PostgreSQL

```bash
cd services/postgres/
cp example.tfvars terraform.tfvars
tofu init
tofu apply
```

Creates `keycloak` and `app` databases, the `vault_mgmt` credential management account, and template roles with appropriate grants. No Vault token needed — this module has no Vault resources.

Verify:

```bash
podman exec armory-postgres psql -U postgres -c "\du"   # vault_mgmt role present
podman exec armory-postgres psql -U postgres -c "\l"    # keycloak + app databases
```

---

### Phase 6 — Deploy Keycloak

```bash
cd services/keycloak/
cp example.tfvars terraform.tfvars
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init
tofu apply
```

Starts Keycloak on port 8444 with a Vault Agent sidecar that manages:
- TLS certificate from `pki_ext` — rendered to `/opt/armory/keycloak/certs/keycloak.pem`
- PostgreSQL password from the Database secrets static role — rendered to `/opt/armory/keycloak/secrets/keycloak.env`
- Admin bootstrap credentials from KV v2 — rendered to `/opt/armory/keycloak/secrets/keycloak-admin.env`

Keycloak does not start until the vault-agent healthcheck confirms both the TLS cert and DB credentials are present.

Access the Keycloak admin console at `https://127.0.0.1:8444/admin` using the admin credentials stored in `kv/data/keycloak/admin`.

---

### Phase 7 — Configure Keycloak realm (manual)

Before enabling OIDC in Vault, set up the Keycloak side:

1. Log in to `https://127.0.0.1:8444/admin`
2. Create realm **`armory`**
3. Create OIDC client **`vault`** (Client authentication: ON, note the client secret)
4. Create group **`vault-operators`**, add the operator user
5. Add a **Group Membership** protocol mapper on the `vault` client, token claim name `groups`

---

### Phase 8 — Enable OIDC auth (ceremony)

This is a three-step ceremony — do not skip steps:

**Step 1:** Apply Vault OIDC config (userpass stays active during transition):

```bash
cd vault-config/
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu apply \
  -var oidc_enabled=true \
  -var oidc_client_id=vault \
  -var 'oidc_client_secret=<CLIENT_SECRET_FROM_KEYCLOAK>'
```

**Step 2:** Verify OIDC login works:

```bash
bao login -method=oidc role=operator
# Must succeed and return the 'operator' policy
```

**Step 3:** Retire userpass (only after OIDC is confirmed working):

```bash
tofu apply \
  -var oidc_enabled=true \
  -var oidc_client_id=vault \
  -var 'oidc_client_secret=<CLIENT_SECRET>' \
  -var userpass_enabled=false
```

> **Never run Step 3 before Step 2.** Removing userpass before OIDC is verified working
> will lock you out of Vault. If that happens, restart Vault with a root token from the
> key ceremony and re-enable userpass.

---

## Connecting to Vault

### Via the container

```bash
podman exec armory-vault bao status
podman exec -e VAULT_TOKEN=<TOKEN> armory-vault bao <command>
```

### From other services on armory-net

Services on `armory-net` reach Vault at `https://armory-vault:8200`. Mount `/opt/armory/vault/tls/ca.crt` as `VAULT_CACERT`.

### Web UI / host CLI

Port 8200 is bound to `127.0.0.1` only. Access the UI at `https://127.0.0.1:8200/ui`. Trust the CA:

```bash
# Fedora / RHEL
sudo cp /opt/armory/vault/tls/ca.crt /etc/pki/ca-trust/source/anchors/armory-vault-ca.crt
sudo update-ca-trust
```

### Operator login (userpass, before OIDC)

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=/opt/armory/vault/tls/ca.crt
bao login -method=userpass username=operator
```

### Audit log

```bash
tail -f /opt/armory/vault/logs/audit.log | python3 -m json.tool
```

All credential issuance, KV reads, OIDC logins, and PKI operations are logged here.

---

## Switching to HashiCorp Vault

Change four variables in `vault/terraform.tfvars` and re-apply:

```hcl
image_registry = "docker.io/hashicorp"
image_name     = "vault"
image_tag      = "1.18.3"
vault_binary   = "vault"
```

The `vault_audit` resource is commented out in `vault-config/audit.tf` — uncomment it if using HashiCorp Vault (the runtime audit API is available there but blocked in OpenBao 2.x).

---

## Testing

### Integration tests

The integration test suite performs a full destroy-rebuild-validate cycle automatically.

```bash
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/pytest tests/ -v
```

This will:
1. Destroy any existing state (containers, deploy dirs, stale tfstate)
2. `tofu init -upgrade` for vault/ and vault-config/ (idempotent on subsequent runs)
3. Apply `vault/`, init, and unseal
4. Apply `vault-config/`
5. Apply `services/webserver/` and wait for nginx
6. Run tests across TLS, PKI, auth, and webserver
7. Collect container logs to `tests/logs/`
8. Tear down everything

The root token is captured from `operator init` stdout and passed via `TF_VAR_vault_token` — it is never written to disk. To leave the environment running after tests:

```bash
ARMORY_NO_TEARDOWN=1 .venv/bin/pytest tests/ -v
```

See [ADR-015](docs/ADR/ADR-015-pytest-integration-testing.md) for the rationale.

### Module-level tests (`tofu test`)

Fast, no infrastructure required. Run from each module directory:

```bash
cd vault/              && tofu test   # TLS SANs, key algorithm, outputs
cd vault-config/       && tofu test   # PKI config, policies, auth, KV, Database engine, OIDC
cd services/webserver/ && tofu test   # Vault policy, AppRole, compose healthcheck
cd services/postgres/  && tofu test   # Compose healthcheck, init.sql correctness
cd services/keycloak/  && tofu test   # Vault policy, AppRole (3 policies), compose healthchecks, agent templates
```

All use mocked providers — no containers start and no files are written.

---

## Runtime Directory Layout

```
/opt/armory/
├── vault/
│   ├── compose.yml
│   ├── config/vault.hcl
│   ├── data/               # Raft storage
│   ├── tls/                # ca.crt, vault.crt, vault.key
│   ├── logs/audit.log      # Vault audit log
│   └── ca-bundle.pem       # All three CA certs — import into OS trust store
├── postgres/
│   ├── compose.yml
│   ├── pgdata/             # PostgreSQL data directory
│   └── init.sql            # Bootstrap SQL (runs once on first start)
├── webserver/
│   ├── compose.yml
│   ├── agent/agent.hcl
│   ├── approle/            # role_id, wrapped_secret_id
│   ├── certs/nginx.pem     # TLS cert rendered by Vault Agent
│   └── nginx/nginx.conf
└── keycloak/
    ├── compose.yml
    ├── agent/agent.hcl
    ├── approle/            # role_id, wrapped_secret_id
    ├── certs/keycloak.pem  # TLS cert (cert + CA + key)
    └── secrets/
        ├── keycloak.env          # KC_DB_PASSWORD (rotated by Vault)
        └── keycloak-admin.env    # KC_BOOTSTRAP_ADMIN_* (from KV v2)
```

---

## Security Trade-offs

### Encryption posture

All wire communication is encrypted. Vault enforces TLS 1.2+ on the API (8200) and cluster (8201) ports. PKI private keys never leave Vault. Database credentials are short-lived (dynamic) or automatically rotated (static). Vault Agent renders credentials to files accessible only within the compose network.

Two intentional trade-offs exist at the host level:

- **`terraform.tfstate` contains private keys in plaintext.** TLS CA and server private keys, as well as Vault-managed passwords, are stored as plaintext JSON in state files. These are gitignored but unprotected on disk. Use remote state with encryption for any shared or server environment.
- **`vault.key` is world-readable (0444).** Required by rootless Podman UID namespace mapping. Acceptable on a single-user machine.

### Running OpenTofu inside a container

`null_resource` provisioners call `podman compose` and `local_file` resources write to the host filesystem. Running OpenTofu in a container requires mounting the Podman socket (root-equivalent host access). For local development, run OpenTofu on the host. For CI/CD, use `ghcr.io/opentofu/opentofu`, mount the socket explicitly, and document the trade-off.

---

## Architecture Decisions

See [`docs/ADR/`](docs/ADR/) for all 18 Architecture Decision Records, including:

- [ADR-002](docs/ADR/ADR-002-three-tier-pki-hierarchy.md) — Three-tier PKI hierarchy
- [ADR-009](docs/ADR/ADR-009-vault-agent-sidecar.md) — Vault Agent sidecar pattern
- [ADR-011](docs/ADR/ADR-011-separate-opentofu-modules.md) — Separate OpenTofu modules per concern
- [ADR-016](docs/ADR/ADR-016-webserver-vault-agent-sidecar.md) — Vault Agent combined PEM pattern
- [ADR-017](docs/ADR/ADR-017-postgres-vault-database-engine.md) — PostgreSQL + Vault Database secrets engine
- [ADR-018](docs/ADR/ADR-018-keycloak-oidc-human-identity.md) — Keycloak for human identity + OIDC auth

---

## Variable Reference

### `vault/` module

| Variable | Default | Description |
|---|---|---|
| `deploy_dir` | `/opt/armory/vault` | Host path for runtime artefacts |
| `api_addr` | `127.0.0.1` | Advertised API address (used in vault.hcl and TLS SANs) |
| `node_id` | `vault-node-0` | Raft node identifier |
| `image_registry` | `quay.io/openbao` | Container registry |
| `image_name` | `openbao` | Image name |
| `image_tag` | `2.5.2` | Image version |
| `vault_binary` | `bao` | CLI binary inside the container |
| `ui_enabled` | `true` | Enable the web UI |
| `log_level` | `info` | Log verbosity |
| `disable_mlock` | `false` | Set `true` if kernel lacks `IPC_LOCK` |
| `tls_san_dns` | `[]` | Extra DNS SANs for the server cert |
| `tls_san_ip` | `[]` | Extra IP SANs for the server cert |

### `vault-config/` module

| Variable | Default | Description |
|---|---|---|
| `operator_password` | `armory-demo-2026` | Userpass operator account password |
| `userpass_enabled` | `true` | Keep userpass active (set false after OIDC verified) |
| `postgres_host` | `armory-postgres` | PostgreSQL container hostname on armory-net |
| `vault_mgmt_password` | `vault-mgmt-demo-2026` | Password for the vault_mgmt PG role |
| `keycloak_admin_password` | `armory-demo-2026` | Bootstrap password stored in KV v2 |
| `oidc_enabled` | `false` | Enable OIDC auth method (requires Keycloak running) |
| `keycloak_url` | `https://127.0.0.1:8444` | Keycloak base URL for OIDC discovery |
| `oidc_client_id` | `vault` | OIDC client ID in the armory realm |
| `oidc_client_secret` | `""` | OIDC client secret (set when enabling OIDC) |

### `services/postgres/` module

| Variable | Default | Description |
|---|---|---|
| `deploy_dir` | `/opt/armory/postgres` | Host path for runtime artefacts |
| `container_name` | `armory-postgres` | PostgreSQL container name on armory-net |
| `postgres_image` | `docker.io/postgres:16-alpine` | Container image |
| `postgres_password` | `postgres-demo-2026` | Superuser password |
| `vault_mgmt_password` | `vault-mgmt-demo-2026` | vault_mgmt role password |

### `services/keycloak/` module

| Variable | Default | Description |
|---|---|---|
| `deploy_dir` | `/opt/armory/keycloak` | Host path for runtime artefacts |
| `keycloak_container_name` | `armory-keycloak` | Keycloak container name |
| `keycloak_image` | `quay.io/keycloak/keycloak:24.0` | Container image |
| `keycloak_port` | `8444` | Host port for Keycloak HTTPS |
| `postgres_host` | `armory-postgres` | PostgreSQL container hostname |
| `server_name` | `armory-keycloak` | TLS certificate common name |
| `cert_ip_sans` | `[]` | Extra IP SANs for Keycloak TLS cert |
| `cert_dns_sans` | `[]` | DNS SANs for Keycloak TLS cert |
