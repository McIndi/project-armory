# OIDC auth method tests for the vault-config/ module.

mock_provider "vault" {
  mock_resource "vault_pki_secret_backend_intermediate_set_signed" {
    defaults = {
      imported_issuers = ["mock-issuer-id"]
    }
  }
}
mock_provider "local" {}

variables {
  vault_token        = "test-token"
  oidc_enabled       = true
  oidc_client_secret = "test-secret"
}

run "oidc_backend_type_is_oidc" {
  command = plan

  assert {
    condition     = vault_jwt_auth_backend.oidc[0].type == "oidc"
    error_message = "OIDC auth backend must be of type 'oidc'"
  }
}

run "oidc_backend_path" {
  command = plan

  assert {
    condition     = vault_jwt_auth_backend.oidc[0].path == "oidc"
    error_message = "OIDC auth backend must be mounted at path 'oidc'"
  }
}

run "oidc_discovery_url_includes_armory_realm" {
  command = plan

  assert {
    condition     = strcontains(vault_jwt_auth_backend.oidc[0].oidc_discovery_url, "/realms/armory")
    error_message = "OIDC discovery URL must point to the 'armory' Keycloak realm"
  }
}

run "operator_role_type_is_oidc" {
  command = plan

  assert {
    condition     = vault_jwt_auth_backend_role.operator[0].role_type == "oidc"
    error_message = "Operator role type must be 'oidc'"
  }
}

run "operator_role_uses_groups_claim" {
  command = plan

  assert {
    condition     = vault_jwt_auth_backend_role.operator[0].groups_claim == "groups"
    error_message = "Operator role must use 'groups' claim for group membership mapping"
  }
}

run "operator_role_token_policies_include_operator" {
  command = plan

  assert {
    condition     = contains(vault_jwt_auth_backend_role.operator[0].token_policies, "operator")
    error_message = "Operator OIDC role must grant the 'operator' Vault policy"
  }
}

run "oidc_not_created_when_disabled" {
  command = plan

  variables {
    oidc_enabled = false
  }

  assert {
    condition     = length(vault_jwt_auth_backend.oidc) == 0
    error_message = "OIDC backend must not be created when oidc_enabled is false"
  }
}

run "userpass_not_created_when_disabled" {
  command = plan

  variables {
    userpass_enabled = false
  }

  assert {
    condition     = length(vault_auth_backend.userpass) == 0
    error_message = "Userpass backend must not be created when userpass_enabled is false"
  }
}
