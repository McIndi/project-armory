# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

output "vault_addr" {
  description = "Vault API address from the host. Use https://armory-vault:<vault_port> from within the compose network."
  value       = "https://${var.api_addr}:${var.vault_port}"
}

output "vault_ui_url" {
  description = "Web UI URL, accessible from the host browser via the published port binding."
  value       = var.ui_enabled ? "https://${var.api_addr}:${var.vault_port}/ui" : null
}

output "vault_cacert_path" {
  description = "Path to the CA certificate on the host. Set VAULT_CACERT / BAO_CACERT to this value when using the CLI from the host."
  value       = "${var.deploy_dir}/tls/ca.crt"
}

# ---------------------------------------------------------------------------
# Initialisation helper
# ---------------------------------------------------------------------------

output "init_command" {
  description = "Run this command to initialise a brand-new Vault cluster (single unseal key, single key share — adjust -key-shares/-key-threshold for production)."
  value       = "podman exec ${var.container_name} ${var.vault_binary} operator init -key-shares=1 -key-threshold=1"
}

output "unseal_command_example" {
  description = "Template for the unseal command — substitute the unseal key from operator init output."
  value       = "podman exec ${var.container_name} ${var.vault_binary} operator unseal <UNSEAL_KEY>"
}

# ---------------------------------------------------------------------------
# TLS artefacts (sensitive)
# ---------------------------------------------------------------------------

output "ca_cert_pem" {
  description = "PEM-encoded CA certificate. Trust this on any system that needs to verify Vault's TLS certificate."
  value       = tls_self_signed_cert.ca.cert_pem
  sensitive   = true
}

output "server_cert_pem" {
  description = "PEM-encoded server certificate (leaf + CA chain)."
  value       = "${tls_locally_signed_cert.server.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
  sensitive   = true
}

# ---------------------------------------------------------------------------
# PKI helpers
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Deployment metadata
# ---------------------------------------------------------------------------

output "deploy_dir" {
  description = "Root directory of all Vault runtime artefacts on the host."
  value       = var.deploy_dir
}

output "compose_file" {
  description = "Path to the generated Compose file."
  value       = "${var.deploy_dir}/compose.yml"
}

output "image" {
  description = "Full image reference used for this deployment."
  value       = "${var.image_registry}/${var.image_name}:${var.image_tag}"
}
