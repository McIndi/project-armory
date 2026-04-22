output "pki_root_mount" {
  description = "Mount path for the root CA. Used only for signing intermediates — no leaf cert role is defined here."
  value       = vault_mount.pki_root.path
}

output "approle_mount_path" {
  description = "Mount path for the AppRole auth method. Pass to service modules as var.approle_mount_path."
  value       = vault_auth_backend.approle.path
}

output "pki_int_mount" {
  description = "Mount path for the internal intermediate CA (*.armory.internal)."
  value       = vault_mount.pki_int.path
}

output "pki_ext_mount" {
  description = "Mount path for the external intermediate CA."
  value       = vault_mount.pki_ext.path
}

output "ca_bundle_path" {
  description = "Path to the CA bundle on the host. Import into OS or browser trust store."
  value       = local_file.ca_bundle.filename
}

output "audit_log_path" {
  description = "Path to the audit log on the host (bind-mounted from /vault/logs inside the container)."
  value       = "${var.armory_base_dir}/vault/logs/audit.log"
}

output "operator_login_command" {
  description = "Command to authenticate as the operator user (userpass method, while enabled)."
  value       = var.userpass_enabled ? "podman exec armory-vault bao login -method=userpass -format=json username=operator | python3 -c \"import sys,json; print(json.load(sys.stdin)['auth']['client_token'])\"" : "userpass disabled — use: bao login -method=oidc role=operator"
}

output "oidc_login_command" {
  description = "Command to authenticate via OIDC (requires Keycloak running and oidc_enabled=true)."
  value       = "bao login -method=oidc role=operator"
}
