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

deploy_dir           = "/opt/armory/webserver"
compose_project_name = "armory-webserver"
nginx_container_name = "armory-webserver"
agent_container_name = "armory-vault-agent"

# Optional override. When unset, defaults to ${armory_base_dir}/vault/tls.
# vault_tls_dir      = "/opt/armory/vault/tls"

server_name = "armory-webserver"
cert_ttl    = "720h"

host_ip        = "127.0.0.1"
nginx_host_port = 8000

# Optional: extra IP SANs beyond 127.0.0.1 (always included).
# Useful when nginx must be reachable from a LAN IP.
# cert_ip_sans = ["192.168.1.50"]

# Optional: DNS SANs. The Vault PKI role must allow these names.
# cert_dns_sans = ["nginx.local"]
