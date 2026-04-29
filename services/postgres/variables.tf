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

variable "postgres_port" {
  description = "Host port published for PostgreSQL. Set via TF_VAR_postgres_port in armory.env."
  type        = number
  default     = 5432
}

variable "keycloak_db_username" {
  description = "PostgreSQL login role for Keycloak, managed by Vault's database static role. Must match vault-config keycloak_db_username. Set via TF_VAR_keycloak_db_username in armory.env."
  type        = string
  default     = "keycloak"
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

variable "postgres_username" {
  description = "PostgreSQL superuser name (POSTGRES_USER). Set via TF_VAR_postgres_username in armory.env."
  type        = string
  default     = "postgres"
}

variable "postgres_password" {
  description = "Password for the PostgreSQL superuser. Set via TF_VAR_postgres_password in armory.env."
  type        = string
  sensitive   = true
}

variable "vault_mgmt_username" {
  description = "PostgreSQL role used by Vault's database secrets engine. Must match vault-config vault_mgmt_username. Set via TF_VAR_vault_mgmt_username in armory.env."
  type        = string
  default     = "vault_mgmt"
}

variable "vault_mgmt_password" {
  description = "Password for the vault_mgmt role used by Vault Database secrets engine. Must match vault-config vault_mgmt_password. Set via TF_VAR_vault_mgmt_password in armory.env."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Vault connection
# ---------------------------------------------------------------------------

variable "vault_addr" {
  description = "Vault API address reachable from the host."
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "vault_agent_addr" {
  description = "Vault API address reachable from inside the agent container (container-to-container on armory-net)."
  type        = string
  default     = "https://armory-vault:8200"
}

variable "vault_token" {
  description = "Vault token for Terraform apply (root or privileged)."
  type        = string
  sensitive   = true
}

variable "armory_base_dir" {
  description = "Base host directory for Armory runtime artefacts."
  type        = string
  default     = "/opt/armory"
}

variable "vault_cacert" {
  description = "Path to Vault TLS CA certificate on the host."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Vault Agent / PKI
# ---------------------------------------------------------------------------

variable "approle_mount_path" {
  description = "Mount path of the AppRole auth method."
  type        = string
  default     = "approle"
}

variable "pki_int_mount" {
  description = "Mount path of the internal PKI secrets engine."
  type        = string
  default     = "pki_int"
}

variable "pki_int_role" {
  description = "PKI role name for issuing internal service certificates."
  type        = string
  default     = "armory-server"
}

variable "server_name" {
  description = "Common name for the PostgreSQL TLS certificate (must be armory.internal or a subdomain)."
  type        = string
  default     = "armory-postgres.armory.internal"
}

variable "cert_ttl" {
  description = "Requested TTL for the TLS certificate."
  type        = string
  default     = "24h"
}

variable "cert_ip_sans" {
  description = "Additional IP SANs beyond 127.0.0.1."
  type        = list(string)
  default     = []
}

variable "cert_dns_sans" {
  description = "Additional DNS SANs."
  type        = list(string)
  default     = []
}

variable "agent_image" {
  description = "Vault Agent (OpenBao) container image."
  type        = string
  default     = "quay.io/openbao/openbao:2.5.2"
}

variable "agent_container_name" {
  description = "Container name for the Vault Agent sidecar."
  type        = string
  default     = "armory-postgres-vault-agent"
}

variable "vault_tls_dir" {
  description = "Host path containing the Vault CA certificate."
  type        = string
  default     = null
}
