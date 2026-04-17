# ===========================================================================
# OIDC auth method — human operator identity via Keycloak
# ===========================================================================
#
# Deployment ceremony (do NOT skip steps):
#   1. Keycloak must be running and reachable at var.keycloak_url
#   2. Create realm 'armory', OIDC client 'vault', group 'vault-operators'
#   3. Map group membership to a 'groups' claim in the token
#   4. Apply this module (adds OIDC alongside userpass — both work)
#   5. Verify: bao login -method=oidc role=operator
#   6. Only then: tofu apply -var userpass_enabled=false

resource "vault_jwt_auth_backend" "oidc" {
  count = var.oidc_enabled ? 1 : 0

  type               = "oidc"
  path               = "oidc"
  description        = "OIDC authentication backed by Keycloak"
  oidc_discovery_url = "${var.keycloak_url}/realms/armory"
  oidc_client_id     = var.oidc_client_id
  oidc_client_secret = var.oidc_client_secret
  default_role       = "operator"
}

resource "vault_jwt_auth_backend_role" "operator" {
  count = var.oidc_enabled ? 1 : 0

  backend           = vault_jwt_auth_backend.oidc[0].path
  role_name         = "operator"
  role_type         = "oidc"
  allowed_redirect_uris = ["http://localhost:8250/oidc/callback"]
  user_claim        = "sub"
  groups_claim      = "groups"
  token_policies    = [vault_policy.operator.name]
}
