# ===========================================================================
# Locals
# ===========================================================================

locals {
  pgdata_dir    = "${var.deploy_dir}/pgdata"
  init_sql_path = "${var.deploy_dir}/init.sql"
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
      mkdir -p "${local.pgdata_dir}"
      chmod 777 "${local.pgdata_dir}"
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
    project_name      = var.compose_project_name
    postgres_image    = var.postgres_image
    container_name    = var.container_name
    postgres_password = var.postgres_password
    pgdata_dir        = local.pgdata_dir
    init_sql_path     = local.init_sql_path
    network_name      = var.network_name
  })
}

# ===========================================================================
# Deploy
# ===========================================================================

resource "null_resource" "deploy" {
  depends_on = [
    local_file.init_sql,
    local_file.compose,
  ]

  triggers = {
    compose_hash = local_file.compose.content
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
