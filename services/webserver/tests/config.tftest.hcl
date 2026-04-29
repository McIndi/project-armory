# Unit tests for services/webserver/ module configuration.
# Vault, local, and null providers are all mocked — no live infrastructure needed.

mock_provider "vault" {
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
# Vault policy
# ---------------------------------------------------------------------------

run "policy_name" {
  command = plan

  assert {
    condition     = vault_policy.webserver.name == "webserver"
    error_message = "Vault policy must be named webserver"
  }
}

run "policy_grants_pki_ext_issue" {
  command = plan

  assert {
    condition     = can(regex("pki_ext/issue/armory-external", vault_policy.webserver.policy))
    error_message = "Policy must grant access to pki_ext/issue/armory-external"
  }
}

# ---------------------------------------------------------------------------
# AppRole role
# ---------------------------------------------------------------------------

run "approle_role_name" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role.webserver.role_name == "webserver"
    error_message = "AppRole role must be named webserver"
  }
}

run "approle_role_uses_correct_mount" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role.webserver.backend == var.approle_mount_path
    error_message = "AppRole role must use the configured approle mount path"
  }
}

run "approle_role_binds_webserver_policy" {
  command = plan

  assert {
    condition     = contains(vault_approle_auth_backend_role.webserver.token_policies, "webserver")
    error_message = "AppRole role must bind the webserver policy"
  }
}

run "secret_id_uses_response_wrapping" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role_secret_id.webserver.wrapping_ttl != null
    error_message = "secret_id must use response wrapping (wrapping_ttl must be set)"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

run "nginx_url_output" {
  command = plan

  assert {
    condition     = output.nginx_url == "https://${var.host_ip}:${var.nginx_host_port}"
    error_message = "nginx_url must be https://host_ip:nginx_host_port"
  }
}
