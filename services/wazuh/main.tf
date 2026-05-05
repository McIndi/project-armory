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
    indexer_data = "${var.deploy_dir}/indexer-data"
    wazuh_logs   = "${var.deploy_dir}/wazuh-logs"
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

    path "${var.pki_int_mount}/issue/${var.pki_int_role}" {
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
      mkdir -p "${local.dirs.agent_config}" "${local.dirs.approle}" "${local.dirs.certs}" "${local.dirs.secrets}" "${local.dirs.observer}" "${local.dirs.config}" "${local.dirs.indexer_data}" "${local.dirs.wazuh_logs}"
      mkdir -p "${local.dirs.wazuh_logs}/archives" "${local.dirs.wazuh_logs}/alerts" "${local.dirs.wazuh_logs}/firewall"
      chmod 755 "${local.dirs.agent_config}" "${local.dirs.observer}" "${local.dirs.config}" "${local.dirs.indexer_data}"
      chmod 777 "${local.dirs.approle}" "${local.dirs.certs}" "${local.dirs.secrets}" "${local.dirs.wazuh_logs}"
      chmod 777 "${local.dirs.wazuh_logs}/archives" "${local.dirs.wazuh_logs}/alerts" "${local.dirs.wazuh_logs}/firewall"
      # pre-create armory-observer.log as a file so Podman bind-mount doesn't make it a dir
      touch "${local.dirs.wazuh_logs}/armory-observer.log"
      # wazuh-indexer container runs as uid 1000 inside the rootless Podman user
      # namespace — use podman unshare so the chown maps to the correct host UID.
      podman unshare chown 1000:1000 "${local.dirs.indexer_data}"
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
    vault_addr             = var.vault_agent_addr
    approle_mount_path     = var.approle_mount_path
    pki_ext_mount          = var.pki_ext_mount
    pki_ext_role           = var.pki_ext_role
    pki_int_mount          = var.pki_int_mount
    pki_int_role           = var.pki_int_role
    indexer_container_name = var.indexer_container_name
    dashboard_container_name = var.dashboard_container_name
    server_name            = var.server_name
    cert_ttl               = var.cert_ttl
    ip_sans_str            = local.ip_sans_str
    alt_names_str          = local.alt_names_str
    oidc_kv_path           = var.oidc_kv_path
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

resource "local_file" "ossec_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/ossec.conf"
  file_permission = "0644"
  content         = file("${path.module}/templates/ossec.conf")
}

resource "local_file" "opensearch_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/opensearch.yml"
  file_permission = "0644"
  content         = file("${path.module}/templates/opensearch.yml.tpl")
}

resource "local_file" "dashboard_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/opensearch_dashboards.yml"
  file_permission = "0644"
  content         = file("${path.module}/templates/opensearch_dashboards.yml.tpl")
}

resource "local_file" "security_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/opensearch_security_config.yml"
  file_permission = "0644"
  content         = file("${path.module}/templates/opensearch_security_config.yml.tpl")
}

resource "local_file" "compose" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name               = var.compose_project_name
    manager_image              = var.manager_image
    manager_container_name     = var.manager_container_name
    indexer_image              = var.indexer_image
    indexer_container_name     = var.indexer_container_name
    indexer_java_opts          = var.indexer_java_opts
    agent_image                = var.agent_image
    vault_agent_container_name = var.vault_agent_container_name
    observer_image             = var.observer_image
    observer_container_name    = var.observer_container_name
    auth_proxy_image           = var.auth_proxy_image
    auth_proxy_container_name  = var.auth_proxy_container_name
    dashboard_image            = var.dashboard_image
    dashboard_container_name   = var.dashboard_container_name
    vault_agent_addr           = var.vault_agent_addr
    keycloak_oidc_issuer_base_url = var.keycloak_oidc_issuer_base_url
    keycloak_realm             = var.keycloak_realm
    keycloak_oidc_client_id    = var.keycloak_oidc_client_id
    required_group             = var.required_group
    wazuh_indexer_username     = var.wazuh_indexer_username
    wazuh_indexer_password     = var.wazuh_indexer_password
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
    wazuh_logs_dir             = local.dirs.wazuh_logs
    indexer_data_dir           = local.dirs.indexer_data
    ossec_config_file          = local_file.ossec_config.filename
    ossec_local_config_file    = local_file.ossec_local_config.filename
    opensearch_yml_file        = local_file.opensearch_config.filename
    opensearch_dashboards_yml_file = local_file.dashboard_config.filename
    opensearch_security_config_file = local_file.security_config.filename
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
    local_file.ossec_config,
    local_file.ossec_local_config,
    local_file.opensearch_config,
    local_file.dashboard_config,
    local_file.security_config,
    local_sensitive_file.role_id,
    local_sensitive_file.wrapped_secret_id,
    vault_kv_secret_v2.wazuh_oidc,
  ]

  triggers = {
    compose_hash  = local_file.compose.content
    agent_hash    = local_file.agent_config.content
    observer      = local_file.observer_script.content
    ossec_conf    = local_file.ossec_config.content
    ossec_local   = local_file.ossec_local_config.content
    compose_file  = "${var.deploy_dir}/compose.yml"
    project_name  = var.compose_project_name
  }

  provisioner "local-exec" {
    command     = "podman compose --project-name ${var.compose_project_name} -f ${var.deploy_dir}/compose.yml up -d"
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -euo pipefail

      for _ in $(seq 1 24); do
        if podman exec ${var.indexer_container_name} test -f /usr/share/wazuh-indexer/opensearch-security/config.yml; then
          if podman exec ${var.indexer_container_name} sh -ec '
            cert_tmp=/tmp/securityadmin-cert.pem
            key_tmp=/tmp/securityadmin-key.pem

            awk '\''/-----BEGIN CERTIFICATE-----/{flag=1} flag{print} /-----END CERTIFICATE-----/{exit}'\'' \
              /usr/share/wazuh-indexer/certs/admin.pem > "$cert_tmp"

            awk '\''/-----BEGIN .*PRIVATE KEY-----/{flag=1} flag{print} /-----END .*PRIVATE KEY-----/{exit}'\'' \
              /usr/share/wazuh-indexer/certs/admin.pem > "$key_tmp"

            env OPENSEARCH_JAVA_HOME=/usr/share/wazuh-indexer/jdk JAVA_HOME=/usr/share/wazuh-indexer/jdk \
              bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
                -h 127.0.0.1 \
                -cd /usr/share/wazuh-indexer/opensearch-security \
                -cacert /usr/share/wazuh-indexer/certs/ca-bundle.pem \
                -cert "$cert_tmp" \
                -key "$key_tmp" \
                -icl -nhnv
          '; then
            exit 0
          fi
        fi

        sleep 5
      done

      echo "securityadmin bootstrap failed for ${var.indexer_container_name}" >&2
      exit 1
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -euo pipefail

      # Wait for security index to be ready after bootstrap, then configure role mappings
      # for proxy-auth (oauth2-proxy + Keycloak) users to access the dashboard.
      for _ in $(seq 1 12); do
        if podman exec ${var.indexer_container_name} sh -ec '
          # Extract cert/key from admin.pem for API auth
          cert_tmp=/tmp/api-cert.pem
          key_tmp=/tmp/api-key.pem

          awk '\''/-----BEGIN CERTIFICATE-----/{flag=1} flag{print} /-----END CERTIFICATE-----/{exit}'\'' \
            /usr/share/wazuh-indexer/certs/admin.pem > "$cert_tmp"

          awk '\''/-----BEGIN .*PRIVATE KEY-----/{flag=1} flag{print} /-----END .*PRIVATE KEY-----/{exit}'\'' \
            /usr/share/wazuh-indexer/certs/admin.pem > "$key_tmp"

          # Configure role mapping to allow proxy-auth users dashboard access
          # Map any user authenticated via proxy header to the proxy_dashboard_users backend role,
          # which then maps to kibana_user role for dashboard permissions.
          curl -s -X PUT "https://127.0.0.1:9200/_plugins/_security/api/rolesmapping/kibana_user" \
            --cert "$cert_tmp" \
            --key "$key_tmp" \
            --cacert /usr/share/wazuh-indexer/certs/ca-bundle.pem \
            -H "Content-Type: application/json" \
            -d '"'"'{
              "backend_roles": ["${var.required_group}"],
              "hosts": [],
              "users": [],
              "and_backend_roles": []
            }'"'"' || true
        '; then
          exit 0
        fi

        sleep 5
      done

      echo "Role mapping configuration may have failed, but continuing..." >&2
      exit 0
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "podman compose --project-name ${self.triggers.project_name} -f ${self.triggers.compose_file} down --volumes 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}
