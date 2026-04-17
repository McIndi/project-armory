output "keycloak_url" {
  description = "HTTPS URL for the Keycloak admin console."
  value       = "https://${var.host_ip}:${var.keycloak_port}"
}

output "compose_file" {
  description = "Path to the generated Compose file."
  value       = "${var.deploy_dir}/compose.yml"
}

output "deploy_dir" {
  description = "Root directory of all Keycloak runtime artefacts on the host."
  value       = var.deploy_dir
}
