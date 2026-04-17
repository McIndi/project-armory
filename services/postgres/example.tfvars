# Copy to terraform.tfvars and fill in sensitive values.
# terraform.tfvars is gitignored — never commit secrets.

deploy_dir           = "/opt/armory/postgres"
compose_project_name = "armory-postgres"
container_name       = "armory-postgres"
postgres_image       = "docker.io/postgres:16-alpine"
network_name         = "armory-net"

# Passwords — set via environment variables to avoid writing to disk:
#   export TF_VAR_postgres_password=<password>
#   export TF_VAR_vault_mgmt_password=<password>
