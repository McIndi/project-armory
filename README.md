# Project Armory

A production-oriented infrastructure project building a cryptographic backbone for secrets management, PKI, and sensitive data storage. The foundation is a Vault deployment that all other services will integrate with.

Currently using [OpenBao](https://openbao.org) and [OpenTofu](https://opentofu.org) as open-source standins. The code is structured for a clean swap to HashiCorp Vault and Terraform when required for client environments.

---

## Repository Layout

```
project-armory/
└── vault/                  # OpenTofu module — deploys Vault via podman compose
    ├── versions.tf         # Provider and OpenTofu version constraints
    ├── variables.tf        # All configurable inputs with defaults
    ├── main.tf             # TLS generation, config rendering, container lifecycle
    ├── outputs.tf          # Connection info, init/unseal helpers, cert exports
    ├── example.tfvars      # Reference values — copy to terraform.tfvars to deploy
    └── templates/
        ├── vault.hcl.tpl   # Vault server config (raft storage, TLS listener)
        └── compose.yml.tpl # Podman Compose service definition
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

## Post-Deploy: Initialise and Unseal

A brand-new Vault cluster starts **sealed and uninitialised**. Run these two steps once after the first `tofu apply`.

### Initialise

Copy the `init_command` from the apply output and run it:

```bash
tofu output -raw init_command | bash
```

Save the **Unseal Key** and **Root Token** printed to stdout somewhere safe (a password manager, not a file on disk). These cannot be recovered.

### Unseal

Copy the unseal command template from the output and substitute your unseal key:

```bash
VAULT_ADDR=https://127.0.0.1:8200 \
  VAULT_CACERT=/opt/armory/vault/tls/ca.crt \
  bao operator unseal <UNSEAL_KEY>
```

Vault must be unsealed after every restart before it will serve requests.

---

## Connecting to Vault

### From the host CLI

```bash
export VAULT_ADDR=$(tofu -chdir=vault output -raw vault_addr)
export VAULT_CACERT=$(tofu -chdir=vault output -raw vault_cacert_path)
export VAULT_TOKEN=<ROOT_TOKEN>

bao status
```

### Web UI

Navigate to the URL printed in `vault_ui_url` (default `https://127.0.0.1:8200/ui`). Your browser will warn about the self-signed CA — import `/opt/armory/vault/tls/ca.crt` into your system or browser trust store to resolve this.

### Trusting the CA on the host

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

## Variable Reference

| Variable | Default | Description |
|---|---|---|
| `deploy_dir` | `/opt/armory/vault` | Host path for all runtime artefacts |
| `node_id` | `vault-node-0` | Raft node identifier |
| `image_registry` | `quay.io/openbao` | Container registry |
| `image_name` | `openbao` | Image name |
| `image_tag` | `2.5.2` | Image version |
| `vault_binary` | `bao` | CLI binary name inside the container |
| `api_addr` | `127.0.0.1` | Advertised API address |
| `api_port` | `8200` | Host port for API/UI |
| `cluster_port` | `8201` | Host port for cluster communication |
| `ui_enabled` | `true` | Enable the web UI |
| `log_level` | `info` | Log verbosity (`trace` `debug` `info` `warn` `error`) |
| `disable_mlock` | `false` | Disable mlock (set `true` if kernel lacks `IPC_LOCK`) |
| `tls_san_dns` | `["localhost", "armory-vault"]` | Additional DNS SANs for the server cert |
| `tls_san_ip` | `[]` | Additional IP SANs for the server cert |
