"""
Integration smoke tests for Keycloak realm import and Vault OIDC configuration.

These tests are gated behind the ARMORY_KEYCLOAK_INTEGRATION=1 environment
variable and require a fully running stack (rebuild.sh must have completed,
including Phase 6 and Phase 7).

Run with:
    ARMORY_KEYCLOAK_INTEGRATION=1 pytest tests/test_keycloak.py -v

What these tests verify:
  - Keycloak /health/ready returns HTTP 200 (container is up and started)
  - Keycloak admin API shows the 'armory' realm exists (import succeeded)
  - Vault auth/oidc/config has a discovery_url pointing at the armory realm
  - Vault auth/oidc/role/operator has groups_claim=groups
  - Vault auth/oidc/role/operator allows all three expected redirect URIs
"""

import os
import subprocess

import pytest
import requests
import urllib3

# Suppress TLS warnings for self-signed certs — we pass explicit cacert to
# requests calls that need it; urllib3 InsecureRequestWarning is suppressed only
# for Keycloak calls that use the PKI CA bundle.
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Guard — skip entire module unless explicitly enabled
# ---------------------------------------------------------------------------

INTEGRATION_ENABLED = os.environ.get("ARMORY_KEYCLOAK_INTEGRATION", "").lower() in (
    "1",
    "true",
    "yes",
)

pytestmark = pytest.mark.skipif(
    not INTEGRATION_ENABLED,
    reason="Keycloak integration tests disabled. Set ARMORY_KEYCLOAK_INTEGRATION=1 to enable.",
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ARMORY_BASE_DIR = os.environ.get("ARMORY_BASE_DIR", "/opt/armory")
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "https://127.0.0.1:8444")
VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://127.0.0.1:8200")

# ca-bundle.pem covers pki_ext-issued certs (including Keycloak TLS)
CA_BUNDLE = os.path.join(PROJECT_ROOT, "vault", "ca-bundle.pem")
# Vault's own self-signed TLS CA
VAULT_CACERT = os.path.join(ARMORY_BASE_DIR, "vault", "tls", "ca.crt")

REALM = "armory"
EXPECTED_REDIRECT_URIS = {
    "http://localhost:8250/oidc/callback",
    "https://127.0.0.1:8200/oidc/callback",
    "https://127.0.0.1:8200/ui/vault/auth/oidc/oidc/callback",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _vault_token() -> str:
    """Read the root token from the credentials file saved by rebuild.sh."""
    creds_file = os.path.join(PROJECT_ROOT, "unseal_key-and-root_token.txt")
    if not os.path.isfile(creds_file):
        pytest.skip(f"Vault credentials file not found: {creds_file}")
    with open(creds_file) as f:
        for line in f:
            if "Initial Root Token:" in line:
                return line.split("Initial Root Token:")[-1].strip()
    pytest.skip("Could not parse root token from credentials file")


def _vault_api(path: str, token: str) -> dict:
    """GET a Vault API path and return the parsed JSON response."""
    resp = requests.get(
        f"{VAULT_ADDR}/v1/{path}",
        headers={"X-Vault-Token": token},
        verify=VAULT_CACERT,
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"Vault API GET {path} returned {resp.status_code}: {resp.text}"
    )
    return resp.json()


def _keycloak_admin_token(admin_url: str, admin_user: str, admin_pass: str) -> str:
    """Obtain a Keycloak admin access token from the master realm."""
    resp = requests.post(
        f"{admin_url}/realms/master/protocol/openid-connect/token",
        data={
            "client_id": "admin-cli",
            "username": admin_user,
            "password": admin_pass,
            "grant_type": "password",
        },
        verify=CA_BUNDLE if os.path.isfile(CA_BUNDLE) else False,
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"Keycloak admin token request failed ({resp.status_code}): {resp.text}"
    )
    return resp.json()["access_token"]


def _keycloak_admin_credentials() -> tuple[str, str]:
    """Read Keycloak admin credentials from the vault-agent-rendered env file."""
    env_file = os.path.join(ARMORY_BASE_DIR, "keycloak", "secrets", "keycloak-admin.env")
    if not os.path.isfile(env_file):
        pytest.skip(f"Keycloak admin env file not found: {env_file}")
    creds = {}
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                creds[k.strip()] = v.strip().strip('"')
    user = creds.get("KC_BOOTSTRAP_ADMIN_USERNAME", "")
    pwd = creds.get("KC_BOOTSTRAP_ADMIN_PASSWORD", "")
    if not user or not pwd:
        pytest.skip("Could not parse Keycloak admin credentials from env file")
    return user, pwd


# ---------------------------------------------------------------------------
# Tests — Keycloak health
# ---------------------------------------------------------------------------


def test_keycloak_health_ready():
    """Keycloak /health/ready must return HTTP 200."""
    resp = requests.get(
        f"{KEYCLOAK_URL}/health/ready",
        verify=CA_BUNDLE if os.path.isfile(CA_BUNDLE) else False,
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"Keycloak /health/ready returned {resp.status_code}"
    )


def test_keycloak_armory_realm_exists():
    """The 'armory' realm must exist (realm import JSON was processed)."""
    admin_user, admin_pass = _keycloak_admin_credentials()
    token = _keycloak_admin_token(KEYCLOAK_URL, admin_user, admin_pass)

    resp = requests.get(
        f"{KEYCLOAK_URL}/admin/realms/{REALM}",
        headers={"Authorization": f"Bearer {token}"},
        verify=CA_BUNDLE if os.path.isfile(CA_BUNDLE) else False,
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"Keycloak realm '{REALM}' not found (HTTP {resp.status_code})"
    )
    data = resp.json()
    assert data.get("realm") == REALM, f"Unexpected realm name: {data.get('realm')}"


def test_keycloak_vault_operators_group_exists():
    """The 'vault-operators' group must exist in the armory realm."""
    admin_user, admin_pass = _keycloak_admin_credentials()
    token = _keycloak_admin_token(KEYCLOAK_URL, admin_user, admin_pass)

    resp = requests.get(
        f"{KEYCLOAK_URL}/admin/realms/{REALM}/groups",
        headers={"Authorization": f"Bearer {token}"},
        params={"search": "vault-operators"},
        verify=CA_BUNDLE if os.path.isfile(CA_BUNDLE) else False,
        timeout=10,
    )
    assert resp.status_code == 200
    groups = resp.json()
    names = [g["name"] for g in groups]
    assert "vault-operators" in names, (
        f"Group 'vault-operators' not found in realm '{REALM}'. Found: {names}"
    )


def test_keycloak_vault_client_exists():
    """The 'vault' confidential OIDC client must exist in the armory realm."""
    admin_user, admin_pass = _keycloak_admin_credentials()
    token = _keycloak_admin_token(KEYCLOAK_URL, admin_user, admin_pass)

    resp = requests.get(
        f"{KEYCLOAK_URL}/admin/realms/{REALM}/clients",
        headers={"Authorization": f"Bearer {token}"},
        params={"clientId": "vault"},
        verify=CA_BUNDLE if os.path.isfile(CA_BUNDLE) else False,
        timeout=10,
    )
    assert resp.status_code == 200
    clients = resp.json()
    assert len(clients) == 1, f"Expected one 'vault' client, got: {[c['clientId'] for c in clients]}"
    client = clients[0]
    assert client["publicClient"] is False, "vault client must be confidential (publicClient=false)"


def test_keycloak_agent_cli_client_has_pkce():
    """The 'agent-cli' public OIDC client must have PKCE S256 configured."""
    admin_user, admin_pass = _keycloak_admin_credentials()
    token = _keycloak_admin_token(KEYCLOAK_URL, admin_user, admin_pass)

    resp = requests.get(
        f"{KEYCLOAK_URL}/admin/realms/{REALM}/clients",
        headers={"Authorization": f"Bearer {token}"},
        params={"clientId": "agent-cli"},
        verify=CA_BUNDLE if os.path.isfile(CA_BUNDLE) else False,
        timeout=10,
    )
    assert resp.status_code == 200
    clients = resp.json()
    assert len(clients) == 1, f"Expected one 'agent-cli' client, got: {clients}"
    client = clients[0]
    assert client["publicClient"] is True, "agent-cli client must be public"
    pkce_method = client.get("attributes", {}).get("pkce.code.challenge.method", "")
    assert pkce_method == "S256", (
        f"agent-cli client must have pkce.code.challenge.method=S256, got: '{pkce_method}'"
    )


# ---------------------------------------------------------------------------
# Tests — Vault OIDC configuration
# ---------------------------------------------------------------------------


def test_vault_oidc_backend_discovery_url():
    """Vault OIDC backend discovery URL must point at the armory realm."""
    token = _vault_token()
    data = _vault_api("auth/oidc/config", token)
    discovery_url = data.get("data", {}).get("oidc_discovery_url", "")
    assert f"/realms/{REALM}" in discovery_url, (
        f"OIDC discovery URL does not reference realm '{REALM}': {discovery_url}"
    )


def test_vault_oidc_operator_role_groups_claim():
    """Vault OIDC operator role must use 'groups' as the groups_claim."""
    token = _vault_token()
    data = _vault_api("auth/oidc/role/operator", token)
    groups_claim = data.get("data", {}).get("groups_claim", "")
    assert groups_claim == "groups", (
        f"Vault OIDC operator role groups_claim must be 'groups', got: '{groups_claim}'"
    )


def test_vault_oidc_operator_role_redirect_uris():
    """Vault OIDC operator role must allow all three expected redirect URIs."""
    token = _vault_token()
    data = _vault_api("auth/oidc/role/operator", token)
    allowed = set(data.get("data", {}).get("allowed_redirect_uris", []))
    missing = EXPECTED_REDIRECT_URIS - allowed
    assert not missing, (
        f"Vault OIDC operator role is missing redirect URIs: {missing}\n"
        f"Configured: {allowed}"
    )
