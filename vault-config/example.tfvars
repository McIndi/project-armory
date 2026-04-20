# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

vault_addr   = "https://127.0.0.1:8200"
vault_cacert = "/opt/armory/vault/tls/ca.crt"

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
