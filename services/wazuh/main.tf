# ===========================================================================
# Locals
# ===========================================================================

locals {
  dirs = {
    agent_config = "${var.deploy_dir}/agent"
    approle      = "${var.deploy_dir}/approle"
    certs        = "${var.deploy_dir}/certs"
    secrets      = "${var.deploy_dir}/secrets"
    observer     = "${var.deploy_dir}/observer"
    config       = "${var.deploy_dir}/config"
  }

  vault_tls_dir = coalesce(var.vault_tls_dir, "${var.armory_base_dir}/vault/tls")
  ca_bundle_file = abspath("${path.module}/../../vault/ca-bundle.pem")
  ip_sans_str   = join(",", concat(["127.0.0.1"], var.cert_ip_sans))
  alt_names_str = join(",", var.cert_dns_sans)
}

# ===========================================================================
# Vault policy + AppRole
# ===========================================================================

resource "vault_policy" "wazuh" {
  name = "wazuh"

  policy = <<-EOT
    path "${var.pki_ext_mount}/issue/${var.pki_ext_role}" {
      capabilities = ["create", "update"]
    }

    path "kv/metadata/wazuh/*" {
      capabilities = ["read", "list"]
    }

    path "kv/data/wazuh/*" {
      capabilities = ["read"]
    }

    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }

    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    path "auth/token/revoke-self" {
      capabilities = ["update"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "wazuh" {
  backend        = var.approle_mount_path
  role_name      = "wazuh"
  token_policies = [vault_policy.wazuh.name]
  token_ttl      = 3600
  token_max_ttl  = 7200
}

resource "vault_approle_auth_backend_role_secret_id" "wazuh" {
  backend      = var.approle_mount_path
  role_name    = vault_approle_auth_backend_role.wazuh.role_name
  wrapping_ttl = "24h"
}

resource "vault_kv_secret_v2" "wazuh_oidc" {
  mount = split("/", trimprefix(var.oidc_kv_path, "/"))[0]
  name  = join("/", slice(split("/", trimprefix(var.oidc_kv_path, "/")), 2, length(split("/", trimprefix(var.oidc_kv_path, "/")))))

  data_json = jsonencode({
    client_secret = var.wazuh_oidc_client_secret
    cookie_secret = var.wazuh_cookie_secret
  })
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
      mkdir -p "${local.dirs.agent_config}" "${local.dirs.approle}" "${local.dirs.certs}" "${local.dirs.secrets}" "${local.dirs.observer}" "${local.dirs.config}"
      chmod 755 "${local.dirs.agent_config}" "${local.dirs.observer}" "${local.dirs.config}"
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
    vault_addr         = var.vault_agent_addr
    approle_mount_path = var.approle_mount_path
    pki_ext_mount      = var.pki_ext_mount
    pki_ext_role       = var.pki_ext_role
    server_name        = var.server_name
    cert_ttl           = var.cert_ttl
    ip_sans_str        = local.ip_sans_str
    alt_names_str      = local.alt_names_str
    oidc_kv_path       = var.oidc_kv_path
  })
}

resource "local_sensitive_file" "role_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/role_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role.wazuh.role_id
}

resource "local_sensitive_file" "wrapped_secret_id" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.approle}/wrapped_secret_id"
  file_permission = "0444"
  content         = vault_approle_auth_backend_role_secret_id.wazuh.wrapping_token
}

resource "local_file" "observer_script" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.observer}/observer.py"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/observer.py.tpl", {
    vault_health_url          = var.vault_health_url
    keycloak_health_url       = var.keycloak_health_url
    postgres_host             = var.postgres_host
    postgres_port             = var.postgres_port
    observer_interval_seconds = var.observer_interval_seconds
  })
}

resource "local_file" "observer_log_placeholder" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.observer}/armory-observer.log"
  file_permission = "0666"
  content         = ""
}

# Bootstrap env file must exist with values before podman compose up.
# podman-compose reads env_file during container creation, so an empty file
# would create auth-proxy without required client/cookie secrets.
resource "local_sensitive_file" "oidc_env_bootstrap" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.secrets}/oidc.env"
  file_permission = "0666"
  content         = <<-EOT
    OAUTH2_PROXY_CLIENT_SECRET=${var.wazuh_oidc_client_secret}
    OAUTH2_PROXY_COOKIE_SECRET=${var.wazuh_cookie_secret}
  EOT
}

resource "local_file" "ossec_local_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/ossec.local.conf"
  file_permission = "0644"
  content         = file("${path.module}/templates/ossec.local.conf")
}

resource "local_file" "compose" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name               = var.compose_project_name
    manager_image              = var.manager_image
    manager_container_name     = var.manager_container_name
    agent_image                = var.agent_image
    vault_agent_container_name = var.vault_agent_container_name
    observer_image             = var.observer_image
    observer_container_name    = var.observer_container_name
    auth_proxy_image           = var.auth_proxy_image
    auth_proxy_container_name  = var.auth_proxy_container_name
    vault_agent_addr           = var.vault_agent_addr
    keycloak_url               = var.keycloak_url
    keycloak_realm             = var.keycloak_realm
    keycloak_oidc_client_id    = var.keycloak_oidc_client_id
    required_group             = var.required_group
    host_ip                    = var.host_ip
    wazuh_api_port             = var.wazuh_api_port
    wazuh_auth_proxy_port      = var.wazuh_auth_proxy_port
    wazuh_events_port          = var.wazuh_events_port
    wazuh_enrollment_port      = var.wazuh_enrollment_port
    network_name               = var.network_name
    agent_config_dir           = local.dirs.agent_config
    approle_dir                = local.dirs.approle
    vault_tls_dir              = local.vault_tls_dir
    ca_bundle_file             = local.ca_bundle_file
    certs_dir                  = local.dirs.certs
    secrets_dir                = local.dirs.secrets
    observer_dir               = local.dirs.observer
    ossec_local_config_file    = local_file.ossec_local_config.filename
    vault_audit_log_path       = var.vault_audit_log_path
  })
}

# ===========================================================================
# Deploy
# ===========================================================================

resource "null_resource" "deploy" {
  depends_on = [
    local_file.agent_config,
    local_file.compose,
    local_file.observer_script,
    local_file.observer_log_placeholder,
    local_sensitive_file.oidc_env_bootstrap,
    local_file.ossec_local_config,
    local_sensitive_file.role_id,
    local_sensitive_file.wrapped_secret_id,
    vault_kv_secret_v2.wazuh_oidc,
  ]

  triggers = {
    compose_hash = local_file.compose.content
    agent_hash   = local_file.agent_config.content
    observer     = local_file.observer_script.content
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
