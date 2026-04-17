# ===========================================================================
# AppRole auth method
# ===========================================================================

resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle"
  description = "AppRole authentication for service-to-Vault machine identity"
}
