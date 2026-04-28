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

# ---------------------------------------------------------------------------
# Vault connection
# ---------------------------------------------------------------------------

variable "vault_addr" {
  description = "Vault API address reachable from the host."
  type        = string
  default     = "https://127.0.0.1:8200"
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
