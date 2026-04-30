output "wazuh_api_url" {
  description = "Direct Wazuh API URL (manager)."
  value       = "https://${var.host_ip}:${var.wazuh_api_port}"
}

output "wazuh_auth_url" {
  description = "Keycloak-protected oauth2-proxy URL for Wazuh access."
  value       = "https://${var.host_ip}:${var.wazuh_auth_proxy_port}"
}

output "compose_file" {
  description = "Path to the generated Compose file."
  value       = "${var.deploy_dir}/compose.yml"
}

output "deploy_dir" {
  description = "Root directory of all Wazuh runtime artefacts on the host."
  value       = var.deploy_dir
}
