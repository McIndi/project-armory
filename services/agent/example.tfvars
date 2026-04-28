# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

armory_base_dir = "/opt/armory"

vault_addr   = "https://127.0.0.1:8200"
# Optional override. When unset, defaults to ${armory_base_dir}/vault/tls/ca.crt.
# vault_cacert = "/opt/armory/vault/tls/ca.crt"

# vault_token must be set via environment variable:
#   export TF_VAR_vault_token=<ROOT_TOKEN>

approle_mount_path = "approle"
deploy_dir         = "/opt/armory/agent"

# Agent API HTTPS endpoint published on the host.
host_ip   = "127.0.0.1"
host_port = 8445
