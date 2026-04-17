# ===========================================================================
# AppRole auth method — machine-to-machine identity
# ===========================================================================

resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle"
  description = "AppRole authentication for service-to-Vault machine identity"
}

# ===========================================================================
# Userpass auth method — human operator identity
# ===========================================================================

resource "vault_auth_backend" "userpass" {
  count       = var.userpass_enabled ? 1 : 0
  type        = "userpass"
  path        = "userpass"
  description = "Username/password authentication for human operators"
}

resource "vault_generic_endpoint" "operator_user" {
  count                = var.userpass_enabled ? 1 : 0
  path                 = "auth/${vault_auth_backend.userpass[0].path}/users/operator"
  ignore_absent_fields = true

  data_json = jsonencode({
    password       = var.operator_password
    token_policies = [vault_policy.operator.name]
  })

  depends_on = [vault_auth_backend.userpass, vault_policy.operator]
}
