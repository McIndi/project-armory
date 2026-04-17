# Copy to terraform.tfvars and fill in vault_token.
# terraform.tfvars is gitignored — never commit secrets.

vault_addr   = "https://127.0.0.1:8200"
vault_cacert = "/opt/armory/vault/tls/ca.crt"

# vault_token must be set via environment variable:
#   export TF_VAR_vault_token=<ROOT_TOKEN>

approle_mount_path = "approle"
pki_ext_mount      = "pki_ext"
pki_ext_role       = "armory-external"

deploy_dir           = "/opt/armory/webserver"
compose_project_name = "armory-webserver"
nginx_container_name = "armory-webserver"
agent_container_name = "armory-vault-agent"

server_name = "armory-webserver"
cert_ttl    = "720h"

host_ip   = "127.0.0.1"
host_port = 8443
