# ===========================================================================
# OIDC auth method — human operator identity via Keycloak
# ===========================================================================
#
# Phase 7 (automated): rebuild.sh applies this after Keycloak is healthy.
# The realm, OIDC clients, group, and seeded operator user are created by the
# Keycloak realm import JSON rendered at deploy time (services/keycloak).
# Keycloak → Vault OIDC flow:
#   bao login -method=oidc role=operator   → CLI callback (localhost:8250)
#   Vault UI  → browser callback (127.0.0.1:<vault_port> / /ui/vault/auth/oidc/…)

locals {
  # When oidc_redirect_uris is not overridden, compute the standard Vault CLI
  # and UI callback URLs from vault_port so they stay correct if the port changes.
  oidc_redirect_uris = var.oidc_redirect_uris != null ? var.oidc_redirect_uris : [
    "http://localhost:8250/oidc/callback",
    "https://127.0.0.1:${var.vault_port}/oidc/callback",
    "https://127.0.0.1:${var.vault_port}/ui/vault/auth/oidc/oidc/callback",
  ]
}

resource "vault_jwt_auth_backend" "oidc" {
  count = var.oidc_enabled ? 1 : 0

  type               = "oidc"
  path               = "oidc"
  description        = "OIDC authentication backed by Keycloak"
  oidc_discovery_url = "${var.keycloak_url}/realms/${var.keycloak_realm}"
  # Vault validates discovery over TLS from inside the Vault container, so
  # provide the Armory CA bundle explicitly for non-public CAs.
  oidc_discovery_ca_pem = try(file("${path.root}/../vault/ca-bundle.pem"), null)
  oidc_client_id     = var.oidc_client_id
  oidc_client_secret = var.oidc_client_secret
  default_role       = var.operator_username
}

resource "vault_jwt_auth_backend_role" "operator" {
  count = var.oidc_enabled ? 1 : 0

  backend               = vault_jwt_auth_backend.oidc[0].path
  role_name             = var.operator_username
  role_type             = "oidc"
  allowed_redirect_uris = local.oidc_redirect_uris
  user_claim            = "sub"
  groups_claim          = "groups"
  token_policies        = [vault_policy.operator.name]
}
