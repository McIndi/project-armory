"""
Integration tests for the agent AppRole policy and credential lifecycle.

These tests verify the security properties of the agent's Vault identity:
- The policy grants exactly the paths it should (DB creds) and nothing else.
- Dynamic DB credentials are issued with a non-zero lease duration.
- The Vault token is revocable by the agent itself (lifecycle boundary closes).

Prerequisites:
  - vault_env fixture (vault + vault-config applied with agent_enabled=true)
  - agent_env fixture (services/agent/ applied, credentials on disk)
"""

import pytest
import hvac


@pytest.fixture(scope="module")
def agent_client(agent_env, vault_client):
    """Authenticated hvac client using the agent AppRole credentials.

    Issues a fresh wrapped secret_id via the root vault_client — the running
    vault-agent sidecar consumes the token written to disk (single-use,
    remove_after_reading), so reading from disk would race with the agent.
    """
    approle_dir  = agent_env["approle_dir"]
    vault_addr   = agent_env["vault_addr"]
    vault_cacert = agent_env["vault_cacert"]

    role_id = open(f"{approle_dir}/role_id").read().strip()

    response = vault_client.auth.approle.generate_secret_id(
        role_name="agent",
        wrap_ttl="10m",
    )
    wrapped_token = response["wrap_info"]["token"]

    unwrapped = vault_client.sys.unwrap(token=wrapped_token)
    secret_id = unwrapped["data"]["secret_id"]

    client = hvac.Client(url=vault_addr, verify=vault_cacert)

    login = client.auth.approle.login(role_id=role_id, secret_id=secret_id)
    client.token = login["auth"]["client_token"]
    return client


def test_agent_policy_grants_dynamic_db_creds(agent_client):
    """Policy allows reading dynamic credentials from database/creds/app."""
    response = agent_client.secrets.database.generate_credentials(name="app")
    assert response["data"]["username"]
    assert response["data"]["password"]
    assert response["lease_duration"] > 0


def test_agent_policy_blocks_keycloak_db_role(agent_client):
    """Policy must not grant access to the keycloak static role."""
    with pytest.raises(hvac.exceptions.Forbidden):
        agent_client.secrets.database.generate_credentials(name="keycloak")


def test_agent_policy_blocks_pki_issuance(agent_client):
    """Policy must not grant PKI certificate issuance."""
    with pytest.raises(hvac.exceptions.Forbidden):
        agent_client.secrets.pki.generate_certificate(
            name="armory-server",
            common_name="agent.armory.internal",
            mount_point="pki_int",
        )


def test_agent_token_revoke_self(agent_client):
    """Agent can revoke its own token; subsequent lookup must raise Forbidden."""
    agent_client.auth.token.revoke_self()
    with pytest.raises(hvac.exceptions.Forbidden):
        agent_client.auth.token.lookup_self()
