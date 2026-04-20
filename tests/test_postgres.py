"""
Integration tests for the PostgreSQL service and Vault database secrets engine.

Prerequisites:
  - vault_env fixture (Vault running, vault-config applied)
  - postgres_env fixture (services/postgres/ applied, database roles enabled)
"""

import json
import subprocess
from pathlib import Path

import psycopg2
import pytest


PROJECT_ROOT = Path(__file__).parent.parent
# Postgres cert is issued by pki_int — verify against the PKI CA bundle.
PKI_CA_BUNDLE = str(PROJECT_ROOT / "vault" / "ca-bundle.pem")


def test_postgres_container_healthy(postgres_env):
    """Container health-check must report 'healthy'."""
    result = subprocess.run(
        "podman inspect --format '{{.State.Health.Status}}' armory-postgres",
        shell=True, capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "healthy"


def test_dynamic_credentials_issued(postgres_env, vault_client):
    """Vault issues non-empty username and password for the app role."""
    response = vault_client.secrets.database.generate_credentials(name="app")
    assert response["data"]["username"]
    assert response["data"]["password"]
    assert response["lease_duration"] > 0


def test_dynamic_credentials_connect_to_postgres(postgres_env, vault_client):
    """Dynamic credentials returned by Vault can actually connect to Postgres."""
    response = vault_client.secrets.database.generate_credentials(name="app")
    creds = response["data"]

    conn = psycopg2.connect(
        host="127.0.0.1",
        port=5432,
        dbname="app",
        user=creds["username"],
        password=creds["password"],
        sslmode="verify-full",
        sslrootcert=PKI_CA_BUNDLE,
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user")
            row = cur.fetchone()
        assert row[0] == creds["username"]
    finally:
        conn.close()


def test_two_dynamic_credentials_are_distinct(postgres_env, vault_client):
    """Vault never replays credentials — two issuances must produce different usernames."""
    first  = vault_client.secrets.database.generate_credentials(name="app")
    second = vault_client.secrets.database.generate_credentials(name="app")
    assert first["data"]["username"] != second["data"]["username"]


def test_keycloak_static_role_readable(postgres_env, vault_client):
    """The keycloak static role must return a non-empty password (static role wired up)."""
    response = vault_client.secrets.database.get_static_credentials(name="keycloak")
    assert response["data"]["password"]
