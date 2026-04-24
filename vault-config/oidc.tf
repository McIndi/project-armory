# ===========================================================================
# OIDC auth method — human operator identity via Keycloak
# ===========================================================================
#
# Phase 7 (automated): rebuild.sh applies this after Keycloak is healthy.
# The realm, OIDC clients, group, and seeded operator user are created by the
# Keycloak realm import JSON rendered at deploy time (services/keycloak).
# Keycloak → Vault OIDC flow:
#   bao login -method=oidc role=operator   → CLI callback (localhost:8250)
#   Vault UI  → browser callback (127.0.0.1:8200 / /ui/vault/auth/oidc/…)

resource "vault_jwt_auth_backend" "oidc" {
  count = var.oidc_enabled ? 1 : 0

  type               = "oidc"
  path               = "oidc"
  description        = "OIDC authentication backed by Keycloak"
  oidc_discovery_url = "${var.keycloak_url}/realms/armory"
  # Vault validates discovery over TLS from inside the Vault container, so
  # provide the Armory CA bundle explicitly for non-public CAs.
  oidc_discovery_ca_pem = try(file("${path.root}/../vault/ca-bundle.pem"), null)
  oidc_client_id     = var.oidc_client_id
  oidc_client_secret = var.oidc_client_secret
  default_role       = "operator"
}

resource "vault_jwt_auth_backend_role" "operator" {
  count = var.oidc_enabled ? 1 : 0

  backend               = vault_jwt_auth_backend.oidc[0].path
  role_name             = "operator"
  role_type             = "oidc"
  allowed_redirect_uris = var.oidc_redirect_uris
  user_claim            = "sub"
  groups_claim          = "groups"
  token_policies        = [vault_policy.operator.name]
}
