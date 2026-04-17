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
