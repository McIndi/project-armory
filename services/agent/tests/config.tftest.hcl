# Unit tests for services/agent/ module configuration.
# Vault, local, and null providers are all mocked — no live infrastructure needed.

mock_provider "vault" {
  mock_data "vault_approle_auth_backend_role_id" {
    defaults = {
      role_id = "mock-role-id"
    }
  }
  mock_resource "vault_approle_auth_backend_role_secret_id" {
    defaults = {
      wrapping_token = "mock-wrapping-token"
    }
  }
}
mock_provider "local" {}
mock_provider "null" {}

variables {
  vault_token = "test-token"
}

# ---------------------------------------------------------------------------
# AppRole credentials
# ---------------------------------------------------------------------------

run "secret_id_uses_response_wrapping" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role_secret_id.agent.wrapping_ttl != null
    error_message = "secret_id must use response wrapping"
  }
}

run "secret_id_targets_agent_role" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role_secret_id.agent.role_name == "agent"
    error_message = "secret_id must target the 'agent' AppRole role"
  }
}

# ---------------------------------------------------------------------------
# Credential files
# ---------------------------------------------------------------------------

run "role_id_file_in_approle_dir" {
  command = plan

  assert {
    condition     = local_sensitive_file.role_id.filename == "${var.deploy_dir}/approle/role_id"
    error_message = "role_id must be written to <deploy_dir>/approle/role_id"
  }
}

run "role_id_file_permission" {
  command = plan

  assert {
    condition     = local_sensitive_file.role_id.file_permission == "0444"
    error_message = "role_id file must have permission 0444"
  }
}

run "wrapped_secret_id_file_in_approle_dir" {
  command = plan

  assert {
    condition     = local_sensitive_file.wrapped_secret_id.filename == "${var.deploy_dir}/approle/wrapped_secret_id"
    error_message = "wrapped_secret_id must be written to <deploy_dir>/approle/wrapped_secret_id"
  }
}

run "wrapped_secret_id_file_permission" {
  command = plan

  assert {
    condition     = local_sensitive_file.wrapped_secret_id.file_permission == "0444"
    error_message = "wrapped_secret_id file must have permission 0444"
  }
}

run "tls_role_id_file_in_approle_dir" {
  command = plan

  assert {
    condition     = local_sensitive_file.role_id_tls.filename == "${var.deploy_dir}/approle/role_id_tls"
    error_message = "role_id_tls must be written to <deploy_dir>/approle/role_id_tls"
  }
}

run "tls_wrapped_secret_file_in_approle_dir" {
  command = plan

  assert {
    condition     = local_sensitive_file.wrapped_secret_id_tls.filename == "${var.deploy_dir}/approle/wrapped_secret_id_tls"
    error_message = "wrapped_secret_id_tls must be written to <deploy_dir>/approle/wrapped_secret_id_tls"
  }
}

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------

run "approle_dir_is_under_deploy_dir" {
  command = plan

  assert {
    condition     = startswith(local.dirs.approle, var.deploy_dir)
    error_message = "approle dir must be under deploy_dir"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

run "deploy_dir_output" {
  command = plan

  assert {
    condition     = output.deploy_dir == var.deploy_dir
    error_message = "deploy_dir output must equal var.deploy_dir"
  }
}

run "approle_dir_output" {
  command = plan

  assert {
    condition     = output.approle_dir == "${var.deploy_dir}/approle"
    error_message = "approle_dir output must be <deploy_dir>/approle"
  }
}

run "agent_api_url_output" {
  command = plan

  assert {
    condition     = output.agent_api_url == "https://${var.host_ip}:${var.host_port}"
    error_message = "agent_api_url output must expose the HTTPS endpoint"
  }
}
