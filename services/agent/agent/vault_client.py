import os
import hvac
import structlog

log = structlog.get_logger()

VAULT_ADDR    = os.environ["VAULT_ADDR"]
ARMORY_CACERT = os.environ["ARMORY_CACERT"]
APPROLE_DIR   = os.environ["APPROLE_DIR"]


def _load_approle_credentials() -> tuple[str, str]:
    with open(os.path.join(APPROLE_DIR, "role_id")) as f:
        role_id = f.read().strip()
    with open(os.path.join(APPROLE_DIR, "wrapped_secret_id")) as f:
        wrapped_secret_id = f.read().strip()
    return role_id, wrapped_secret_id


def authenticate() -> hvac.Client:
    """
    Authenticate to Vault via AppRole.

    1. Open an unauthenticated client (TLS verified against Armory CA)
    2. Unwrap the response-wrapped secret_id — single-use, consumed atomically
    3. Login with role_id + unwrapped secret_id
    4. Return an authenticated client

    The Vault audit log records both the unwrap and the login,
    including the token accessor issued to this agent instance.
    """
    log.info("vault.auth.start", vault_addr=VAULT_ADDR)

    role_id, wrapped_secret_id = _load_approle_credentials()

    # The wrapping token IS the auth token for /sys/wrapping/unwrap.
    # Passing it in the body with an unauthenticated client is rejected (403).
    wrap_client = hvac.Client(url=VAULT_ADDR, token=wrapped_secret_id, verify=ARMORY_CACERT)

    log.info("vault.auth.unwrap_secret_id")
    unwrap_response = wrap_client.sys.unwrap()
    secret_id = unwrap_response["data"]["secret_id"]

    client = hvac.Client(url=VAULT_ADDR, verify=ARMORY_CACERT)

    log.info("vault.auth.approle_login")
    login_response = client.auth.approle.login(
        role_id=role_id,
        secret_id=secret_id,
    )

    client.token = login_response["auth"]["client_token"]

    log.info(
        "vault.auth.success",
        accessor=login_response["auth"]["accessor"],
        policies=login_response["auth"]["policies"],
        token_ttl=login_response["auth"]["lease_duration"],
    )
    return client


def get_dynamic_db_credentials(client: hvac.Client) -> dict:
    """
    Fetch short-lived dynamic credentials for the app database.

    Vault creates a temporary PostgreSQL role valid for the lease TTL
    defined in vault-config/database.tf (default: 3600s). The role is
    automatically revoked by Vault when the lease expires.
    """
    log.info("vault.db_creds.request", role="app")
    response = client.secrets.database.generate_credentials(name="app")
    creds = {
        "username":       response["data"]["username"],
        "password":       response["data"]["password"],
        "lease_id":       response["lease_id"],
        "lease_duration": response["lease_duration"],
    }
    log.info(
        "vault.db_creds.issued",
        username=creds["username"],
        lease_id=creds["lease_id"],
        ttl=creds["lease_duration"],
    )
    return creds


def revoke_token(client: hvac.Client) -> None:
    """
    Revoke the agent's Vault token on task completion.

    Explicit revocation closes the token's access window immediately and
    appears in the Vault audit log, making the task lifecycle boundary clear.
    Called unconditionally from the finally block in agent.py — exceptions
    are caught and logged here so the caller always completes cleanly.
    """
    log.info("vault.token.revoke_self")
    try:
        client.auth.token.revoke_self()
        log.info("vault.token.revoked")
    except Exception as e:
        log.error("vault.token.revoke_failed", error=str(e))
