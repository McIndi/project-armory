# Database secrets engine tests for the vault-config/ module.

mock_provider "vault" {
  mock_resource "vault_pki_secret_backend_intermediate_set_signed" {
    defaults = {
      imported_issuers = ["mock-issuer-id"]
    }
  }
}
mock_provider "local" {}

variables {
  vault_token         = "test-token"
  vault_mgmt_password = "test-mgmt-pw"
}

run "database_mount_type" {
  command = plan

  assert {
    condition     = vault_mount.database.type == "database"
    error_message = "Database secrets engine must be of type 'database'"
  }
}

run "database_mount_path" {
  command = plan

  assert {
    condition     = vault_mount.database.path == "database"
    error_message = "Database secrets engine must be mounted at 'database'"
  }
}

run "postgres_connection_allowed_roles" {
  command = plan

  assert {
    condition     = contains(vault_database_secret_backend_connection.postgres.allowed_roles, "keycloak")
    error_message = "Postgres connection must allow the keycloak role"
  }

  assert {
    condition     = contains(vault_database_secret_backend_connection.postgres.allowed_roles, "app")
    error_message = "Postgres connection must allow the app role"
  }
}

run "keycloak_static_role_username" {
  command = plan

  assert {
    condition     = vault_database_secret_backend_static_role.keycloak.username == "keycloak"
    error_message = "Keycloak static role must manage the 'keycloak' PostgreSQL user"
  }
}

run "keycloak_static_role_rotation_period_is_86400" {
  command = plan

  assert {
    condition     = vault_database_secret_backend_static_role.keycloak.rotation_period == 86400
    error_message = "Keycloak static role rotation period must be 86400 seconds (24h)"
  }
}

run "app_dynamic_role_default_ttl" {
  command = plan

  assert {
    condition     = vault_database_secret_backend_role.app.default_ttl == 3600
    error_message = "App dynamic role default TTL must be 3600 seconds (1h)"
  }
}

run "app_dynamic_role_max_ttl" {
  command = plan

  assert {
    condition     = vault_database_secret_backend_role.app.max_ttl == 86400
    error_message = "App dynamic role max TTL must be 86400 seconds (24h)"
  }
}

run "keycloak_db_policy_allows_static_cred_read" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.keycloak_db.policy, "database/static-creds/keycloak")
    error_message = "keycloak_db policy must allow reading static credentials"
  }
}

run "keycloak_db_policy_allows_rotation" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.keycloak_db.policy, "database/rotate-role/keycloak")
    error_message = "keycloak_db policy must allow requesting credential rotation"
  }
}

run "app_db_policy_allows_dynamic_cred_generation" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.app_db.policy, "database/creds/app")
    error_message = "app_db policy must allow generating dynamic credentials"
  }
}
