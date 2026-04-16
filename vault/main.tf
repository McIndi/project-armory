# ===========================================================================
# Locals — single source of truth for derived paths and values
# ===========================================================================

locals {
  image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

  dirs = {
    config = "${var.deploy_dir}/config"
    data   = "${var.deploy_dir}/data"
    tls    = "${var.deploy_dir}/tls"
    logs   = "${var.deploy_dir}/logs"
  }

  # Merge caller-supplied SANs with the always-required entries
  san_dns = distinct(concat(["localhost", var.tls_server_cn], var.tls_san_dns, [var.api_addr]))
  san_ip  = distinct(concat(["127.0.0.1"], var.tls_san_ip, [var.api_addr == "127.0.0.1" ? "" : var.api_addr]))

  # Strip empty strings that sneak in when api_addr == 127.0.0.1
  san_ip_clean = [for ip in local.san_ip : ip if ip != ""]
}

# ===========================================================================
# TLS — CA + server certificate chain
# ===========================================================================

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name  = var.tls_ca_cn
    organization = var.tls_org
  }

  validity_period_hours = var.tls_validity_hours
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "key_encipherment",
    "digital_signature",
  ]
}

resource "tls_private_key" "server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name  = var.tls_server_cn
    organization = var.tls_org
  }

  dns_names    = local.san_dns
  ip_addresses = local.san_ip_clean
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem   = tls_cert_request.server.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = var.tls_validity_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ===========================================================================
# Host directory scaffolding
# ===========================================================================

resource "null_resource" "create_dirs" {
  triggers = {
    dirs = jsonencode(local.dirs)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      for d in ${join(" ", values(local.dirs))}; do
        mkdir -p "$d"
        chmod 750 "$d"
      done
      # data and tls dirs need tighter permissions
      chmod 700 "${local.dirs.data}"
      chmod 700 "${local.dirs.tls}"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# ===========================================================================
# TLS artefacts written to host
# ===========================================================================

resource "local_sensitive_file" "ca_cert" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.tls}/ca.crt"
  content         = tls_self_signed_cert.ca.cert_pem
  file_permission = "0444"
}

resource "local_sensitive_file" "server_cert" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.tls}/vault.crt"
  content         = "${tls_locally_signed_cert.server.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
  file_permission = "0444"
}

resource "local_sensitive_file" "server_key" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.tls}/vault.key"
  content         = tls_private_key.server.private_key_pem
  file_permission = "0400"
}

# ===========================================================================
# Vault configuration
# ===========================================================================

resource "local_file" "vault_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/vault.hcl"
  file_permission = "0640"
  content         = templatefile("${path.module}/templates/vault.hcl.tpl", {
    node_id      = var.node_id
    api_addr     = var.api_addr
    api_port     = var.api_port
    cluster_port = var.cluster_port
    ui_enabled   = var.ui_enabled
    log_level    = var.log_level
    disable_mlock = var.disable_mlock
  })
}

# ===========================================================================
# Podman Compose file
# ===========================================================================

resource "local_file" "compose" {
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0640"
  content         = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name   = var.compose_project_name
    image          = local.image
    container_name = var.container_name
    restart_policy = var.restart_policy
    api_port       = var.api_port
    cluster_port   = var.cluster_port
    api_addr       = var.api_addr
    vault_binary   = var.vault_binary
    network_name   = var.podman_network_name
    config_dir     = local.dirs.config
    data_dir       = local.dirs.data
    tls_dir        = local.dirs.tls
    logs_dir       = local.dirs.logs
    disable_mlock  = var.disable_mlock
  })
}

# ===========================================================================
# Deploy — podman compose up
# ===========================================================================

resource "null_resource" "deploy" {
  depends_on = [
    local_file.vault_config,
    local_file.compose,
    local_sensitive_file.server_cert,
    local_sensitive_file.server_key,
    local_sensitive_file.ca_cert,
  ]

  triggers = {
    compose_hash         = local_file.compose.content
    config_hash          = local_file.vault_config.content
    cert_hash            = tls_locally_signed_cert.server.cert_pem
    compose_project_name = var.compose_project_name
    compose_file         = "${var.deploy_dir}/compose.yml"
  }

  provisioner "local-exec" {
    command     = "podman compose --project-name ${var.compose_project_name} -f ${var.deploy_dir}/compose.yml up -d --pull=always"
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "podman compose --project-name ${self.triggers.compose_project_name} -f ${self.triggers.compose_file} down --volumes 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}
