output "nginx_url" {
  description = "HTTPS URL for the webserver."
  value       = "https://${var.host_ip}:${var.host_port}"
}

output "compose_file" {
  description = "Path to the generated Compose file."
  value       = "${var.deploy_dir}/compose.yml"
}

output "deploy_dir" {
  description = "Root directory of all webserver runtime artefacts on the host."
  value       = var.deploy_dir
}
