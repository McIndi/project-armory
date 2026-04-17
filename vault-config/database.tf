# ===========================================================================
# Database secrets engine
# ===========================================================================

resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "Dynamic and static credential management for PostgreSQL"
}

# ---------------------------------------------------------------------------
# PostgreSQL connection — vault_mgmt account
# ---------------------------------------------------------------------------

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "postgres"
  allowed_roles = ["keycloak", "app"]

  verify_connection = false

  postgresql {
    connection_url = "postgresql://vault_mgmt:${var.vault_mgmt_password}@${var.postgres_host}:5432/postgres"
  }
}

# ---------------------------------------------------------------------------
# Static role — Keycloak (connection pool, no mid-session rotation)
# Vault manages the keycloak PG role's password; Keycloak reads it via agent.
# ---------------------------------------------------------------------------

resource "vault_database_secret_backend_static_role" "keycloak" {
  backend  = vault_mount.database.path
  name     = "keycloak"
  db_name  = vault_database_secret_backend_connection.postgres.name
  username = "keycloak"

  rotation_period = 86400

  rotation_statements = [
    "ALTER ROLE \"{{name}}\" WITH PASSWORD '{{password}}';"
  ]
}

# ---------------------------------------------------------------------------
# Dynamic role — app (short-lived ephemeral credentials)
# ---------------------------------------------------------------------------

resource "vault_database_secret_backend_role" "app" {
  backend = vault_mount.database.path
  name    = "app"
  db_name = vault_database_secret_backend_connection.postgres.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT app_role TO \"{{name}}\";"
  ]

  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]

  default_ttl = 3600
  max_ttl     = 86400
}
