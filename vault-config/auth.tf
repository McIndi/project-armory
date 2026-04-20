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

# ===========================================================================
# Agent AppRole — machine identity for the agentic layer service
# ===========================================================================

# The wrapped_secret_id is intentionally NOT created here. It is managed
# exclusively by services/agent/main.tf, matching the pattern used by every
# other service module. Two state files owning the same Vault resource causes
# state drift: every vault-config apply would issue a new wrapped_secret_id
# and invalidate the one on disk.
resource "vault_approle_auth_backend_role" "agent" {
  count          = var.agent_enabled ? 1 : 0
  backend        = vault_auth_backend.approle.path
  role_name      = "agent"
  token_policies = [vault_policy.agent[0].name]
  token_ttl      = 1800  # 30 minutes — sufficient for one task run
  token_max_ttl  = 3600
  secret_id_ttl  = 600   # 10 minutes to unwrap and authenticate
}
