import os
import threading
import hvac
import structlog

log = structlog.get_logger()

VAULT_ADDR    = os.environ["VAULT_ADDR"]
VAULT_CACERT  = os.environ.get("VAULT_CACERT", os.environ.get("ARMORY_CACERT", ""))
APPROLE_DIR   = os.environ["APPROLE_DIR"]

_RENEW_THRESHOLD_SECONDS = 120
_runtime_client: hvac.Client | None = None
_runtime_lock = threading.Lock()


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
    log.info("vault.auth.start", vault_addr=VAULT_ADDR, vault_cacert=VAULT_CACERT)

    if not VAULT_CACERT:
        raise RuntimeError("VAULT_CACERT is not set (and ARMORY_CACERT fallback is empty)")
    if not os.path.exists(VAULT_CACERT):
        raise RuntimeError(f"Vault CA file does not exist: {VAULT_CACERT}")

    role_id, wrapped_secret_id = _load_approle_credentials()

    # The wrapping token IS the auth token for /sys/wrapping/unwrap.
    # Passing it in the body with an unauthenticated client is rejected (403).
    wrap_client = hvac.Client(url=VAULT_ADDR, token=wrapped_secret_id, verify=VAULT_CACERT)

    log.info("vault.auth.unwrap_secret_id")
    unwrap_response = wrap_client.sys.unwrap()
    secret_id = unwrap_response["data"]["secret_id"]

    client = hvac.Client(url=VAULT_ADDR, verify=VAULT_CACERT)

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


def initialize_runtime_client() -> hvac.Client:
    """
    Authenticate once per API process and cache the resulting client.

    This consumes wrapped_secret_id exactly once on startup. Subsequent task
    executions reuse the authenticated client token.
    """
    global _runtime_client

    with _runtime_lock:
        if _runtime_client is not None:
            return _runtime_client

        _runtime_client = authenticate()
        return _runtime_client


def _renew_runtime_client_if_needed(client: hvac.Client) -> None:
    """
    Renew the cached token only when the remaining TTL is low.

    If the token is no longer renewable, we allow downstream calls to fail with
    a clear Vault error rather than masking the failure.
    """
    info = client.auth.token.lookup_self()
    ttl = int(info["data"].get("ttl", 0))
    renewable = bool(info["data"].get("renewable", False))

    if ttl > _RENEW_THRESHOLD_SECONDS:
        return

    if not renewable:
        log.warning("vault.token.not_renewable", ttl=ttl)
        raise RuntimeError(
            "Vault runtime token is not renewable and is near expiry; "
            "restart the API with a fresh wrapped_secret_id"
        )

    log.info("vault.token.renew_self", ttl=ttl)
    renewed = client.auth.token.renew_self()
    renewed_ttl = int(renewed["auth"].get("lease_duration", 0))
    log.info("vault.token.renewed", ttl=renewed_ttl)


def get_runtime_client() -> hvac.Client:
    """Return the cached runtime client, renewing token when needed."""
    with _runtime_lock:
        if _runtime_client is None:
            raise RuntimeError("Vault runtime client is not initialized")

        _renew_runtime_client_if_needed(_runtime_client)
        return _runtime_client


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


def shutdown_runtime_client() -> None:
    """Revoke and clear the cached runtime token on API shutdown."""
    global _runtime_client

    with _runtime_lock:
        if _runtime_client is None:
            return

        revoke_token(_runtime_client)
        _runtime_client = None
