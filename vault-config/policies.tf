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

    # Self-service password change — own account only
    path "auth/userpass/users/${var.operator_username}/password" { capabilities = ["update"] }

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

    # KV v2 — list metadata (discover what secrets exist) and read values
    path "kv/metadata/*" { capabilities = ["list"] }
    path "kv/data/*"     { capabilities = ["read"] }
  EOT
}

# ---------------------------------------------------------------------------
# keycloak_db — read static credentials and request rotation
# ---------------------------------------------------------------------------

resource "vault_policy" "keycloak_db" {
  name = "keycloak_db"

  policy = <<-EOT
    path "database/static-creds/keycloak"  { capabilities = ["read"] }
    path "database/rotate-role/keycloak"   { capabilities = ["update"] }
  EOT
}

# ---------------------------------------------------------------------------
# app_db — generate dynamic credentials for the app database
# ---------------------------------------------------------------------------

resource "vault_policy" "app_db" {
  name = "app_db"

  policy = <<-EOT
    path "database/creds/app" { capabilities = ["read"] }
  EOT
}

# ---------------------------------------------------------------------------
# kv_admin — full lifecycle management of KV v2 secrets (bootstrap/rotation)
# ---------------------------------------------------------------------------

resource "vault_policy" "kv_admin" {
  name = "kv_admin"

  policy = <<-EOT
    path "kv/metadata/*" { capabilities = ["create", "read", "update", "delete", "list"] }
    path "kv/data/*"     { capabilities = ["create", "read", "update", "delete"] }
    path "kv/delete/*"   { capabilities = ["update"] }
    path "kv/undelete/*" { capabilities = ["update"] }
    path "kv/destroy/*"  { capabilities = ["update"] }
  EOT
}

# ---------------------------------------------------------------------------
# kv_reader_keycloak — scoped read-only access for Keycloak Vault Agent
# ---------------------------------------------------------------------------

resource "vault_policy" "kv_reader_keycloak" {
  name = "kv_reader_keycloak"

  policy = <<-EOT
    path "kv/metadata/keycloak/*" { capabilities = ["read", "list"] }
    path "kv/data/keycloak/*"     { capabilities = ["read"] }
  EOT
}

# ---------------------------------------------------------------------------
# agent — scoped policy for the agentic layer service
# Read dynamic DB credentials and agent-specific KV namespace only.
# Cannot issue certificates, cannot touch other services' secrets.
# ---------------------------------------------------------------------------

resource "vault_policy" "agent" {
  count = var.agent_enabled ? 1 : 0
  name  = "agent"

  policy = <<-EOT
    # TLS certificate issuance for the agent API sidecar
    path "pki_ext/issue/armory-external" { capabilities = ["create", "update"] }

    # Dynamic credentials for the app database
    path "database/creds/app" { capabilities = ["read"] }

    # Agent-specific KV namespace (task config, no cross-namespace access)
    path "kv/data/agent/*"     { capabilities = ["read"] }
    path "kv/metadata/agent/*" { capabilities = ["read", "list"] }

    # Token self-management
    path "auth/token/lookup-self" { capabilities = ["read"] }
    path "auth/token/renew-self"  { capabilities = ["update"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }
  EOT
}
