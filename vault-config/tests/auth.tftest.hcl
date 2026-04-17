# Auth method configuration tests for the vault-config/ module.

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

run "approle_mount_path" {
  command = plan

  assert {
    condition     = vault_auth_backend.approle.path == "approle"
    error_message = "AppRole must be mounted at approle/"
  }
}

run "approle_mount_type" {
  command = plan

  assert {
    condition     = vault_auth_backend.approle.type == "approle"
    error_message = "Auth backend must be of type approle"
  }
}
