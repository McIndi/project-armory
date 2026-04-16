# Copy to terraform.tfvars and adjust for your environment.
# terraform.tfvars is gitignored — never commit secrets.

# ---------------------------------------------------------------------------
# Common: OpenBao (current standin)
# ---------------------------------------------------------------------------
image_registry = "quay.io/openbao"
image_name     = "openbao"
image_tag      = "2.2.0"
vault_binary   = "bao"

# ---------------------------------------------------------------------------
# Common: HashiCorp Vault (swap when client environments are ready)
# ---------------------------------------------------------------------------
# image_registry = "docker.io/hashicorp"
# image_name     = "vault"
# image_tag      = "1.18.3"
# vault_binary   = "vault"

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------
deploy_dir     = "/opt/armory/vault"
node_id        = "vault-node-0"
container_name = "armory-vault"
api_addr       = "127.0.0.1"   # Change to host IP/hostname for network access
api_port       = 8200
cluster_port   = 8201

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
tls_org       = "Project Armory"
tls_ca_cn     = "Armory Vault CA"
tls_server_cn = "armory-vault"
tls_san_dns   = ["localhost", "armory-vault"]
tls_san_ip    = []

# ---------------------------------------------------------------------------
# Vault behaviour
# ---------------------------------------------------------------------------
ui_enabled    = true
log_level     = "info"
disable_mlock = false   # Set true only if host kernel lacks IPC_LOCK support
