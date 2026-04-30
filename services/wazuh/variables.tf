# ---------------------------------------------------------------------------
# Vault connection
# ---------------------------------------------------------------------------

variable "vault_addr" {
  description = "Vault API address reachable from the host (used by OpenTofu provider)."
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "vault_agent_addr" {
  description = "Vault API address reachable from inside the sidecar containers (container-to-container)."
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

variable "oidc_kv_path" {
  description = "KV v2 path containing oauth2-proxy secret values (client_secret and cookie_secret)."
  type        = string
  default     = "kv/data/wazuh/oidc"
}

variable "wazuh_oidc_client_secret" {
  description = "Client secret for the Wazuh oauth2-proxy Keycloak client. Seeded into Vault KV for the Wazuh Vault Agent sidecar. Set via TF_VAR_wazuh_oidc_client_secret in armory.env."
  type        = string
  sensitive   = true
}

variable "wazuh_cookie_secret" {
  description = "Cookie secret for oauth2-proxy. Must be a 16, 24, or 32 byte base64-encoded value. Seeded into Vault KV for the Wazuh Vault Agent sidecar. Set via TF_VAR_wazuh_cookie_secret in armory.env."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

variable "deploy_dir" {
  description = "Host path for all Wazuh runtime artefacts."
  type        = string
  default     = "/opt/armory/wazuh"
}

variable "compose_project_name" {
  description = "Podman Compose project name."
  type        = string
  default     = "armory-wazuh"
}

variable "manager_container_name" {
  description = "Name of the Wazuh manager container."
  type        = string
  default     = "armory-wazuh-manager"
}

variable "vault_agent_container_name" {
  description = "Name of the Vault Agent sidecar container for Wazuh."
  type        = string
  default     = "armory-vault-agent-wazuh"
}

variable "observer_container_name" {
  description = "Name of the observer sidecar that emits JSON health/perf telemetry."
  type        = string
  default     = "armory-wazuh-observer"
}

variable "auth_proxy_container_name" {
  description = "Name of the oauth2-proxy container in front of Wazuh API."
  type        = string
  default     = "armory-wazuh-auth-proxy"
}

variable "manager_image" {
  description = "Wazuh manager container image."
  type        = string
  default     = "docker.io/wazuh/wazuh-manager:4.8.2"
}

variable "agent_image" {
  description = "Vault Agent container image (same image as OpenBao)."
  type        = string
  default     = "quay.io/openbao/openbao:2.5.2"
}

variable "observer_image" {
  description = "Observer sidecar image."
  type        = string
  default     = "docker.io/python:3.12-slim"
}

variable "auth_proxy_image" {
  description = "oauth2-proxy container image."
  type        = string
  default     = "quay.io/oauth2-proxy/oauth2-proxy:v7.8.1"
}

variable "network_name" {
  description = "Compose network to join. Must be the same network as Vault/Keycloak/PostgreSQL."
  type        = string
  default     = "armory-net"
}

variable "host_ip" {
  description = "Host IP to bind published ports."
  type        = string
  default     = "127.0.0.1"
}

variable "wazuh_api_port" {
  description = "Host port to publish for Wazuh manager API HTTPS."
  type        = number
  default     = 55000
}

variable "wazuh_auth_proxy_port" {
  description = "Host port to publish for Keycloak-protected oauth2-proxy endpoint."
  type        = number
  default     = 8550
}

variable "wazuh_events_port" {
  description = "Host port for Wazuh agent event ingestion (TCP/UDP)."
  type        = number
  default     = 1514
}

variable "wazuh_enrollment_port" {
  description = "Host port for Wazuh agent enrollment."
  type        = number
  default     = 1515
}

# ---------------------------------------------------------------------------
# TLS / certificate
# ---------------------------------------------------------------------------

variable "server_name" {
  description = "Common name for the oauth2-proxy TLS certificate."
  type        = string
  default     = "armory-wazuh"
}

variable "cert_ttl" {
  description = "Requested TTL for the oauth2-proxy certificate (Vault PKI format, e.g. 720h)."
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
# Keycloak integration
# ---------------------------------------------------------------------------

variable "keycloak_url" {
  description = "Keycloak URL reachable from the auth proxy container."
  type        = string
  default     = "https://armory-keycloak:8443"
}

variable "keycloak_realm" {
  description = "Keycloak realm used for Wazuh login."
  type        = string
  default     = "armory"
}

variable "keycloak_oidc_client_id" {
  description = "OIDC client ID for oauth2-proxy (confidential client recommended)."
  type        = string
  default     = "wazuh-dashboard"
}

variable "required_group" {
  description = "Group required to access Wazuh through oauth2-proxy."
  type        = string
  default     = "wazuh-operators"
}

# ---------------------------------------------------------------------------
# Observability targets
# ---------------------------------------------------------------------------

variable "vault_health_url" {
  description = "Vault health endpoint (reachable from armory-net)."
  type        = string
  default     = "https://armory-vault:8200/v1/sys/health"
}

variable "keycloak_health_url" {
  description = "Keycloak readiness endpoint (reachable from armory-net)."
  type        = string
  default     = "https://armory-keycloak:8443/health/ready"
}

variable "postgres_host" {
  description = "PostgreSQL hostname on armory-net."
  type        = string
  default     = "armory-postgres"
}

variable "postgres_port" {
  description = "PostgreSQL port on armory-net."
  type        = number
  default     = 5432
}

variable "observer_interval_seconds" {
  description = "Interval between observer checks in seconds."
  type        = number
  default     = 15
}

variable "vault_audit_log_path" {
  description = "Host path to Vault audit JSON log file."
  type        = string
  default     = "/opt/armory/vault/logs/audit.log"
}
