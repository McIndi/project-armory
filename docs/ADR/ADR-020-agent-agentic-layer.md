# ADR-020: Agentic Layer — Security-First Design

**Status:** Accepted

---

## Context

Project Armory provides secrets management, PKI, and dynamic credential infrastructure.
The next requirement is a thin agentic layer: a service that can act on behalf of a
human operator, executing tasks (initially, database queries) while maintaining
a complete, attributable audit trail from operator identity through to credential
lifecycle.

Three problems had to be solved simultaneously:

1. **Human identity** — How does the agent know *who* initiated a task? Vault tokens
   do not carry human identity. The solution is Keycloak: the operator authenticates
   to Keycloak, receives an OIDC JWT, and presents it to the agent API. The agent
   validates the token independently before accepting any task.

2. **Machine identity** — The agent itself must authenticate to Vault as a named
   service principal, not a human. AppRole is the correct mechanism: the agent holds
   a `role_id` (low-entropy identifier) and a wrapped `secret_id` (high-entropy
   credential, single-use). This is the same pattern used by every other service in
   the stack.

3. **Credential scope** — The agent must receive the minimum credentials required to
   execute the task. For a database query, that means short-lived dynamic credentials
   scoped to the `app` database role — issued fresh per task, revoked (or auto-expired)
   when the task completes.

### Operator token acquisition — Authorization Code + PKCE

The operator must present a Keycloak JWT to the agent API. The question is how
they obtain it.

**Resource Owner Password Credentials (ROPC)** — the operator passes username and
password directly to the token endpoint via curl. This is deprecated in OAuth 2.1
for three reasons: the client sees the raw password, MFA is impossible, and Keycloak's
own login audit does not record the event. ROPC is rejected.

**Device Authorization Grant (RFC 8628)** — the operator receives a `user_code`,
navigates to a verification URL manually, and the CLI polls for the token. Suitable
for truly headless environments. This project runs on a local developer machine with
a browser available, so the additional friction (copy/paste a code, navigate to a
separate URL) is unnecessary.

**Authorization Code + PKCE (RFC 7636)** — the CLI opens the browser directly to
Keycloak's login page; the operator authenticates there; Keycloak redirects to a
one-shot local HTTP server on `127.0.0.1:18080`; the CLI exchanges the authorization
code for a token using a PKCE `code_verifier` instead of a client secret. This is
the current best practice for interactive CLI tools. The operator's password never
leaves Keycloak. MFA is supported transparently. Chosen.

**Separate `agent-cli` public client** — the existing `vault` client is a confidential
client used by Vault's OIDC auth method (server-to-server). Reusing it for the CLI
would require distributing the client secret with the tool, which defeats the purpose
of PKCE. A separate public client `agent-cli` has no secret. Direct Access Grants
(ROPC) are explicitly disabled on `agent-cli` at the Keycloak level, enforcing the
correct flow at the server.

The `azp` (authorized party) check in `oidc.py` validates that tokens were issued
for `agent-cli` specifically — preventing substitution of tokens from other clients
in the same realm.

### JWT validation library choice

The initial plan used `python-jose` for JWT validation. `python-jose` has known CVEs
related to algorithm confusion attacks and is no longer actively maintained. For a
service where JWT validation is the primary security gate, this is unacceptable.

`authlib` is the replacement. It is actively maintained, has a clean security track
record, and supports the same RS256 validation surface. See also: the `cachetools`
decision below.

### JWKS caching

Keycloak serves its public keys at a JWKS endpoint. Fetching keys on every request
is wasteful; caching them for the process lifetime (`lru_cache`) is dangerous — if
Keycloak rotates its signing keys (on realm reset or key expiry), the agent would
continue validating against stale keys until restarted.

A TTL-bounded cache (5-minute TTL via `cachetools.TTLCache`) balances these concerns:
key rotation is picked up within 5 minutes, and Keycloak is not hammered on every
request.

### Audience verification

JWT audience verification (`aud` claim) was initially disabled (`verify_aud: False`).
Without audience verification, any valid Keycloak token for the `armory` realm —
issued for *any* client, not just the `vault` client — would be accepted by the
agent API.

The fix is to verify the `azp` (authorized party) claim instead of `aud`. Keycloak
always sets `azp` to the client ID that requested the token. Checking `azp == "vault"`
ensures only tokens explicitly issued for the Vault/agent client are accepted, even if
the realm has other OIDC clients registered.

### AppRole ownership boundary

`vault_approle_auth_backend_role_secret_id` must be owned by exactly one Terraform
state file. The AppRole *role* is created in `vault-config/auth.tf` (alongside all
other AppRole roles). The wrapped secret_id is issued and written to disk by
`services/agent/main.tf` — the same pattern used by `services/webserver/` and
`services/keycloak/`.

If `vault-config/` also created a `vault_approle_auth_backend_role_secret_id` resource
for the agent, every `tofu apply` of `vault-config/` would issue a new wrapped token
and silently invalidate the one on disk. Two state files must not own the same
Vault resource.

### Blocking I/O and the asyncio event loop

FastAPI endpoints declared `async def` run on the asyncio event loop. Vault
authentication (HTTP), database credential issuance (HTTP), and database queries
(TCP + TLS) are all blocking I/O. Calling blocking code from an `async def` handler
blocks the entire event loop for the duration of the task.

The fix is to declare `submit_task` as a plain `def` function. FastAPI detects this
and runs the handler in a thread pool (via `run_in_executor`), keeping the event loop
free for other requests.

### Request correlation

The operator submits a task; the agent authenticates to Vault; Vault issues a DB
credential; the agent executes a query. These events appear in two separate log streams:
the agent's structured application log and the Vault audit log. Without a correlation
token, there is no way to link a specific API request to its Vault audit entries.

A UUID4 `request_id` is generated at the start of each `run_task` invocation, bound to
the structlog context (so it appears in every log entry for that task), and returned in
the API response. The operator can take the `request_id` from the response and find all
matching entries in both log streams.

### SQL validation

The agent accepts a query string from the operator over HTTP. The Vault-issued database
role carries only read grants (defined in `services/postgres/templates/init.sql.tpl`),
so write operations would fail at the database layer regardless. However, rejecting
non-SELECT queries at the application layer is an explicit statement of intent — it
prevents accidental writes if the database grants ever widen, and keeps the API's
contract clear.

---

## Decision

- Build the agent as a Python FastAPI service in `services/agent/agent/`.
- Operator token acquisition uses **Authorization Code + PKCE** (`cli.py`). ROPC is
  rejected (deprecated, exposes password to client, blocks MFA). Device Authorization
  Grant was considered but rejected (unnecessary friction on a local machine with a
  browser). A separate public Keycloak client **`agent-cli`** is created with Direct
  Access Grants disabled — ROPC is blocked at the server, not just the client.
- Use **`authlib`** for JWT validation (replaces `python-jose`).
- Use a **5-minute TTL JWKS cache** (`cachetools.TTLCache`), thread-safe.
- Validate the **`azp` claim** against `OIDC_CLIENT_ID` to reject tokens issued for
  other clients in the same Keycloak realm.
- The `submit_task` FastAPI endpoint is declared **`def`** (not `async def`) so
  FastAPI routes it to a thread pool.
- Generate a **UUID4 `request_id`** per task invocation; bind it to structlog context
  and return it in the response.
- Enforce **SELECT-only** queries at both the Pydantic model layer and in `tools.py`.
- The `vault_approle_auth_backend_role` resource lives in `vault-config/auth.tf`;
  the `vault_approle_auth_backend_role_secret_id` resource lives in
  `services/agent/main.tf` only — no cross-state ownership.
- Rename the CA cert environment variable from `VAULT_CACERT` to `ARMORY_CACERT`
  throughout the agent service — the same CA signs Vault, Keycloak, and Postgres TLS,
  and a provider-neutral name avoids confusion.

---

## Consequences

- The deployment sequence gains a new phase (9) after Keycloak is running:
  `vault-config/` re-apply with `agent_enabled=true`, then `services/agent/` apply.
- The wrapped `secret_id` on disk is single-use. After the agent authenticates once,
  `tofu apply` in `services/agent/` must be re-run to issue a new one. This is a
  security property of Vault response-wrapping, not a limitation. Phase 2 will add a
  broker to eliminate this manual step.
- `ARMORY_CACERT` must be set to `/opt/armory/vault/tls/ca.crt` for all three TLS
  verifications (Vault API, Keycloak JWKS, Postgres `sslrootcert`).
- The agent is not containerized in Phase 1 (runs directly on the host). Phase 2 will
  add a `compose.yml.tpl` and join the service to `armory-net` so `armory-postgres`
  resolves natively. Until then, the operator must add a hosts entry or run the agent
  inside a container on `armory-net`.
- Integration tests (`tests/test_agent.py`) require `vault-config/` to be applied
  with `agent_enabled=true` and `services/agent/` to be applied. The `agent_env`
  conftest fixture handles this automatically. The wrapped secret_id is consumed by
  the fixture — re-apply `services/agent/` before running the tests a second time.
