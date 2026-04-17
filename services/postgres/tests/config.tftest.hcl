# Unit tests for services/postgres/ module configuration.
# local and null providers are mocked — no running containers needed.

mock_provider "local" {}
mock_provider "null" {}

variables {
  postgres_password   = "test-postgres-pw"
  vault_mgmt_password = "test-vault-mgmt-pw"
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
