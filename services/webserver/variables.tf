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

variable "vault_tls_dir" {
  description = "Host path to the Vault TLS directory (contains ca.crt)."
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

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

variable "deploy_dir" {
  description = "Host path for all webserver runtime artefacts."
  type        = string
  default     = "/opt/armory/webserver"
}

variable "compose_project_name" {
  description = "Podman Compose project name."
  type        = string
  default     = "armory-webserver"
}

variable "nginx_container_name" {
  description = "Name of the nginx container."
  type        = string
  default     = "armory-webserver"
}

variable "agent_container_name" {
  description = "Name of the Vault Agent container."
  type        = string
  default     = "armory-vault-agent"
}

variable "nginx_image" {
  description = "nginx container image."
  type        = string
  default     = "docker.io/nginx:alpine"
}

variable "agent_image" {
  description = "Vault Agent container image (same image as Vault)."
  type        = string
  default     = "quay.io/openbao/openbao:2.5.2"
}

variable "network_name" {
  description = "Compose network to join. Must be the same network as Vault."
  type        = string
  default     = "armory-net"
}

# ---------------------------------------------------------------------------
# TLS / certificate
# ---------------------------------------------------------------------------

variable "server_name" {
  description = "Common name for the nginx TLS certificate and nginx server_name."
  type        = string
  default     = "armory-webserver"
}

variable "cert_ttl" {
  description = "Requested TTL for the nginx certificate (Vault PKI format, e.g. 720h)."
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
# Network
# ---------------------------------------------------------------------------

variable "host_ip" {
  description = "Host IP to bind the published port. Use 0.0.0.0 for external access."
  type        = string
  default     = "127.0.0.1"
}

variable "host_port" {
  description = "Host port to publish for nginx HTTPS. Use >= 1024 for rootless podman."
  type        = number
  default     = 8443
}
