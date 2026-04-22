# ---------------------------------------------------------------------------
# Vault connection
# ---------------------------------------------------------------------------

variable "vault_addr" {
  description = "Vault API address reachable from the host (used by OpenTofu provider)."
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "vault_agent_addr" {
  description = "Vault API address reachable from inside the agent container (container-to-container)."
  type        = string
  default     = "https://armory-vault:8200"
}

variable "vault_token" {
  description = "Vault token with permissions to create policies and AppRole roles."
  type        = string
  sensitive   = true
}

variable "armory_base_dir" {
  description = "Base host directory for Armory runtime artefacts."
  type        = string
  default     = "/opt/armory"
}

variable "vault_cacert" {
  description = "Path to the Vault TLS CA certificate on the host."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Vault resource references
# ---------------------------------------------------------------------------

variable "approle_mount_path" {
  description = "Mount path for the AppRole auth method."
  type        = string
  default     = "approle"
}

variable "pki_ext_mount" {
  description = "Mount path for the external intermediate CA."
  type        = string
  default     = "pki_ext"
}

variable "pki_ext_role" {
  description = "PKI role name for issuing external certificates."
  type        = string
  default     = "armory-external"
}

variable "db_static_creds_path" {
  description = "Vault path for Keycloak static database credentials."
  type        = string
  default     = "database/static-creds/keycloak"
}

variable "kv_admin_path" {
  description = "Vault KV v2 path for Keycloak admin bootstrap credentials."
  type        = string
  default     = "kv/data/keycloak/admin"
}

variable "keycloak_db_policy" {
  description = "Vault policy name granting access to Keycloak database credentials."
  type        = string
  default     = "keycloak_db"
}

variable "kv_reader_policy" {
  description = "Vault policy name granting read access to Keycloak KV secrets."
  type        = string
  default     = "kv_reader_keycloak"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

variable "deploy_dir" {
  description = "Host path for all Keycloak runtime artefacts."
  type        = string
  default     = "/opt/armory/keycloak"
}

variable "compose_project_name" {
  description = "Podman Compose project name."
  type        = string
  default     = "armory-keycloak"
}

variable "keycloak_container_name" {
  description = "Name of the Keycloak container."
  type        = string
  default     = "armory-keycloak"
}

variable "agent_container_name" {
  description = "Name of the Vault Agent sidecar container."
  type        = string
  default     = "armory-vault-agent-keycloak"
}

variable "keycloak_image" {
  description = "Keycloak container image."
  type        = string
  default     = "quay.io/keycloak/keycloak:24.0"
}

variable "agent_image" {
  description = "Vault Agent container image (same image as OpenBao)."
  type        = string
  default     = "quay.io/openbao/openbao:2.5.2"
}

variable "network_name" {
  description = "Compose network to join. Must be the same network as Vault and PostgreSQL."
  type        = string
  default     = "armory-net"
}

variable "vault_tls_dir" {
  description = "Host path to the Vault TLS directory (contains ca.crt). Bind-mounted read-only into the agent."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# TLS / certificate
# ---------------------------------------------------------------------------

variable "server_name" {
  description = "Common name for the Keycloak TLS certificate."
  type        = string
  default     = "armory-keycloak"
}

variable "cert_ttl" {
  description = "Requested TTL for the Keycloak certificate (Vault PKI format, e.g. 720h)."
  type        = string
  default     = "720h"
}

variable "cert_ip_sans" {
  description = "Extra IP SANs for the certificate beyond 127.0.0.1, which is always included."
  type        = list(string)
  default     = []
}

variable "cert_dns_sans" {
  description = "DNS SANs (alt_names) for the certificate."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Network / database
# ---------------------------------------------------------------------------

variable "postgres_host" {
  description = "PostgreSQL container hostname on armory-net."
  type        = string
  default     = "armory-postgres"
}

variable "host_ip" {
  description = "Host IP to bind the published port."
  type        = string
  default     = "127.0.0.1"
}

variable "keycloak_port" {
  description = "Host port to publish for Keycloak HTTPS. Use >= 1024 for rootless podman."
  type        = number
  default     = 8444
}
