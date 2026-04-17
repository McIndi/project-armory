# ---------------------------------------------------------------------------
# Deployment identity
# ---------------------------------------------------------------------------

variable "deploy_dir" {
  description = "Absolute path on the host where all runtime artifacts (config, data, TLS, logs) will be written."
  type        = string
  default     = "/opt/armory/vault"
}

variable "node_id" {
  description = "Raft node identifier. Must be unique per cluster member."
  type        = string
  default     = "vault-node-0"
}

# ---------------------------------------------------------------------------
# Image — swap these to switch between OpenBao and HashiCorp Vault
# ---------------------------------------------------------------------------

variable "image_registry" {
  description = "Container registry hosting the image."
  type        = string
  default     = "quay.io/openbao"
}

variable "image_name" {
  description = "Image name within the registry."
  type        = string
  default     = "openbao"
}

variable "image_tag" {
  description = "Image tag / version to deploy."
  type        = string
  default     = "2.5.2"
}

variable "container_name" {
  description = "Name given to the running container."
  type        = string
  default     = "armory-vault"
}

# When switching to HashiCorp Vault set this to "vault"
variable "vault_binary" {
  description = "Name of the vault binary inside the container (bao for OpenBao, vault for HashiCorp Vault)."
  type        = string
  default     = "bao"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "api_addr" {
  description = "Hostname or IP that Vault advertises as its API address. Use the host's reachable IP/hostname for non-loopback access."
  type        = string
  default     = "127.0.0.1"
}

variable "podman_network_name" {
  description = "Name of the podman network created for this deployment."
  type        = string
  default     = "armory-net"
}

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------

variable "tls_org" {
  description = "Organization name embedded in the generated TLS certificates."
  type        = string
  default     = "Project Armory"
}

variable "tls_validity_hours" {
  description = "Validity period (hours) for the generated CA and server certificates."
  type        = number
  default     = 87600 # 10 years — rotate before production use
}

variable "tls_ca_cn" {
  description = "Common Name for the self-signed CA certificate."
  type        = string
  default     = "Armory Vault CA"
}

variable "tls_server_cn" {
  description = "Common Name for the Vault server certificate."
  type        = string
  default     = "armory-vault"
}

variable "tls_san_dns" {
  description = "Additional DNS SANs for the server cert. localhost and tls_server_cn are always included."
  type        = list(string)
  default     = []
}

variable "tls_san_ip" {
  description = "Additional IP SANs for the server cert (127.0.0.1 is always included)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Vault behaviour
# ---------------------------------------------------------------------------

variable "ui_enabled" {
  description = "Enable the Vault web UI."
  type        = bool
  default     = true
}

variable "log_level" {
  description = "Vault log level: trace, debug, info, warn, error."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["trace", "debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of: trace, debug, info, warn, error."
  }
}

variable "disable_mlock" {
  description = "Disable mlock. Required when the host kernel does not support IPC_LOCK (e.g. some WSL2 configurations). Do not set true in production unless necessary."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Compose / runtime
# ---------------------------------------------------------------------------

variable "compose_project_name" {
  description = "Podman Compose project name (sets label com.docker.compose.project)."
  type        = string
  default     = "armory-vault"
}

variable "restart_policy" {
  description = "Container restart policy."
  type        = string
  default     = "unless-stopped"
}
