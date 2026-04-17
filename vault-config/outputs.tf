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
