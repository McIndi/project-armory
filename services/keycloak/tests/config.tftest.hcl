# Unit tests for services/keycloak/ module configuration.
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
    condition     = vault_policy.keycloak.name == "keycloak"
    error_message = "Vault policy must be named 'keycloak'"
  }
}

run "policy_grants_pki_ext_issue" {
  command = plan

  assert {
    condition     = can(regex("pki_ext/issue/armory-external", vault_policy.keycloak.policy))
    error_message = "Policy must grant access to pki_ext/issue/armory-external"
  }
}

# ---------------------------------------------------------------------------
# AppRole
# ---------------------------------------------------------------------------

run "approle_role_name" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role.keycloak.role_name == "keycloak"
    error_message = "AppRole role must be named 'keycloak'"
  }
}

run "approle_role_binds_keycloak_policy" {
  command = plan

  assert {
    condition     = contains(vault_approle_auth_backend_role.keycloak.token_policies, "keycloak")
    error_message = "AppRole role must bind the keycloak PKI policy"
  }
}

run "approle_role_binds_db_policy" {
  command = plan

  assert {
    condition     = contains(vault_approle_auth_backend_role.keycloak.token_policies, var.keycloak_db_policy)
    error_message = "AppRole role must bind the database credentials policy"
  }
}

run "approle_role_binds_kv_reader_policy" {
  command = plan

  assert {
    condition     = contains(vault_approle_auth_backend_role.keycloak.token_policies, var.kv_reader_policy)
    error_message = "AppRole role must bind the KV reader policy"
  }
}

run "secret_id_uses_response_wrapping" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role_secret_id.keycloak.wrapping_ttl != null
    error_message = "secret_id must use response wrapping"
  }
}

# ---------------------------------------------------------------------------
# Compose file
# ---------------------------------------------------------------------------

run "compose_includes_vault_agent_service" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, var.agent_container_name)
    error_message = "compose.yml must include the vault-agent service"
  }
}

run "compose_includes_keycloak_service" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, var.keycloak_container_name)
    error_message = "compose.yml must include the keycloak service"
  }
}

run "compose_healthcheck_checks_cert" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "BEGIN CERTIFICATE")
    error_message = "vault-agent healthcheck must verify keycloak.pem contains a certificate"
  }
}

run "compose_healthcheck_checks_db_env" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "keycloak.env")
    error_message = "vault-agent healthcheck must verify the DB credentials env file exists"
  }
}

run "compose_uses_external_network" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "external: true")
    error_message = "compose.yml must join the external armory-net network"
  }
}

# ---------------------------------------------------------------------------
# Agent config
# ---------------------------------------------------------------------------

run "agent_config_has_pki_template" {
  command = plan

  assert {
    condition     = strcontains(local_file.agent_config.content, "pkiCert")
    error_message = "agent.hcl must contain a pkiCert template stanza"
  }
}

run "agent_config_has_db_creds_template" {
  command = plan

  assert {
    condition     = strcontains(local_file.agent_config.content, var.db_static_creds_path)
    error_message = "agent.hcl must contain a template stanza for database static credentials"
  }
}

run "agent_config_has_admin_creds_template" {
  command = plan

  assert {
    condition     = strcontains(local_file.agent_config.content, var.kv_admin_path)
    error_message = "agent.hcl must contain a template stanza for KV admin credentials"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

run "keycloak_url_output" {
  command = plan

  assert {
    condition     = output.keycloak_url == "https://${var.host_ip}:${var.keycloak_port}"
    error_message = "keycloak_url must be https://host_ip:keycloak_port"
  }
}
