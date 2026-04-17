# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

variable "deploy_dir" {
  description = "Host path for all PostgreSQL runtime artefacts."
  type        = string
  default     = "/opt/armory/postgres"
}

variable "compose_project_name" {
  description = "Podman Compose project name."
  type        = string
  default     = "armory-postgres"
}

variable "container_name" {
  description = "Name of the PostgreSQL container."
  type        = string
  default     = "armory-postgres"
}

variable "postgres_image" {
  description = "PostgreSQL container image."
  type        = string
  default     = "docker.io/postgres:16-alpine"
}

variable "network_name" {
  description = "Compose network to join. Must be the same network as Vault."
  type        = string
  default     = "armory-net"
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

variable "postgres_password" {
  description = "Password for the PostgreSQL superuser (postgres)."
  type        = string
  sensitive   = true
  default     = "postgres-demo-2026"
}

variable "vault_mgmt_password" {
  description = "Password for the vault_mgmt role used by Vault Database secrets engine."
  type        = string
  sensitive   = true
  default     = "vault-mgmt-demo-2026"
}
