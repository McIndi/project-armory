# Output value tests for the vault/ module.

mock_provider "null" {}
mock_provider "local" {}

run "vault_addr_output_is_localhost" {
  command = plan

  assert {
    condition     = output.vault_addr == "https://127.0.0.1:8200"
    error_message = "vault_addr must be the localhost-only address"
  }
}

run "image_output_includes_all_parts" {
  command = plan

  assert {
    condition     = output.image == "${var.image_registry}/${var.image_name}:${var.image_tag}"
    error_message = "image output must be registry/name:tag"
  }
}

run "deploy_dir_output_matches_variable" {
  command = plan

  assert {
    condition     = output.deploy_dir == var.deploy_dir
    error_message = "deploy_dir output must match the deploy_dir variable"
  }
}

run "compose_file_output_is_under_deploy_dir" {
  command = plan

  assert {
    condition     = output.compose_file == "${var.deploy_dir}/compose.yml"
    error_message = "compose_file output must be deploy_dir/compose.yml"
  }
}

run "ui_disabled_returns_null_url" {
  command = plan

  variables {
    ui_enabled = false
  }

  assert {
    condition     = output.vault_ui_url == null
    error_message = "vault_ui_url must be null when ui_enabled is false"
  }
}

run "vault_config_includes_audit_stanza" {
  command = plan

  assert {
    condition     = strcontains(local_file.vault_config.content, "audit \"file\"")
    error_message = "vault.hcl must contain a file audit device declaration"
  }

  assert {
    condition     = strcontains(local_file.vault_config.content, "/vault/logs/audit.log")
    error_message = "audit device must write to /vault/logs/audit.log"
  }
}
