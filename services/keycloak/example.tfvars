# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

armory_base_dir = "/opt/armory"

vault_addr   = "https://127.0.0.1:8200"
# Optional override. When unset, defaults to ${armory_base_dir}/vault/tls/ca.crt.
# vault_cacert = "/opt/armory/vault/tls/ca.crt"

# vault_token must be set via environment variable:
#   export TF_VAR_vault_token=<ROOT_TOKEN>

approle_mount_path = "approle"
pki_ext_mount      = "pki_ext"
pki_ext_role       = "armory-external"

db_static_creds_path = "database/static-creds/keycloak"
kv_admin_path        = "kv/data/keycloak/admin"
keycloak_db_policy   = "keycloak_db"
kv_reader_policy     = "kv_reader_keycloak"

deploy_dir              = "/opt/armory/keycloak"
compose_project_name    = "armory-keycloak"
keycloak_container_name = "armory-keycloak"
agent_container_name    = "armory-vault-agent-keycloak"
# Optional override. When unset, defaults to ${armory_base_dir}/vault/tls.
# vault_tls_dir           = "/opt/armory/vault/tls"

postgres_host = "armory-postgres"
server_name   = "armory-keycloak"
cert_ttl      = "720h"

host_ip       = "127.0.0.1"
keycloak_port = 8443

# Optional: extra IP SANs beyond 127.0.0.1 (always included).
# cert_ip_sans = ["192.168.1.50"]

# Optional: DNS SANs. The Vault PKI role must allow these names.
# cert_dns_sans = ["keycloak.local"]

# ---------------------------------------------------------------------------
# Realm bootstrap — Keycloak first-boot import
# ---------------------------------------------------------------------------
# These values are baked into the realm JSON rendered at deploy time.
# They must match vault-config oidc_client_secret and oidc_client_id.
# Override before any non-demo use.

keycloak_realm          = "armory"
realm_required_group    = "vault-operators"
realm_operator_username = "operator"
# realm_operator_password = "armory-demo-2026"   # set via TF_VAR_realm_operator_password

vault_oidc_client_id = "vault"
# vault_oidc_client_secret = "armory-vault-oidc-secret-2026"  # set via TF_VAR_vault_oidc_client_secret

agent_cli_client_id    = "agent-cli"
agent_cli_redirect_uri = "http://127.0.0.1:18080/callback"
agent_cli_web_origin   = "http://127.0.0.1:18080"

keycloak_oidc_client_id = "wazuh-dashboard"
required_group          = "wazuh-operators"
wazuh_operator_username = "wazuh-operator"
# wazuh_operator_password = "armory-demo-2026"      # set via TF_VAR_wazuh_operator_password
# wazuh_oidc_client_secret = "armory-wazuh-oidc-secret-2026"  # set via TF_VAR_wazuh_oidc_client_secret
# wazuh_auth_proxy_port = 8550

vault_oidc_redirect_uris = [
  "http://localhost:8250/oidc/callback",
  "https://127.0.0.1:8200/oidc/callback",
  "https://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback",
]
