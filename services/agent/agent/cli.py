#!/usr/bin/env python3
"""
Agent CLI — submit a task to the Armory Agent API.

Authenticates the operator via Authorization Code + PKCE (RFC 7636):
the browser handles Keycloak login entirely; this script only ever sees an
authorization code and exchanges it for a token without a client secret.

Usage:
    python cli.py --query "SELECT current_user, now() AS ts"

Required environment variables:
    KEYCLOAK_URL    Base URL of the Keycloak server (e.g. https://127.0.0.1:8444)
    ARMORY_CACERT   Path to the Armory CA cert (used for Keycloak TLS verification)

Optional environment variables:
    KEYCLOAK_REALM  Realm name (default: armory)
    OIDC_CLIENT_ID  Public client ID registered in Keycloak (default: agent-cli)
    AGENT_API_URL   Agent API base URL (default: http://127.0.0.1:8000)
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import urllib.parse
import webbrowser

import httpx

KEYCLOAK_URL   = os.environ["KEYCLOAK_URL"]
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "armory")
ARMORY_CACERT  = os.environ["ARMORY_CACERT"]
OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID", "agent-cli")
AGENT_API_URL  = os.environ.get("AGENT_API_URL", "http://127.0.0.1:8000")

_CALLBACK_PORT = 18080
_CALLBACK_PATH = "/callback"
_REDIRECT_URI  = f"http://127.0.0.1:{_CALLBACK_PORT}{_CALLBACK_PATH}"

_TOKEN_URL = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
_AUTH_URL  = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/auth"


def _pkce_pair() -> tuple[str, str]:
    """Return (code_verifier, code_challenge) using S256."""
    verifier  = secrets.token_urlsafe(96)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


def _get_authorization_code() -> tuple[str, str]:
    """
    Open the browser to Keycloak's login page, start a one-shot local callback
    server on 127.0.0.1:18080, and return (authorization_code, code_verifier).

    The server handles exactly one request then exits. If the operator does not
    complete login within 120 seconds, TimeoutError is raised.
    """
    verifier, challenge = _pkce_pair()
    state    = secrets.token_urlsafe(16)
    received: dict = {}

    class _CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != _CALLBACK_PATH:
                self.send_response(404)
                self.end_headers()
                return

            params = urllib.parse.parse_qs(parsed.query)

            if params.get("state", [""])[0] != state:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"State mismatch. Close this tab and try again.")
                return

            if "error" in params:
                received["error"]             = params["error"][0]
                received["error_description"] = params.get("error_description", ["unknown"])[0]
            else:
                received["code"] = params.get("code", [""])[0]

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Authentication complete. You may close this tab.")

        def log_message(self, *args):
            pass  # suppress server access log

    server = http.server.HTTPServer(("127.0.0.1", _CALLBACK_PORT), _CallbackHandler)
    thread = threading.Thread(target=server.handle_request)
    thread.daemon = True
    thread.start()

    auth_url = _AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id":             OIDC_CLIENT_ID,
        "response_type":         "code",
        "redirect_uri":          _REDIRECT_URI,
        "scope":                 "openid",
        "state":                 state,
        "code_challenge":        challenge,
        "code_challenge_method": "S256",
    })

    print("Opening browser for Keycloak login...", file=sys.stderr)
    webbrowser.open(auth_url)

    thread.join(timeout=120)

    if "error" in received:
        raise RuntimeError(
            f"Keycloak returned an error: {received['error']} — {received['error_description']}"
        )
    if "code" not in received:
        raise TimeoutError("Login timed out — no authorization code received within 120 seconds")

    return received["code"], verifier


def _exchange_code(code: str, verifier: str) -> str:
    """Exchange the authorization code and PKCE verifier for an access token."""
    response = httpx.post(
        _TOKEN_URL,
        data={
            "grant_type":    "authorization_code",
            "client_id":     OIDC_CLIENT_ID,
            "code":          code,
            "redirect_uri":  _REDIRECT_URI,
            "code_verifier": verifier,
        },
        verify=ARMORY_CACERT,
        timeout=15,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def _submit_task(token: str, query: str) -> dict:
    """Submit a db_query task to the agent API and return the parsed response."""
    response = httpx.post(
        f"{AGENT_API_URL}/task",
        json={"type": "db_query", "query": query},
        headers={"Authorization": f"Bearer {token}"},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()


def main():
    parser = argparse.ArgumentParser(
        description="Submit a task to the Armory Agent API via Keycloak PKCE login."
    )
    parser.add_argument("--query", required=True, help="SQL SELECT query to execute")
    args = parser.parse_args()

    code, verifier = _get_authorization_code()
    token  = _exchange_code(code, verifier)
    result = _submit_task(token, args.query)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
