# ---------------------------------------------------------------------------
# Vault connection
# ---------------------------------------------------------------------------

variable "vault_addr" {
  description = "Vault API address reachable from the host (used by OpenTofu provider)."
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "vault_token" {
  description = "Vault token with permissions to create AppRole secret IDs."
  type        = string
  sensitive   = true
}

variable "vault_cacert" {
  description = "Path to the Vault TLS CA certificate on the host."
  type        = string
  default     = "/opt/armory/vault/tls/ca.crt"
}

# ---------------------------------------------------------------------------
# Vault resource references
# ---------------------------------------------------------------------------

variable "approle_mount_path" {
  description = "Mount path for the AppRole auth method."
  type        = string
  default     = "approle"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

variable "deploy_dir" {
  description = "Host path for all agent runtime artefacts (approle credentials, logs, data)."
  type        = string
  default     = "/opt/armory/agent"
}
