# KV v2 secrets engine tests for the vault-config/ module.

mock_provider "vault" {
  mock_resource "vault_pki_secret_backend_intermediate_set_signed" {
    defaults = {
      imported_issuers = ["mock-issuer-id"]
    }
  }
}
mock_provider "local" {}

variables {
  vault_token = "test-token"
}

run "kv_mount_path" {
  command = plan

  assert {
    condition     = vault_mount.kv.path == "kv"
    error_message = "KV mount must be at path 'kv'"
  }
}

run "kv_mount_type_is_kv_v2" {
  command = plan

  assert {
    condition     = vault_mount.kv.type == "kv"
    error_message = "KV mount type must be 'kv'"
  }

  assert {
    condition     = vault_mount.kv.options["version"] == "2"
    error_message = "KV mount options must specify version 2"
  }
}

run "keycloak_admin_secret_path" {
  command = plan

  assert {
    condition     = vault_kv_secret_v2.keycloak_admin.name == "keycloak/admin"
    error_message = "Keycloak admin secret must be stored at keycloak/admin"
  }
}

run "kv_admin_policy_covers_data_path" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.kv_admin.policy, "kv/data/*")
    error_message = "kv_admin policy must cover kv/data/* for secret value management"
  }
}

run "kv_admin_policy_covers_metadata_path" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.kv_admin.policy, "kv/metadata/*")
    error_message = "kv_admin policy must cover kv/metadata/* for version management"
  }
}

run "kv_reader_keycloak_covers_data_path" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.kv_reader_keycloak.policy, "kv/data/keycloak/*")
    error_message = "kv_reader_keycloak policy must cover kv/data/keycloak/*"
  }
}

run "kv_reader_keycloak_covers_metadata_path" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.kv_reader_keycloak.policy, "kv/metadata/keycloak/*")
    error_message = "kv_reader_keycloak policy must cover kv/metadata/keycloak/*"
  }
}

run "operator_policy_can_list_kv_metadata" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.operator.policy, "kv/metadata/*")
    error_message = "Operator policy must allow listing KV metadata"
  }
}

run "operator_policy_can_read_kv_data" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.operator.policy, "kv/data/*")
    error_message = "Operator policy must allow reading KV data"
  }
}
