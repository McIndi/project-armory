# ===========================================================================
# Locals
# ===========================================================================

locals {
  dirs = {
    approle = "${var.deploy_dir}/approle"
    logs    = "${var.deploy_dir}/logs"
    data    = "${var.deploy_dir}/data"
  }
}

# ===========================================================================
# AppRole credentials
#
# The AppRole role itself is created in vault-config/auth.tf. This module
# only issues the wrapped secret_id and writes both credentials to disk —
# the same pattern used by services/webserver/ and services/keycloak/.
# ===========================================================================

data "vault_approle_auth_backend_role_id" "agent" {
  backend   = var.approle_mount_path
  role_name = "agent"
}

resource "vault_approle_auth_backend_role_secret_id" "agent" {
  backend      = var.approle_mount_path
  role_name    = "agent"
  wrapping_ttl = "10m"
}

# ===========================================================================
# Host directory scaffolding
# ===========================================================================

resource "null_resource" "create_dirs" {
  triggers = {
    dirs = jsonencode(local.dirs)
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -euo pipefail
      mkdir -p "${local.dirs.approle}" "${local.dirs.logs}" "${local.dirs.data}"
      chmod 700 "${local.dirs.approle}"
      chmod 755 "${local.dirs.logs}" "${local.dirs.data}"
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "D=$(echo '${self.triggers.dirs}' | python3 -c \"import json,sys,os; d=json.load(sys.stdin); print(os.path.dirname(d['approle']))\") && rm -rf \"$D\" 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

# ===========================================================================
# Credential files
# ===========================================================================

resource "local_sensitive_file" "role_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/role_id"
  file_permission = "0444"
  content         = data.vault_approle_auth_backend_role_id.agent.role_id
}

resource "local_sensitive_file" "wrapped_secret_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/wrapped_secret_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role_secret_id.agent.wrapping_token
}
