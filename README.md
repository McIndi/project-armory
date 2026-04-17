# Project Armory

A production-oriented infrastructure project building a cryptographic backbone for secrets management, PKI, and sensitive data storage. The foundation is a Vault deployment that all other services will integrate with.

Currently using [OpenBao](https://openbao.org) and [OpenTofu](https://opentofu.org) as open-source standins. The code is structured for a clean swap to HashiCorp Vault and Terraform when required for client environments.

---

## Repository Layout

```
project-armory/
├── vault/                  # OpenTofu module — deploys Vault via podman compose
│   ├── versions.tf         # Provider and OpenTofu version constraints
│   ├── variables.tf        # All configurable inputs with defaults
│   ├── main.tf             # TLS generation, config rendering, container lifecycle
│   ├── outputs.tf          # Connection info, init/unseal helpers, cert exports
│   ├── example.tfvars      # Reference values — copy to terraform.tfvars to deploy
│   └── templates/
│       ├── vault.hcl.tpl   # Vault server config (raft storage, TLS listener)
│       └── compose.yml.tpl # Podman Compose service definition
├── vault-config/           # OpenTofu module — configures Vault (PKI, AppRole)
│   ├── versions.tf
│   ├── variables.tf
│   ├── pki.tf              # Three-tier PKI hierarchy (root, internal, external CAs)
│   ├── auth.tf             # AppRole auth method
│   ├── outputs.tf
│   └── example.tfvars
├── tests/                  # End-to-end integration test suite
│   ├── conftest.py         # Session fixture: full lifecycle management
│   ├── test_tls.py         # Bootstrap TLS certificate assertions
│   ├── test_pki.py         # PKI issuance, chain, AIA/CRL validation
│   ├── test_auth.py        # Auth method assertions
│   └── requirements.txt    # pytest, hvac, cryptography
└── docs/
    ├── ADR/                # Architecture Decision Records
    └── pki_workflows.md    # Cryptographic material custody reference
```

---

## Requirements

| Tool | Minimum version | Notes |
|---|---|---|
| [OpenTofu](https://opentofu.org/docs/intro/install/) | 1.8.0 | `tofu` must be on `$PATH` |
| [Podman](https://podman.io/docs/installation) | 4.0 | `podman` must be on `$PATH` |
| [podman-compose](https://github.com/containers/podman-compose) | 1.0 | `podman compose` (plugin) or `podman-compose` |
| Linux kernel | — | `IPC_LOCK` capability required for mlock; set `disable_mlock = true` if unavailable (e.g. some WSL2 setups) |

The Vault/OpenBao CLI is **not** required on the host — `tofu output` prints ready-to-run `init` and `unseal` commands that can be executed directly. If you do have the CLI installed, set `VAULT_CACERT` to the generated CA path shown in the outputs.

---

## First Deployment

### 0. One-time host prerequisite

`deploy_dir` defaults to `/opt/armory/vault`. If that parent path doesn't exist yet, create it and give your user ownership before the first apply:

```bash
sudo mkdir -p /opt/armory
sudo chown $USER:$USER /opt/armory
```

Skip this if you set `deploy_dir` to a path you already own (e.g. `~/armory/vault`).

### 1. Create your `terraform.tfvars`

```bash
cp vault/example.tfvars vault/terraform.tfvars
```

Edit `terraform.tfvars`. The only value you are likely to change for a local deployment is `api_addr` — set it to your host's IP or hostname if you need to reach Vault from other machines. Everything else works out of the box with the defaults.

```hcl
# Expose Vault on the local network (example)
api_addr = "192.168.1.50"

# Add the host IP to the server cert's IP SANs
tls_san_ip = ["192.168.1.50"]
```

> `terraform.tfvars` is gitignored. Never commit it.

### 2. Initialise providers

```bash
cd vault
tofu init
```

### 3. Review the plan

```bash
tofu plan
```

### 4. Deploy

```bash
tofu apply
```

OpenTofu will:
1. Generate a self-signed CA and server certificate (ECDSA P-384).
2. Write TLS artefacts, the Vault config, and the Compose file to `deploy_dir` (default `/opt/armory/vault`).
3. Pull the OpenBao image and start the container via `podman compose`.

---

## Post-Deploy: Initialise, Unseal, and Configure

Deployment is a three-phase process. Each phase has its own OpenTofu module and state.

### Phase 1 — Deploy Vault (`vault/`)

```bash
cd vault/
tofu init
tofu apply
```

### Phase 2 — Key ceremony (manual, once only)

A brand-new Vault cluster starts sealed and uninitialised:

```bash
# Initialise — prints Unseal Key and Root Token
podman exec armory-vault bao operator init -key-shares=1 -key-threshold=1

# Unseal
podman exec armory-vault bao operator unseal <UNSEAL_KEY>
```

Save the **Unseal Key** and **Root Token** somewhere safe (a password manager, not a file on disk). These cannot be recovered. Vault must be unsealed after every restart.

### Phase 3 — Configure Vault (`vault-config/`)

```bash
cd vault-config/
cp example.tfvars terraform.tfvars   # first time only — no token in this file
export TF_VAR_vault_token=<ROOT_TOKEN>
tofu init
tofu apply
```

This configures the PKI hierarchy (replacing the former `pki-setup.sh`) and enables AppRole auth. A `ca-bundle.pem` is written to `vault/` for trust store import.

---

## Connecting to Vault

### Via the container

The canonical interface. The container has the CLI and the correct environment variables pre-configured:

```bash
podman exec armory-vault bao status
podman exec -e VAULT_TOKEN=<ROOT_TOKEN> armory-vault bao <command>
```

### From other services in the compose network

Services on the same `armory-net` network reach Vault at `https://armory-vault:8200`. Set `VAULT_CACERT` to the CA cert path inside whichever container needs it, or mount `/opt/armory/vault/tls/ca.crt` into it.

### Web UI / host CLI

Vault publishes port 8200 on `127.0.0.1` only (localhost-bound, not externally accessible). Access the UI at `https://127.0.0.1:8200/ui` and trust the CA on the host:

```bash
# Fedora / RHEL
sudo cp /opt/armory/vault/tls/ca.crt /etc/pki/ca-trust/source/anchors/armory-vault-ca.crt
sudo update-ca-trust
```

---

## Switching to HashiCorp Vault

Change four variables in `terraform.tfvars` and re-apply:

```hcl
image_registry = "docker.io/hashicorp"
image_name     = "vault"
image_tag      = "1.18.3"
vault_binary   = "vault"
```

No structural changes to the module are needed.

---

## Useful Commands

```bash
# Check container status
podman ps --filter name=armory-vault

# Tail logs
podman logs -f armory-vault

# Stop without destroying data
podman compose --project-name armory-vault -f /opt/armory/vault/compose.yml stop

# Tear down (destroys data volume — irreversible)
tofu destroy
```

---

## Runtime Directory Layout

OpenTofu creates the following on the host under `deploy_dir` (default `/opt/armory/vault`):

```
/opt/armory/vault/
├── compose.yml         # Generated Compose file
├── config/
│   └── vault.hcl       # Generated Vault server configuration
├── data/               # Raft integrated storage (mode 700)
├── tls/                # TLS artefacts (mode 700)
│   ├── ca.crt          # CA certificate — trust this on client machines
│   ├── vault.crt       # Server certificate chain (leaf + CA)
│   └── vault.key       # Server private key (mode 400)
└── logs/               # Log output mount
```

---

## Testing

The integration test suite performs a full destroy-rebuild-validate cycle automatically.

### Setup (once)

```bash
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
```

### Run

```bash
.venv/bin/pytest tests/ -v
```

This will:
1. Destroy any existing state
2. Apply `vault/`, init, and unseal
3. Apply `vault-config/`
4. Run 24 tests across TLS, PKI, and auth
5. Collect container logs to `tests/logs/`
6. Tear down everything

The root token is captured from `operator init` stdout and passed via `TF_VAR_vault_token` — it is never written to disk.

To leave the environment running after tests (for debugging):

```bash
ARMORY_NO_TEARDOWN=1 .venv/bin/pytest tests/ -v
```

See [ADR-015](docs/ADR/ADR-015-pytest-integration-testing.md) for the rationale behind this approach.

### Module-level tests (`tofu test`)

Fast, no infrastructure required. Run from each module directory:

```bash
cd vault/        && tofu test   # 12 tests — TLS SANs, key algorithm, outputs
cd vault-config/ && tofu test   # 12 tests — PKI config, role settings, auth
```

These use mocked providers — no containers start and no files are written.

---

## Security Trade-offs

### Encryption posture

All wire communication is encrypted. Vault enforces TLS 1.2+ on the API (8200) and cluster (8201) ports using an ECDSA P-384 certificate generated at deploy time. The in-container CLI and the `vault-config/` OpenTofu module both connect over HTTPS with the CA cert explicitly set. Vault encrypts all data before writing it to Raft storage (AES-256-GCM barrier encryption), and PKI private keys never leave Vault.

Two intentional trade-offs exist at the host level:

- **`terraform.tfstate` contains private keys in plaintext.** The TLS CA and server private keys are stored as plaintext JSON in `vault/terraform.tfstate`. The file is gitignored but unprotected on disk. Anyone with read access to the project directory can extract those keys. For a shared or server environment, use remote state with encryption (S3 + KMS, Terraform Cloud, etc.).
- **`vault.key` is world-readable (0444).** The server TLS private key must be readable by the container's internal user due to rootless Podman UID namespace mapping. On a single-user machine this is acceptable; on a shared host it is a meaningful exposure.

### Running OpenTofu inside a container

There is genuine value in containerising OpenTofu — primarily version pinning and CI/CD consistency. The same image can run locally and in GitHub Actions / GitLab CI, eliminating tool-version drift across environments. `versions.tf` already pins provider versions and the minimum OpenTofu version, which captures most of the reproducibility benefit without a container.

The specific complication for this project is that `null_resource` provisioners call `podman compose` and `podman exec` as `local-exec` commands, and `local_file` resources write directly to the host filesystem. Running OpenTofu inside a container would require mounting the Podman socket into the OpenTofu container — which grants that container root-equivalent access to the host. That trade-off is worth making consciously in a CI context and documenting explicitly; it is not a reason to avoid the pattern, but it is not free.

**Recommendation:** run OpenTofu on the host for local development. For CI/CD, use the official `ghcr.io/opentofu/opentofu` image, mount the Podman socket explicitly, and document the socket-access trade-off in your pipeline configuration.

---

## Vault Capabilities

See [`vault/CAPABILITIES.md`](vault/CAPABILITIES.md) for a full breakdown of what is active, what is available to enable, and what the current deployment intentionally lacks (auto-unseal, HA, audit logging, ACL policies).

---

## Variable Reference

| Variable | Default | Description |
|---|---|---|
| `deploy_dir` | `/opt/armory/vault` | Host path for all runtime artefacts |
| `node_id` | `vault-node-0` | Raft node identifier |
| `image_registry` | `quay.io/openbao` | Container registry |
| `image_name` | `openbao` | Image name |
| `image_tag` | `2.5.2` | Image version |
| `vault_binary` | `bao` | CLI binary name inside the container |
| `api_addr` | `127.0.0.1` | Advertised API address (used in vault.hcl and TLS SANs) |
| `ui_enabled` | `true` | Enable the web UI |
| `log_level` | `info` | Log verbosity (`trace` `debug` `info` `warn` `error`) |
| `disable_mlock` | `false` | **OpenBao only:** no effect (OpenBao v2+ dropped mlock). **HashiCorp Vault only:** set `true` if the host kernel lacks `IPC_LOCK` (e.g. some WSL2 setups). |
| `tls_san_dns` | `[]` | Additional DNS SANs (`localhost` and `tls_server_cn` are always included) |
| `tls_san_ip` | `[]` | Additional IP SANs for the server cert |
