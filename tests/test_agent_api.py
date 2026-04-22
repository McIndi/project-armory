"""
Tests for the agent API — both HTTP contract tests (no infrastructure) and
a direct integration test of run_task() (requires Vault + Postgres).

Contract tests use FastAPI TestClient with dependency overrides so they don't
need a running Vault or Keycloak. They verify the HTTP layer: routing, auth
rejection, Pydantic validation, and response structure.

The run_task integration test calls the function directly, bypassing the HTTP
and OIDC layers — this exercises the full Vault AppRole auth → DB credential
issuance → query execution path.
"""

import os
import sys

import pytest

# Several agent modules read env vars at import time — set all required defaults
# before any import of api/oidc/vault_client/tools.
_ARMORY_BASE_DIR = os.environ.get("ARMORY_BASE_DIR", "/opt/armory")
os.environ.setdefault("KEYCLOAK_URL",   "https://127.0.0.1:8444")
os.environ.setdefault("ARMORY_CACERT",  f"{_ARMORY_BASE_DIR}/vault/tls/ca.crt")
os.environ.setdefault("OIDC_CLIENT_ID", "agent-cli")
os.environ.setdefault("VAULT_ADDR",     "https://127.0.0.1:8200")
os.environ.setdefault("APPROLE_DIR",    f"{_ARMORY_BASE_DIR}/agent/approle")
os.environ.setdefault("POSTGRES_HOST",  "armory-postgres")
os.environ.setdefault("POSTGRES_DB",    "app")

# Make agent package importable
from pathlib import Path as _Path
_AGENT_DIR = str(_Path(__file__).parent.parent / "services" / "agent" / "agent")
if _AGENT_DIR not in sys.path:
    sys.path.insert(0, _AGENT_DIR)


# ---------------------------------------------------------------------------
# HTTP contract tests (no infrastructure required)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def test_client():
    from fastapi.testclient import TestClient
    import api as api_module
    from oidc import validate_token

    fake_operator = {
        "sub": "test-sub",
        "preferred_username": "test-operator",
        "groups": ["vault-operators"],
    }
    api_module.app.dependency_overrides[validate_token] = lambda: fake_operator

    with TestClient(api_module.app, raise_server_exceptions=False) as client:
        yield client

    api_module.app.dependency_overrides.clear()


def test_health_returns_200(test_client):
    """GET /health must return 200 with status ok."""
    r = test_client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_missing_bearer_token_returns_403(test_client):
    """POST /task without Authorization header must be rejected."""
    # Remove override so real validate_token runs (which will reject missing token)
    from fastapi.testclient import TestClient
    import api as api_module
    from oidc import validate_token

    api_module.app.dependency_overrides.clear()
    try:
        with TestClient(api_module.app, raise_server_exceptions=False) as client:
            r = client.post("/task", json={"type": "db_query", "query": "SELECT 1"})
        assert r.status_code in (401, 403)
    finally:
        fake_operator = {
            "sub": "test-sub",
            "preferred_username": "test-operator",
            "groups": ["vault-operators"],
        }
        api_module.app.dependency_overrides[validate_token] = lambda: fake_operator


def test_non_select_query_returns_422(test_client):
    """Pydantic must reject non-SELECT queries before auth is even checked."""
    r = test_client.post(
        "/task",
        json={"type": "db_query", "query": "DROP TABLE users"},
    )
    assert r.status_code == 422


def test_unknown_task_type_returns_error(test_client, monkeypatch):
    """Unknown task types must return a response with status 'error'."""
    import agent as agent_module

    def _fake_run_task(task, operator):
        return {"status": "error", "request_id": "x", "message": f"Unknown task type: {task['type']}"}

    monkeypatch.setattr(agent_module, "run_task", _fake_run_task, raising=False)

    # Patch at api level since api.py imports run_task directly
    import api as api_module
    monkeypatch.setattr(api_module, "run_task", _fake_run_task)

    r = test_client.post("/task", json={"type": "totally_unknown"})
    assert r.json()["status"] == "error"


# ---------------------------------------------------------------------------
# Integration test — run_task() directly (requires Vault + Postgres)
# ---------------------------------------------------------------------------

def test_run_task_executes_db_query(agent_env, postgres_env, vault_client):
    """run_task() must return status ok with non-empty results for a SELECT query.

    Issues a fresh wrapped secret_id before the call — the agent_client fixture
    in test_agent.py may have consumed the one written by agent_env.
    """
    from pathlib import Path

    approle_dir = agent_env["approle_dir"]

    # Issue a fresh wrapped secret_id — single-use, may already be consumed
    response = vault_client.auth.approle.generate_secret_id(
        role_name="agent",
        wrap_ttl="10m",
    )
    wrap_token = response["wrap_info"]["token"]
    wrap_path  = Path(f"{approle_dir}/wrapped_secret_id")
    wrap_path.chmod(0o644)  # make writable before overwriting
    wrap_path.write_text(wrap_token)
    wrap_path.chmod(0o444)

    from pathlib import Path as _Path
    _pki_bundle = str(_Path(__file__).parent.parent / "vault" / "ca-bundle.pem")

    os.environ["VAULT_ADDR"]    = agent_env["vault_addr"]
    os.environ["ARMORY_CACERT"] = agent_env["vault_cacert"]
    os.environ["APPROLE_DIR"]   = approle_dir
    # Use 127.0.0.1 — "armory-postgres" resolves only inside containers.
    # Port 5432 is mapped to 127.0.0.1:5432 on the host.
    os.environ["POSTGRES_HOST"] = "127.0.0.1"
    os.environ["POSTGRES_DB"]   = "app"
    # tools.py uses ARMORY_CACERT to verify postgres TLS. On the host the
    # postgres cert is signed by pki_int, not the Vault TLS CA.
    os.environ["POSTGRES_CACERT"] = _pki_bundle

    import importlib
    import tools
    import vault_client as vc_module
    import agent as agent_module
    importlib.reload(tools)
    importlib.reload(vc_module)
    importlib.reload(agent_module)

    operator = {"sub": "test-sub", "preferred_username": "test-operator"}
    task     = {"type": "db_query", "query": "SELECT current_user, now() AS ts"}

    result = agent_module.run_task(task, operator)

    assert result["status"] == "ok", f"run_task failed: {result.get('message')}"
    assert "request_id" in result
    assert len(result["results"]) > 0
