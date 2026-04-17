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

  # Determine whether api_addr is an IP or a hostname
  api_addr_is_ip = can(cidrhost("${var.api_addr}/32", 0))

  # Merge caller-supplied SANs with the always-required entries
  # api_addr is added to DNS SANs only when it is a hostname, not an IP
  san_dns = distinct(concat(
    ["localhost", var.tls_server_cn],
    var.tls_san_dns,
    local.api_addr_is_ip ? [] : [var.api_addr],
  ))

  # api_addr is added to IP SANs only when it is an IP
  san_ip_clean = distinct(concat(
    ["127.0.0.1"],
    var.tls_san_ip,
    local.api_addr_is_ip && var.api_addr != "127.0.0.1" ? [var.api_addr] : [],
  ))
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
    dirs   = jsonencode(local.dirs)
    script = sha256("chmod755-config-tls 777-data-logs")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      mkdir -p "${local.dirs.config}" "${local.dirs.tls}" "${local.dirs.data}" "${local.dirs.logs}"
      chmod 755 "${local.dirs.config}" "${local.dirs.tls}"
      chmod 777 "${local.dirs.data}" "${local.dirs.logs}"
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when = destroy
    # Container-created files are owned by subuid-mapped UIDs the host user cannot
    # delete directly. Use podman unshare to run the removal inside the user namespace,
    # falling back to a plain rm for any host-owned files that remain.
    command     = "D=$(echo '${self.triggers.dirs}' | python3 -c \"import json,sys,os; d=json.load(sys.stdin); print(os.path.dirname(d['config']))\") && podman unshare rm -rf \"$D\" 2>/dev/null || rm -rf \"$D\" 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
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
  file_permission = "0444"
}

# ===========================================================================
# Vault configuration
# ===========================================================================

resource "local_file" "vault_config" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${local.dirs.config}/vault.hcl"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/vault.hcl.tpl", {
    node_id       = var.node_id
    api_addr      = var.api_addr
    ui_enabled    = var.ui_enabled
    log_level     = var.log_level
    disable_mlock = var.disable_mlock
  })
}

# ===========================================================================
# Podman Compose file
# ===========================================================================

resource "local_file" "compose" {
  depends_on      = [null_resource.create_dirs]
  filename        = "${var.deploy_dir}/compose.yml"
  file_permission = "0644"
  content         = templatefile("${path.module}/templates/compose.yml.tpl", {
    project_name   = var.compose_project_name
    image          = local.image
    container_name = var.container_name
    restart_policy = var.restart_policy
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
    command     = "podman compose --project-name ${var.compose_project_name} -f ${var.deploy_dir}/compose.yml up -d --pull-always"
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "podman compose --project-name ${self.triggers.compose_project_name} -f ${self.triggers.compose_file} down --volumes 2>/dev/null || true"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}
