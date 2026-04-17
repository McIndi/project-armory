# ACL policy and audit configuration tests for the vault-config/ module.

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

run "operator_policy_name" {
  command = plan

  assert {
    condition     = vault_policy.operator.name == "operator"
    error_message = "Operator policy must be named 'operator'"
  }
}

run "operator_policy_denies_cert_issuance" {
  command = plan

  assert {
    condition     = !strcontains(vault_policy.operator.policy, "pki_int/issue")
    error_message = "Operator policy must not grant certificate issuance on pki_int"
  }

  assert {
    condition     = !strcontains(vault_policy.operator.policy, "pki_ext/issue")
    error_message = "Operator policy must not grant certificate issuance on pki_ext"
  }
}

run "operator_policy_allows_pki_read" {
  command = plan

  assert {
    condition     = strcontains(vault_policy.operator.policy, "pki_int/ca")
    error_message = "Operator policy must allow reading pki_int CA"
  }

  assert {
    condition     = strcontains(vault_policy.operator.policy, "pki_ext/ca")
    error_message = "Operator policy must allow reading pki_ext CA"
  }
}

run "userpass_mount_type" {
  command = plan

  assert {
    condition     = vault_auth_backend.userpass.type == "userpass"
    error_message = "Userpass auth backend must be of type userpass"
  }
}

run "userpass_mount_path" {
  command = plan

  assert {
    condition     = vault_auth_backend.userpass.path == "userpass"
    error_message = "Userpass auth backend must be mounted at userpass/"
  }
}

run "audit_device_type" {
  command = plan

  assert {
    condition     = vault_audit.file.type == "file"
    error_message = "Audit device must be of type file"
  }
}

run "audit_log_path" {
  command = plan

  assert {
    condition     = vault_audit.file.options["file_path"] == "/vault/logs/audit.log"
    error_message = "Audit log must write to /vault/logs/audit.log (the bind-mounted logs volume)"
  }
}
