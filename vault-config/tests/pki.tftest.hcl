# PKI configuration tests for the vault-config/ module.
#
# The vault and local providers are mocked — no live Vault is required.
# Tests verify resource configuration (inputs, names, settings), not
# runtime behaviour (that is covered by the pytest integration suite).

mock_provider "vault" {
  # imported_issuers is empty in mock responses by default; the [0] index
  # in pki.tf would panic without this override.
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

# ---------------------------------------------------------------------------
# Mount paths
# ---------------------------------------------------------------------------

run "pki_mount_paths" {
  command = plan

  assert {
    condition     = vault_mount.pki_root.path == "pki"
    error_message = "Root CA must be mounted at pki/"
  }

  assert {
    condition     = vault_mount.pki_int.path == "pki_int"
    error_message = "Internal intermediate must be mounted at pki_int/"
  }

  assert {
    condition     = vault_mount.pki_ext.path == "pki_ext"
    error_message = "External intermediate must be mounted at pki_ext/"
  }
}

run "pki_mount_types_are_pki" {
  command = plan

  assert {
    condition     = vault_mount.pki_root.type == "pki"
    error_message = "Root mount must be type pki"
  }

  assert {
    condition     = vault_mount.pki_int.type == "pki"
    error_message = "Internal mount must be type pki"
  }

  assert {
    condition     = vault_mount.pki_ext.type == "pki"
    error_message = "External mount must be type pki"
  }
}

# ---------------------------------------------------------------------------
# CA common names
# ---------------------------------------------------------------------------

run "root_ca_common_name" {
  command = plan

  assert {
    condition     = vault_pki_secret_backend_root_cert.root.common_name == "Armory Root CA"
    error_message = "Root CA must have CN=Armory Root CA"
  }
}

run "intermediate_common_names" {
  command = plan

  assert {
    condition     = vault_pki_secret_backend_intermediate_cert_request.int.common_name == "Armory Internal Intermediate CA"
    error_message = "Internal intermediate must have correct CN"
  }

  assert {
    condition     = vault_pki_secret_backend_intermediate_cert_request.ext.common_name == "Armory External Intermediate CA"
    error_message = "External intermediate must have correct CN"
  }
}

# ---------------------------------------------------------------------------
# Role configuration
# ---------------------------------------------------------------------------

run "role_names" {
  command = plan

  assert {
    condition     = vault_pki_secret_backend_role.armory_server.name == "armory-server"
    error_message = "Internal role must be named armory-server"
  }

  assert {
    condition     = vault_pki_secret_backend_role.armory_external.name == "armory-external"
    error_message = "External role must be named armory-external"
  }
}

run "roles_use_ec_p384" {
  command = plan

  assert {
    condition     = vault_pki_secret_backend_role.armory_server.key_type == "ec"
    error_message = "Internal role must use EC keys"
  }

  assert {
    condition     = vault_pki_secret_backend_role.armory_server.key_bits == 384
    error_message = "Internal role must use 384-bit keys"
  }

  assert {
    condition     = vault_pki_secret_backend_role.armory_external.key_type == "ec"
    error_message = "External role must use EC keys"
  }

  assert {
    condition     = vault_pki_secret_backend_role.armory_external.key_bits == 384
    error_message = "External role must use 384-bit keys"
  }
}

run "internal_role_domain_constraint" {
  command = plan

  assert {
    condition     = contains(vault_pki_secret_backend_role.armory_server.allowed_domains, "armory.internal")
    error_message = "Internal role must be constrained to armory.internal"
  }

  assert {
    condition     = vault_pki_secret_backend_role.armory_server.allow_subdomains == true
    error_message = "Internal role must allow subdomains"
  }
}

run "external_role_allows_any_name_when_domains_empty" {
  command = plan

  # Default: pki_ext_allowed_domains = ""
  assert {
    condition     = vault_pki_secret_backend_role.armory_external.allow_any_name == true
    error_message = "External role must allow any name when pki_ext_allowed_domains is empty"
  }
}

run "external_role_constrained_when_domains_set" {
  command = plan

  variables {
    pki_ext_allowed_domains = "example.com,api.example.com"
  }

  assert {
    condition     = vault_pki_secret_backend_role.armory_external.allow_any_name == false
    error_message = "External role must not allow any name when domains are specified"
  }
}

# ---------------------------------------------------------------------------
# Key hierarchy — intermediates use root backend
# ---------------------------------------------------------------------------

run "intermediates_signed_by_root" {
  command = plan

  assert {
    condition     = vault_pki_secret_backend_root_sign_intermediate.int.backend == "pki"
    error_message = "Internal intermediate must be signed by the root CA (pki/)"
  }

  assert {
    condition     = vault_pki_secret_backend_root_sign_intermediate.ext.backend == "pki"
    error_message = "External intermediate must be signed by the root CA (pki/)"
  }
}
