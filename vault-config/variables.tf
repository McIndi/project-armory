# ---------------------------------------------------------------------------
# Vault connection
# ---------------------------------------------------------------------------

variable "vault_addr" {
  description = "Vault API address reachable from the host. Defaults to the localhost-only binding."
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "vault_token" {
  description = "Vault token with permissions to configure PKI and auth methods (root token for initial setup)."
  type        = string
  sensitive   = true
}

variable "vault_cacert" {
  description = "Path to the Vault TLS CA certificate on the host."
  type        = string
  default     = "/opt/armory/vault/tls/ca.crt"
}

# ---------------------------------------------------------------------------
# PKI
# ---------------------------------------------------------------------------

variable "pki_base_url" {
  description = "Base URL embedded in certificate AIA and CRL distribution point fields. Must be reachable by certificate consumers. Defaults to the compose-network address so services can fetch CRLs."
  type        = string
  default     = "https://armory-vault:8200/v1"
}

variable "pki_ext_allowed_domains" {
  description = "Comma-separated list of domains the external PKI role may issue for. Leave empty to allow any name (enforce constraints via ACL policy instead)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Human operator credentials
# ---------------------------------------------------------------------------

variable "operator_password" {
  description = "Password for the 'operator' userpass account. Override before any non-demo use."
  type        = string
  sensitive   = true
  default     = "armory-demo-2026"
}

# ---------------------------------------------------------------------------
# Database secrets engine
# ---------------------------------------------------------------------------

variable "postgres_host" {
  description = "PostgreSQL container hostname on armory-net. Must match services/postgres container_name."
  type        = string
  default     = "armory-postgres"
}

variable "vault_mgmt_password" {
  description = "Password for the vault_mgmt PostgreSQL role. Must match services/postgres vault_mgmt_password."
  type        = string
  sensitive   = true
  default     = "vault-mgmt-demo-2026"
}

variable "database_roles_enabled" {
  description = "Create database roles (static + dynamic). Set true only after services/postgres/ is applied and healthy."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Keycloak
# ---------------------------------------------------------------------------

variable "keycloak_admin_password" {
  description = "Bootstrap password for the Keycloak admin account, stored in KV v2."
  type        = string
  sensitive   = true
  default     = "armory-demo-2026"
}

# ---------------------------------------------------------------------------
# OIDC auth method
# ---------------------------------------------------------------------------

variable "oidc_enabled" {
  description = "Enable the OIDC auth method backed by Keycloak. Set to true only after Keycloak is running."
  type        = bool
  default     = false
}

variable "keycloak_url" {
  description = "Base URL of the Keycloak server, reachable from the host (e.g. https://127.0.0.1:8444)."
  type        = string
  default     = "https://127.0.0.1:8444"
}

variable "oidc_client_id" {
  description = "OIDC client ID registered in the Keycloak 'armory' realm."
  type        = string
  default     = "vault"
}

variable "oidc_client_secret" {
  description = "OIDC client secret from the Keycloak 'vault' client."
  type        = string
  sensitive   = true
  default     = ""
}

variable "userpass_enabled" {
  description = "Keep userpass auth method active. Set to false only after OIDC login is verified working."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Agentic layer
# ---------------------------------------------------------------------------

variable "agent_enabled" {
  description = "Create the agent AppRole and policy. Set true only after services/agent/ is ready to be applied."
  type        = bool
  default     = false
}
