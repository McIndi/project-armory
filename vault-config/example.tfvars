# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

armory_base_dir = "/opt/armory"

vault_addr   = "https://127.0.0.1:8200"
# Optional override. When unset, defaults to ${armory_base_dir}/vault/tls/ca.crt.
# vault_cacert = "/opt/armory/vault/tls/ca.crt"

# Optional: Include the Vault server TLS CA in the ca-bundle.pem for consolidated trust store.
# When set, ca-bundle.pem will include both the Vault server TLS CA and all PKI CAs.
# vault_tls_cacert_path = "/opt/armory/vault/tls/ca.crt"

# vault_token is required — set via TF_VAR_vault_token env var or terraform.tfvars
# vault_token = "hvs...."

# pki_base_url is embedded in certificate AIA and CRL fields.
# Use the compose-network address so services can fetch CRLs.
pki_base_url = "https://armory-vault:8200/v1"

# Leave empty to allow any domain (enforce via ACL policy).
# Set to a comma-separated list to constrain the external role:
# pki_ext_allowed_domains = "example.com,api.example.com"
pki_ext_allowed_domains = ""

# Password for the 'operator' userpass account.
# Override this before any non-demo use. Stored in tfstate — see ADR-012.
# operator_password = "change-me"

# Enable the agent AppRole and policy. Set true when ready to apply services/agent/.
# agent_enabled = false
