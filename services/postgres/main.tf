# ===========================================================================
# Locals
# ===========================================================================

locals {
  pgdata_dir    = "${var.deploy_dir}/pgdata"
  init_sql_path = "${var.deploy_dir}/init.sql"

  dirs = {
    agent_config = "${var.deploy_dir}/agent"
    approle      = "${var.deploy_dir}/approle"
    certs        = "${var.deploy_dir}/certs"
  }

  ip_sans_str   = join(",", concat(["127.0.0.1"], var.cert_ip_sans))
  alt_names_str = join(",", var.cert_dns_sans)
}

# ===========================================================================
# Vault policy
# ===========================================================================

resource "vault_policy" "postgres" {
  name = "postgres"

  policy = <<-EOT
    path "${var.pki_int_mount}/issue/${var.pki_int_role}" {
      capabilities = ["create", "update"]
    }
  EOT
}

# ===========================================================================
# AppRole
# ===========================================================================

resource "vault_approle_auth_backend_role" "postgres" {
  backend        = var.approle_mount_path
  role_name      = "postgres"
  token_policies = [vault_policy.postgres.name]
  token_ttl      = 3600
  token_max_ttl  = 7200
}

resource "vault_approle_auth_backend_role_secret_id" "postgres" {
  backend      = var.approle_mount_path
  role_name    = vault_approle_auth_backend_role.postgres.role_name
  wrapping_ttl = "24h"
}

# ===========================================================================
# Host directory scaffolding
# ===========================================================================

resource "null_resource" "create_dirs" {
  triggers = {
    deploy_dir = var.deploy_dir
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -euo pipefail
      mkdir -p "${local.pgdata_dir}" "${local.dirs.agent_config}" \
               "${local.dirs.approle}" "${local.dirs.certs}"
      chmod 777 "${local.pgdata_dir}"
      chmod 755 "${local.dirs.agent_config}"
      chmod 777 "${local.dirs.approle}" "${local.dirs.certs}"
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "podman unshare rm -rf '${self.triggers.deploy_dir}' 2>/dev/null || rm -rf '${self.triggers.deploy_dir}' 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

# ===========================================================================
# Rendered configuration files
# ===========================================================================

resource "local_file" "agent_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.agent_config}/agent.hcl"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/agent.hcl.tpl", {
    vault_addr         = var.vault_addr
    approle_mount_path = var.approle_mount_path
    pki_int_mount      = var.pki_int_mount
    pki_int_role       = var.pki_int_role
    server_name        = var.server_name
    cert_ttl           = var.cert_ttl
    ip_sans_str        = local.ip_sans_str
    alt_names_str      = local.alt_names_str
  })
}

resource "local_sensitive_file" "role_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/role_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role.postgres.role_id
}

resource "local_sensitive_file" "wrapped_secret_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/wrapped_secret_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role_secret_id.postgres.wrapping_token
}

resource "local_file" "init_sql" {
  depends_on      = [null_resource.create_dirs]
  filename        = local.init_sql_path
  file_permission = "0640"
  content = templatefile("${path.module}/templates/init.sql.tpl", {
    vault_mgmt_password = var.vault_mgmt_password
  })
}

resource "local_file" "compose" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name         = var.compose_project_name
    postgres_image       = var.postgres_image
    container_name       = var.container_name
    postgres_password    = var.postgres_password
    pgdata_dir           = local.pgdata_dir
    init_sql_path        = local.init_sql_path
    network_name         = var.network_name
    agent_image          = var.agent_image
    agent_container_name = var.agent_container_name
    vault_tls_dir        = var.vault_tls_dir
    agent_config_dir     = local.dirs.agent_config
    approle_dir          = local.dirs.approle
    certs_dir            = local.dirs.certs
  })
}

# ===========================================================================
# Deploy
# ===========================================================================

resource "null_resource" "deploy" {
  depends_on = [
    local_file.agent_config,
    local_file.init_sql,
    local_file.compose,
    local_sensitive_file.role_id,
    local_sensitive_file.wrapped_secret_id,
  ]

  triggers = {
    compose_hash = local_file.compose.content
    agent_hash   = local_file.agent_config.content
    compose_file = "${var.deploy_dir}/compose.yml"
    project_name = var.compose_project_name
  }

  provisioner "local-exec" {
    command     = "podman compose --project-name ${var.compose_project_name} -f ${var.deploy_dir}/compose.yml up -d --pull-always"
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "podman compose --project-name ${self.triggers.project_name} -f ${self.triggers.compose_file} down 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}
