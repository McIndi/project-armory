# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

armory_base_dir = "/opt/armory"

vault_addr   = "https://127.0.0.1:8200"
# Optional override. When unset, defaults to ${armory_base_dir}/vault/tls/ca.crt.
# vault_cacert = "/opt/armory/vault/tls/ca.crt"

# vault_token must be set via environment variable:
#   export TF_VAR_vault_token=<ROOT_TOKEN>

deploy_dir           = "/opt/armory/wazuh"
compose_project_name = "armory-wazuh"

# Host bindings
host_ip               = "127.0.0.1"
wazuh_api_port        = 55000
wazuh_auth_proxy_port = 8550

# Keycloak integration
keycloak_realm          = "armory"
keycloak_oidc_client_id = "wazuh-dashboard"
required_group          = "wazuh-operators"

# Set these via environment variables for real deployments:
#   export TF_VAR_wazuh_oidc_client_secret=<KEYCLOAK_CLIENT_SECRET>
#   export TF_VAR_wazuh_cookie_secret=<32_BYTE_BASE64>

# Sidecar secret path for oauth2-proxy secrets.
# Expected fields:
#   client_secret
#   cookie_secret
oidc_kv_path = "kv/data/wazuh/oidc"
