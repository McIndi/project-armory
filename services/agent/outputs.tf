output "deploy_dir" {
  description = "Root directory of all agent runtime artefacts on the host."
  value       = var.deploy_dir
}

output "approle_dir" {
  description = "Host path containing role_id and wrapped_secret_id. Pass as APPROLE_DIR to the agent process."
  value       = local.dirs.approle
}
