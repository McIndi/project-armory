# ===========================================================================
# ACL policies
# ===========================================================================

# ---------------------------------------------------------------------------
# operator — human operator, read-only introspection, no secret issuance
# ---------------------------------------------------------------------------

resource "vault_policy" "operator" {
  name = "operator"

  policy = <<-EOT
    # Token self-management
    path "auth/token/lookup-self" { capabilities = ["read"] }
    path "auth/token/renew-self"  { capabilities = ["update"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }

    # System introspection — sys/ paths require sudo in addition to read
    path "sys/health"   { capabilities = ["read", "sudo"] }
    path "sys/mounts"   { capabilities = ["read", "sudo"] }
    path "sys/mounts/+" { capabilities = ["read"] }
    path "sys/auth"     { capabilities = ["read", "sudo"] }
    path "sys/auth/+"   { capabilities = ["read"] }

    # Policies — list and read, no create/update/delete
    path "sys/policies/acl"   { capabilities = ["list"] }
    path "sys/policies/acl/+" { capabilities = ["read"] }

    # PKI — read CA material and list roles, no certificate issuance
    path "pki/ca"          { capabilities = ["read"] }
    path "pki/crl"         { capabilities = ["read"] }
    path "pki_int/ca"      { capabilities = ["read"] }
    path "pki_int/crl"     { capabilities = ["read"] }
    path "pki_ext/ca"      { capabilities = ["read"] }
    path "pki_ext/crl"     { capabilities = ["read"] }
    path "pki_int/roles"   { capabilities = ["list"] }
    path "pki_int/roles/+" { capabilities = ["read"] }
    path "pki_ext/roles"   { capabilities = ["list"] }
    path "pki_ext/roles/+" { capabilities = ["read"] }

    # AppRole — list and inspect roles, no secret_id generation
    path "auth/approle/role"   { capabilities = ["list"] }
    path "auth/approle/role/+" { capabilities = ["read"] }
  EOT
}
