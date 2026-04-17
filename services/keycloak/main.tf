# ===========================================================================
# Locals
# ===========================================================================

locals {
  dirs = {
    agent_config = "${var.deploy_dir}/agent"
    approle      = "${var.deploy_dir}/approle"
    certs        = "${var.deploy_dir}/certs"
    secrets      = "${var.deploy_dir}/secrets"
  }

  ip_sans_str   = join(",", concat(["127.0.0.1"], var.cert_ip_sans))
  alt_names_str = join(",", var.cert_dns_sans)
}

# ===========================================================================
# Vault policy
# ===========================================================================

resource "vault_policy" "keycloak" {
  name = "keycloak"

  policy = <<-EOT
    path "${var.pki_ext_mount}/issue/${var.pki_ext_role}" {
      capabilities = ["create", "update"]
    }
  EOT
}

# ===========================================================================
# AppRole
# ===========================================================================

resource "vault_approle_auth_backend_role" "keycloak" {
  backend        = var.approle_mount_path
  role_name      = "keycloak"
  token_policies = [vault_policy.keycloak.name, var.keycloak_db_policy, var.kv_reader_policy]
  token_ttl      = 3600
  token_max_ttl  = 7200
}

resource "vault_approle_auth_backend_role_secret_id" "keycloak" {
  backend      = var.approle_mount_path
  role_name    = vault_approle_auth_backend_role.keycloak.role_name
  wrapping_ttl = "24h"
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
      mkdir -p "${local.dirs.agent_config}" "${local.dirs.approle}" "${local.dirs.certs}" "${local.dirs.secrets}"
      chmod 755 "${local.dirs.agent_config}"
      chmod 777 "${local.dirs.approle}" "${local.dirs.certs}" "${local.dirs.secrets}"
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "D=$(echo '${self.triggers.dirs}' | python3 -c \"import json,sys,os; d=json.load(sys.stdin); print(os.path.dirname(d['agent_config']))\") && podman unshare rm -rf \"$D\" 2>/dev/null || rm -rf \"$D\" 2>/dev/null || true"
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
    vault_addr           = var.vault_agent_addr
    approle_mount_path   = var.approle_mount_path
    pki_ext_mount        = var.pki_ext_mount
    pki_ext_role         = var.pki_ext_role
    server_name          = var.server_name
    cert_ttl             = var.cert_ttl
    ip_sans_str          = local.ip_sans_str
    alt_names_str        = local.alt_names_str
    db_static_creds_path = var.db_static_creds_path
    kv_admin_path        = var.kv_admin_path
  })
}

resource "local_sensitive_file" "role_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/role_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role.keycloak.role_id
}

resource "local_sensitive_file" "wrapped_secret_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/wrapped_secret_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role_secret_id.keycloak.wrapping_token
}

resource "local_file" "compose" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name            = var.compose_project_name
    agent_image             = var.agent_image
    agent_container_name    = var.agent_container_name
    keycloak_image          = var.keycloak_image
    keycloak_container_name = var.keycloak_container_name
    host_ip                 = var.host_ip
    keycloak_port           = var.keycloak_port
    network_name            = var.network_name
    agent_config_dir        = local.dirs.agent_config
    approle_dir             = local.dirs.approle
    vault_tls_dir           = var.vault_tls_dir
    certs_dir               = local.dirs.certs
    secrets_dir             = local.dirs.secrets
    postgres_host           = var.postgres_host
  })
}

# ===========================================================================
# Deploy
# ===========================================================================

resource "null_resource" "deploy" {
  depends_on = [
    local_file.agent_config,
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
    command     = "podman compose --project-name ${self.triggers.project_name} -f ${self.triggers.compose_file} down --volumes 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}
