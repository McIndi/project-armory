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
    connection_url = "postgresql://${var.vault_mgmt_username}:${var.vault_mgmt_password}@${var.postgres_host}:${var.postgres_port}/postgres?sslmode=require"
  }
}

# ---------------------------------------------------------------------------
# Static role — Keycloak (connection pool, no mid-session rotation)
# Vault manages the keycloak PG role's password; Keycloak reads it via agent.
#
# Requires Postgres to be running — Vault connects immediately on role creation
# to set the initial credential. Apply with database_roles_enabled=true only
# after services/postgres/ has been applied and the container is healthy.
# ---------------------------------------------------------------------------

resource "vault_database_secret_backend_static_role" "keycloak" {
  count    = var.database_roles_enabled ? 1 : 0
  backend  = vault_mount.database.path
  name     = "keycloak"
  db_name  = vault_database_secret_backend_connection.postgres.name
  username = var.keycloak_db_username

  rotation_period = 86400

  rotation_statements = [
    "ALTER ROLE \"{{name}}\" WITH PASSWORD '{{password}}';"
  ]
}

# ---------------------------------------------------------------------------
# Dynamic role — app (short-lived ephemeral credentials)
# ---------------------------------------------------------------------------

resource "vault_database_secret_backend_role" "app" {
  count   = var.database_roles_enabled ? 1 : 0
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
