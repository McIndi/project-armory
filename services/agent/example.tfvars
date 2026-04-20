# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

vault_addr   = "https://127.0.0.1:8200"
vault_cacert = "/opt/armory/vault/tls/ca.crt"

# vault_token must be set via environment variable:
#   export TF_VAR_vault_token=<ROOT_TOKEN>

approle_mount_path = "approle"
deploy_dir         = "/opt/armory/agent"
