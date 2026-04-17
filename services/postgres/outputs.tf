output "deploy_dir" {
  description = "Root directory of all PostgreSQL runtime artefacts on the host."
  value       = var.deploy_dir
}

output "postgres_host" {
  description = "Container hostname on armory-net (use in vault-config/ database connection)."
  value       = var.container_name
}

output "compose_file" {
  description = "Path to the generated Compose file."
  value       = "${var.deploy_dir}/compose.yml"
}
