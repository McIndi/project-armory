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

variable "vault_tls_cacert_path" {
  description = "Path to the Vault server TLS CA certificate (self-signed, from vault/ module). If provided, this cert will be included in the ca-bundle.pem for simplified trust store management."
  type        = string
  default     = ""
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
  description = "Base URL of the Keycloak server as reachable from the Vault container (e.g. https://armory-keycloak:8443)."
  type        = string
  default     = "https://armory-keycloak:8443"
}

variable "oidc_client_id" {
  description = "OIDC client ID registered in the Keycloak 'armory' realm."
  type        = string
  default     = "vault"
}

variable "oidc_client_secret" {
  description = "OIDC client secret from the Keycloak 'vault' client. Must match vault_oidc_client_secret in services/keycloak."
  type        = string
  sensitive   = true
  default     = "armory-vault-oidc-secret-2026"
}

variable "oidc_redirect_uris" {
  description = "Allowed redirect URIs for the Vault OIDC role (CLI and UI callbacks). Must match Keycloak vault client."
  type        = list(string)
  default = [
    "http://localhost:8250/oidc/callback",
    "https://127.0.0.1:8200/oidc/callback",
    "https://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback",
  ]
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
