# ===========================================================================
# KV v2 secrets engine
# ===========================================================================

resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "KV v2 store for bootstrap secrets (Keycloak admin credentials, etc.)"
}

# ---------------------------------------------------------------------------
# Keycloak admin credentials — consumed by Vault Agent sidecar on first start
# ---------------------------------------------------------------------------

resource "vault_kv_secret_v2" "keycloak_admin" {
  mount = vault_mount.kv.path
  name  = "keycloak/admin"

  data_json = jsonencode({
    username = var.keycloak_admin_username
    password = var.keycloak_admin_password
  })
}
