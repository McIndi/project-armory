# ===========================================================================
# Locals
# ===========================================================================

locals {
  dirs = {
    agent_config = "${var.deploy_dir}/agent"
    approle      = "${var.deploy_dir}/approle"
    certs        = "${var.deploy_dir}/certs"
    logs         = "${var.deploy_dir}/logs"
    data         = "${var.deploy_dir}/data"
  }

  vault_tls_dir   = coalesce(var.vault_tls_dir, "${var.armory_base_dir}/vault/tls")
  ca_bundle_file  = abspath("${path.module}/../../vault/ca-bundle.pem")
  api_source_dir  = abspath("${path.module}/agent")
  ip_sans_str     = join(",", concat(["127.0.0.1"], var.cert_ip_sans))
  alt_names_str   = join(",", var.cert_dns_sans)
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
  wrapping_ttl = "24h"
}

resource "vault_approle_auth_backend_role_secret_id" "agent_tls" {
  backend      = var.approle_mount_path
  role_name    = "agent"
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
      mkdir -p "${local.dirs.agent_config}" "${local.dirs.approle}" "${local.dirs.certs}" "${local.dirs.logs}" "${local.dirs.data}"
      chmod 755 "${local.dirs.agent_config}"
      chmod 777 "${local.dirs.approle}"
      chmod 777 "${local.dirs.certs}"
      chmod 755 "${local.dirs.logs}" "${local.dirs.data}"
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "D=$(echo '${self.triggers.dirs}' | python3 -c \"import json,sys,os; d=json.load(sys.stdin); print(os.path.dirname(d['approle']))\") && podman unshare rm -rf \"$D\" 2>/dev/null || rm -rf \"$D\" 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

resource "local_file" "agent_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.agent_config}/agent.hcl"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/agent.hcl.tpl", {
    vault_addr         = var.vault_agent_addr
    approle_mount_path = var.approle_mount_path
    pki_ext_mount      = var.pki_ext_mount
    pki_ext_role       = var.pki_ext_role
    server_name        = var.server_name
    cert_ttl           = var.cert_ttl
    ip_sans_str        = local.ip_sans_str
    alt_names_str      = local.alt_names_str
  })
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

resource "local_sensitive_file" "role_id_tls" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/role_id_tls"
  file_permission = "0444"
  content         = data.vault_approle_auth_backend_role_id.agent.role_id
}

resource "local_sensitive_file" "wrapped_secret_id_tls" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/wrapped_secret_id_tls"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role_secret_id.agent_tls.wrapping_token
}

resource "local_file" "compose" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name         = var.compose_project_name
    api_image            = var.api_image
    api_container_name   = var.api_container_name
    agent_image          = var.agent_image
    agent_container_name = var.agent_container_name
    vault_agent_addr     = var.vault_agent_addr
    host_ip              = var.host_ip
    host_port            = var.agent_host_port
    api_port             = var.api_port
    network_name         = var.network_name
    agent_config_dir     = local.dirs.agent_config
    approle_dir          = local.dirs.approle
    certs_dir            = local.dirs.certs
    vault_tls_dir        = local.vault_tls_dir
    ca_bundle_file       = local.ca_bundle_file
    api_source_dir       = local.api_source_dir
    keycloak_url         = var.keycloak_url
    oidc_client_id       = var.oidc_client_id
    postgres_host        = var.postgres_host
    postgres_db          = var.postgres_db
  })
}

resource "null_resource" "deploy" {
  depends_on = [
    local_file.agent_config,
    local_file.compose,
    local_sensitive_file.role_id,
    local_sensitive_file.wrapped_secret_id,
    local_sensitive_file.role_id_tls,
    local_sensitive_file.wrapped_secret_id_tls,
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
