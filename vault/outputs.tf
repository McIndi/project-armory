# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

output "vault_addr" {
  description = "VAULT_ADDR / BAO_ADDR value to use from the host."
  value       = "https://${var.api_addr}:${var.api_port}"
}

output "vault_ui_url" {
  description = "URL for the Vault web UI (if ui_enabled = true)."
  value       = var.ui_enabled ? "https://${var.api_addr}:${var.api_port}/ui" : null
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
  value = join(" \\\n  ", [
    "VAULT_ADDR=https://${var.api_addr}:${var.api_port}",
    "VAULT_CACERT=${var.deploy_dir}/tls/ca.crt",
    "${var.vault_binary} operator init",
    "-key-shares=1",
    "-key-threshold=1",
  ])
}

output "unseal_command_example" {
  description = "Template for the unseal command — substitute the unseal key from operator init output."
  value = join(" \\\n  ", [
    "VAULT_ADDR=https://${var.api_addr}:${var.api_port}",
    "VAULT_CACERT=${var.deploy_dir}/tls/ca.crt",
    "${var.vault_binary} operator unseal <UNSEAL_KEY>",
  ])
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
