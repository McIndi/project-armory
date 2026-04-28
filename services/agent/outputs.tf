output "deploy_dir" {
  description = "Root directory of all agent runtime artefacts on the host."
  value       = var.deploy_dir
}

output "approle_dir" {
  description = "Host path containing role_id and wrapped_secret_id. Pass as APPROLE_DIR to the agent process."
  value       = local.dirs.approle
}

output "agent_api_url" {
  description = "Agent API HTTPS base URL exposed on the host."
  value       = "https://${var.host_ip}:${var.host_port}"
}

output "cert_bundle_path" {
  description = "Host path to the Vault Agent-rendered agent API certificate bundle (cert+chain+key)."
  value       = "${local.dirs.certs}/agent.pem"
}
