"""
Fast unit tests for the agent service — no infrastructure required.

Covers:
  - tools.py SELECT guard (allowed, rejected, case-insensitive)
  - cli.py PKCE pair generation (length, S256 challenge, uniqueness)
"""

import base64
import hashlib
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Provide minimal env vars that modules read at import time
os.environ.setdefault("KEYCLOAK_URL",   "https://127.0.0.1:8444")
os.environ.setdefault("ARMORY_CACERT",  "/dev/null")
os.environ.setdefault("OIDC_CLIENT_ID", "agent-cli")
os.environ.setdefault("POSTGRES_HOST",  "localhost")
os.environ.setdefault("POSTGRES_DB",    "app")

_AGENT_DIR = str(Path(__file__).parent.parent / "services" / "agent" / "agent")
if _AGENT_DIR not in sys.path:
    sys.path.insert(0, _AGENT_DIR)


# ---------------------------------------------------------------------------
# tools.py — SELECT guard
# ---------------------------------------------------------------------------

def _make_mock_conn():
    col_desc = MagicMock()
    col_desc.__getitem__ = MagicMock(return_value="current_user")

    cur = MagicMock()
    cur.__enter__ = lambda s: s
    cur.__exit__  = MagicMock(return_value=False)
    cur.description = [col_desc]
    cur.fetchall.return_value = [("test_user",)]

    conn = MagicMock()
    conn.cursor.return_value = cur
    return conn


def test_select_is_allowed():
    """SELECT queries must not raise."""
    import tools
    creds = {"username": "u", "password": "p"}
    with patch("psycopg2.connect") as mock_connect:
        mock_connect.return_value = _make_mock_conn()
        result = tools.query_database(creds, "SELECT current_user")
    assert isinstance(result, list)


def test_non_select_raises():
    """Non-SELECT queries must raise ValueError before any DB connection is made."""
    import tools
    creds = {"username": "u", "password": "p"}
    with pytest.raises(ValueError, match="Only SELECT"):
        tools.query_database(creds, "DROP TABLE users")


def test_select_case_insensitive():
    """Lowercase 'select' must be accepted."""
    import tools
    creds = {"username": "u", "password": "p"}
    with patch("psycopg2.connect") as mock_connect:
        mock_connect.return_value = _make_mock_conn()
        result = tools.query_database(creds, "select current_user")
    assert isinstance(result, list)


# ---------------------------------------------------------------------------
# cli.py — PKCE pair generation
# ---------------------------------------------------------------------------

def test_pkce_verifier_length():
    """secrets.token_urlsafe(96) encodes to 128 URL-safe characters."""
    import cli
    verifier, _ = cli._pkce_pair()
    # token_urlsafe(96) → 96 bytes → 128 base64url chars (no padding)
    assert len(verifier) == 128


def test_pkce_challenge_is_s256():
    """Challenge must equal BASE64URL(SHA256(verifier)) with no padding."""
    import cli
    verifier, challenge = cli._pkce_pair()
    expected = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        .rstrip(b"=")
        .decode()
    )
    assert challenge == expected


def test_pkce_pairs_are_unique():
    """Two calls must return different verifiers."""
    import cli
    v1, _ = cli._pkce_pair()
    v2, _ = cli._pkce_pair()
    assert v1 != v2
