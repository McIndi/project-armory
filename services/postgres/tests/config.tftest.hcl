# Unit tests for services/postgres/ module configuration.
# local, null, and vault providers are mocked — no running containers needed.

mock_provider "local" {}
mock_provider "null" {}
mock_provider "vault" {}

variables {
  postgres_password   = "test-postgres-pw"
  vault_mgmt_password = "test-vault-mgmt-pw"
  vault_token         = "test-token"
}

run "postgres_host_output_is_container_name" {
  command = plan

  assert {
    condition     = output.postgres_host == var.container_name
    error_message = "postgres_host output must match the container_name variable"
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

run "compose_includes_healthcheck" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "pg_isready")
    error_message = "compose.yml must include a pg_isready healthcheck"
  }
}

run "compose_uses_external_network" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "external: true")
    error_message = "compose.yml must join the external armory-net network"
  }
}

run "init_sql_creates_vault_mgmt_role" {
  command = plan

  assert {
    condition     = strcontains(local_file.init_sql.content, "CREATE ROLE vault_mgmt")
    error_message = "init.sql must create the vault_mgmt role"
  }
}

run "init_sql_grants_connect_on_keycloak" {
  command = plan

  assert {
    condition     = strcontains(local_file.init_sql.content, "GRANT CONNECT ON DATABASE keycloak TO vault_mgmt")
    error_message = "init.sql must grant vault_mgmt CONNECT on the keycloak database"
  }
}

run "init_sql_grants_connect_on_app" {
  command = plan

  assert {
    condition     = strcontains(local_file.init_sql.content, "GRANT CONNECT ON DATABASE app TO vault_mgmt")
    error_message = "init.sql must grant vault_mgmt CONNECT on the app database"
  }
}

run "init_sql_creates_keycloak_database" {
  command = plan

  assert {
    condition     = strcontains(local_file.init_sql.content, "CREATE DATABASE keycloak")
    error_message = "init.sql must create the keycloak database"
  }
}

run "init_sql_creates_app_database" {
  command = plan

  assert {
    condition     = strcontains(local_file.init_sql.content, "CREATE DATABASE app")
    error_message = "init.sql must create the app database"
  }
}

run "init_sql_grants_admin_option_on_template_roles" {
  command = plan

  assert {
    condition     = strcontains(local_file.init_sql.content, "WITH ADMIN OPTION")
    error_message = "init.sql must grant template roles to vault_mgmt WITH ADMIN OPTION"
  }
}

run "vault_agent_service_in_compose" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "vault-agent")
    error_message = "compose.yml must include a vault-agent service"
  }
}

run "postgres_depends_on_vault_agent_healthy" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "service_healthy")
    error_message = "postgres service must depend on vault-agent being healthy"
  }
}

run "postgres_ssl_on_flag" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "ssl=on")
    error_message = "postgres startup command must pass -c ssl=on"
  }
}

run "postgres_mounts_certs_volume" {
  command = plan

  assert {
    condition     = strcontains(local_file.compose.content, "/vault/certs")
    error_message = "compose.yml must mount the certs volume into the postgres container"
  }
}

run "agent_config_has_cert_stanza" {
  command = plan

  assert {
    condition     = strcontains(local_file.agent_config.content, "postgres.crt")
    error_message = "agent.hcl must include a template stanza writing postgres.crt"
  }
}

run "agent_config_has_key_stanza" {
  command = plan

  assert {
    condition     = strcontains(local_file.agent_config.content, "postgres.key")
    error_message = "agent.hcl must include a template stanza writing postgres.key"
  }
}

run "approle_role_name" {
  command = plan

  assert {
    condition     = vault_approle_auth_backend_role.postgres.role_name == "postgres"
    error_message = "AppRole role name must be 'postgres'"
  }
}
