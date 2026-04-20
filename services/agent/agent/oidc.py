import os
import threading
import httpx
import structlog
from cachetools import TTLCache, cached
from authlib.jose import jwt, JsonWebKey
from authlib.jose.errors import JoseError
from fastapi import HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

log = structlog.get_logger()

KEYCLOAK_URL   = os.environ["KEYCLOAK_URL"]
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "armory")
ARMORY_CACERT  = os.environ["ARMORY_CACERT"]
OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID", "agent-cli")
REQUIRED_GROUP = os.environ.get("REQUIRED_GROUP", "vault-operators")

ISSUER   = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}"
JWKS_URL = f"{ISSUER}/protocol/openid-connect/certs"

bearer_scheme = HTTPBearer()

# JWKS cached for 5 minutes. Short enough to pick up Keycloak key rotation,
# long enough to avoid hammering Keycloak on every request.
_jwks_cache = TTLCache(maxsize=1, ttl=300)
_jwks_lock  = threading.Lock()


@cached(cache=_jwks_cache, lock=_jwks_lock)
def _fetch_jwks() -> dict:
    log.info("oidc.jwks.fetch", url=JWKS_URL)
    response = httpx.get(JWKS_URL, verify=ARMORY_CACERT, timeout=10)
    response.raise_for_status()
    jwks = response.json()
    log.info("oidc.jwks.fetched", key_count=len(jwks.get("keys", [])))
    return jwks


def validate_token(
    credentials: HTTPAuthorizationCredentials = Security(bearer_scheme),
) -> dict:
    """
    FastAPI dependency — validates a Keycloak Bearer token.

    Verifies signature, expiry, issuer, authorized party (azp),
    and group membership before accepting the request.
    """
    token = credentials.credentials
    jwks  = _fetch_jwks()

    try:
        key_set = JsonWebKey.import_key_set(jwks)
        claims  = jwt.decode(token, key_set)
        claims.validate()
    except JoseError as e:
        log.warning("oidc.token.invalid", error=str(e))
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    # Issuer check — must be the armory realm
    if claims.get("iss") != ISSUER:
        log.warning("oidc.token.wrong_issuer", iss=claims.get("iss"), expected=ISSUER)
        raise HTTPException(status_code=401, detail="Invalid token issuer")

    # Authorized party check — token must have been issued for the agent-cli client,
    # not some other client registered in the same Keycloak realm.
    if claims.get("azp") != OIDC_CLIENT_ID:
        log.warning(
            "oidc.token.wrong_client",
            azp=claims.get("azp"),
            expected=OIDC_CLIENT_ID,
        )
        raise HTTPException(status_code=401, detail="Token not issued for this client")

    groups = claims.get("groups", [])
    if REQUIRED_GROUP not in groups:
        log.warning(
            "oidc.token.unauthorized",
            sub=claims.get("sub"),
            groups=groups,
            required=REQUIRED_GROUP,
        )
        raise HTTPException(
            status_code=403,
            detail=f"Token does not carry required group: {REQUIRED_GROUP}",
        )

    log.info(
        "oidc.token.valid",
        sub=claims.get("sub"),
        preferred_username=claims.get("preferred_username"),
        groups=groups,
    )
    return dict(claims)
