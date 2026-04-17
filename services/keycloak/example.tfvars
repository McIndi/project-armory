# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

vault_addr   = "https://127.0.0.1:8200"
vault_cacert = "/opt/armory/vault/tls/ca.crt"

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
vault_tls_dir           = "/opt/armory/vault/tls"

postgres_host = "armory-postgres"
server_name   = "armory-keycloak"
cert_ttl      = "720h"

host_ip       = "127.0.0.1"
keycloak_port = 8444

# Optional: extra IP SANs beyond 127.0.0.1 (always included).
# cert_ip_sans = ["192.168.1.50"]

# Optional: DNS SANs. The Vault PKI role must allow these names.
# cert_dns_sans = ["keycloak.local"]
