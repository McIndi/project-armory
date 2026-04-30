# Unit tests for services/wazuh/ module configuration.
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
  vault_token              = "test-token"
  wazuh_oidc_client_secret = "test-wazuh-secret"
  wazuh_cookie_secret      = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
}

run "policy_name" {
  command = plan

  assert {
    condition     = vault_policy.wazuh.name == "wazuh"
    error_message = "Vault policy must be named wazuh"
  }
}

run "policy_grants_pki_issue" {
  command = plan

  assert {
    condition     = can(regex("pki_ext/issue/armory-external", vault_policy.wazuh.policy))
    error_message = "Policy must grant access to pki_ext certificate issuance"
  }
}

run "approle_role_name" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role.wazuh.role_name == "wazuh"
    error_message = "AppRole role must be named wazuh"
  }
}

run "secret_id_uses_response_wrapping" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role_secret_id.wazuh.wrapping_ttl != null
    error_message = "secret_id must use response wrapping"
  }
}

run "compose_includes_manager" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, var.manager_container_name)
    error_message = "compose.yml must include the Wazuh manager service"
  }
}

run "compose_includes_auth_proxy" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, var.auth_proxy_container_name)
    error_message = "compose.yml must include the oauth2-proxy service"
  }
}

run "compose_includes_observer" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, var.observer_container_name)
    error_message = "compose.yml must include the observer sidecar service"
  }
}

run "wazuh_auth_url_output" {
  command = plan

  assert {
    condition     = output.wazuh_auth_url == "https://${var.host_ip}:${var.wazuh_auth_proxy_port}"
    error_message = "wazuh_auth_url must expose the Keycloak-protected endpoint"
  }
}

run "oidc_secret_seeded_in_vault" {
  command = plan

  assert {
    condition     = vault_kv_secret_v2.wazuh_oidc.mount == "kv"
    error_message = "Wazuh OIDC secret must be written to the kv mount"
  }

  assert {
    condition     = vault_kv_secret_v2.wazuh_oidc.name == "wazuh/oidc"
    error_message = "Wazuh OIDC secret must be written to wazuh/oidc"
  }
}
