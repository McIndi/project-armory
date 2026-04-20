"""
Tests that the Vault audit log records the operations we care about.

The audit log accumulates across the session — entries from earlier fixtures
are present when these tests run. Tests parse the full log at assertion time
and filter for the relevant entries.

Prerequisites:
  - postgres_env fixture (dynamic DB credentials have been issued by the time
    test_postgres.py runs, so the audit log contains those entries)
"""

import json
import subprocess

import pytest

AUDIT_LOG_CONTAINER_PATH = "/vault/logs/audit.log"


def _load_audit_entries():
    """Return all parseable JSON entries from the audit log via podman exec."""
    result = subprocess.run(
        f"podman exec armory-vault cat {AUDIT_LOG_CONTAINER_PATH}",
        shell=True, capture_output=True, text=True,
    )
    entries = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return entries


def test_audit_log_exists_and_is_nonempty(postgres_env):
    """Audit log must exist inside the vault container and contain at least one entry."""
    result = subprocess.run(
        f"podman exec armory-vault test -s {AUDIT_LOG_CONTAINER_PATH}",
        shell=True,
    )
    assert result.returncode == 0, f"Audit log missing or empty at {AUDIT_LOG_CONTAINER_PATH}"


def test_audit_log_records_db_credential_issuance(postgres_env, vault_client):
    """Audit log must contain a response entry for database/creds/app."""
    # Ensure at least one issuance has occurred in this session
    vault_client.secrets.database.generate_credentials(name="app")

    entries = _load_audit_entries()
    matches = [
        e for e in entries
        if e.get("type") == "response"
        and e.get("request", {}).get("path") == "database/creds/app"
    ]
    assert matches, "No audit entry found for database/creds/app issuance"


def test_audit_log_records_approle_login(postgres_env):
    """Audit log must contain a response entry for AppRole login."""
    entries = _load_audit_entries()
    matches = [
        e for e in entries
        if e.get("type") == "response"
        and e.get("request", {}).get("path", "").startswith("auth/approle/login")
    ]
    assert matches, "No audit entry found for AppRole login"
