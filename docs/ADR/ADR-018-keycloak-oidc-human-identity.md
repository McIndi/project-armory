# ADR-018: Keycloak for Human Identity and Vault OIDC Auth Method

**Status:** Accepted

---

## Context

Two distinct identity problems emerged as the platform grew:

1. **Web application users** — humans who log in to a web application, need sessions,
   passwords, and potentially multi-factor authentication. They should not need to know
   that Vault exists.
2. **Infrastructure operators** — engineers who authenticate directly to Vault to inspect
   secrets, read PKI state, or rotate credentials.

The initial deployment used Vault's `userpass` auth method for the operator account.
Userpass is appropriate for the operator case, but it is entirely wrong for web
application users:

- Each userpass account requires explicit Vault API calls to create, update, and delete.
  Managing application users this way conflates infrastructure identity management with
  application identity management.
- Vault sessions are short-lived tokens scoped to Vault capabilities. Web sessions are
  longer-lived, stateful, and require logout, "remember me", and MFA concepts that
  Vault has no native support for.
- Vault is not an identity provider; it is a secrets broker. Asking Vault to serve as
  the login system for a web application inverts the correct architecture.

### Keycloak as the identity provider

Keycloak is an open-source Identity and Access Management server. It speaks OIDC
(OpenID Connect) and SAML, manages user sessions, supports MFA and social login,
and provides an admin console for user management. It is the standard choice for
self-hosted identity infrastructure.

For this project, Keycloak serves two roles:
- **Outward-facing:** OIDC provider for web application users.
- **Inward-facing:** OIDC identity provider that Vault trusts for operator login.

### Vault OIDC auth method

Vault's JWT/OIDC auth method allows Vault to accept tokens issued by a trusted external
OIDC provider. An operator authenticates to Keycloak, receives an OIDC token, and
presents it to Vault. Vault verifies the token against Keycloak's discovery endpoint,
maps claims (group membership) to Vault policies, and issues a Vault token.

This replaces the operator's userpass credential with their Keycloak identity. The
operator never needs a Vault-specific password; their Keycloak session is the credential.

### Keycloak itself needs Vault

Keycloak requires:
- A TLS certificate (from Vault PKI, via Vault Agent).
- A PostgreSQL password (from Vault Database secrets engine static role, via Vault Agent).
- An admin bootstrap password (from Vault KV v2, via Vault Agent).

Keycloak is both a Vault **consumer** (it needs Vault-managed credentials) and a Vault
**identity provider** (Vault trusts it for operator login). This circular-looking
dependency resolves cleanly in practice: Keycloak is deployed and obtains its credentials
from Vault before it begins issuing tokens, and Vault's OIDC auth method is configured
only after Keycloak is running.

### Vault Agent sidecar pattern for Keycloak

Keycloak is deployed with the same Vault Agent sidecar pattern established in ADR-016
and ADR-009, but with three rendered artifacts instead of one:

1. `/vault/certs/keycloak.pem` — combined TLS PEM (cert + CA chain + key), from the
   `pki_ext` intermediate CA via `pkiCert` template function.
2. `/vault/secrets/keycloak.env` — env file containing `KC_DB_PASSWORD`, rendered from
   `database/static-creds/keycloak` (Database secrets engine static role).
3. `/vault/secrets/keycloak-admin.env` — env file containing bootstrap admin credentials,
   rendered from `kv/data/keycloak/admin` (KV v2).

Keycloak's Quarkus-based runtime accepts both `--https-certificate-file` and
`--https-certificate-key-file` pointing to the same combined PEM file. Quarkus reads
certificate blocks from the cert path and private key blocks from the key path,
so a single combined bundle satisfies both without requiring two separate template stanzas
that would issue two independent (non-matching) certificates.

### Combined Vault Agent healthcheck

The vault-agent container healthcheck for the Keycloak sidecar validates both credential
types before signalling healthy:

```sh
test -f /vault/certs/keycloak.pem &&
grep -q 'BEGIN CERTIFICATE' /vault/certs/keycloak.pem &&
test -s /vault/secrets/keycloak.env
```

Keycloak's `depends_on: condition: service_healthy` ensures it does not start until both
the TLS cert and the DB credentials file are present and non-empty.

### Transition from userpass to OIDC

The `userpass_enabled` and `oidc_enabled` variables in `vault-config/` allow a
controlled migration ceremony:

1. Both methods coexist during the transition window (`userpass_enabled=true`,
   `oidc_enabled=true`).
2. The operator verifies OIDC login works: `bao login -method=oidc role=operator`.
3. Only after verified: `tofu apply -var userpass_enabled=false` removes userpass.

This ceremony is mandatory. Destroying userpass before OIDC is verified working
would lock the operator out of Vault.

---

## Decision

- Use **Keycloak** as the OIDC identity provider for both web application users and
  infrastructure operator login.
- Deploy Keycloak in `services/keycloak/` using the existing Vault Agent sidecar pattern.
  The agent handles TLS cert (PKI), DB password (Database engine static role), and admin
  credentials (KV v2) in three template stanzas.
- Configure **Vault OIDC auth method** in `vault-config/oidc.tf` pointing at Keycloak's
  `armory` realm. The operator role maps the `groups` claim to the `operator` Vault policy.
- Gate both OIDC and userpass on feature variables (`oidc_enabled`, `userpass_enabled`)
  to support a safe transition ceremony without lock-out risk.
- Keycloak's TLS uses a single combined PEM file for both `KC_HTTPS_CERTIFICATE_FILE`
  and `KC_HTTPS_CERTIFICATE_KEY_FILE` — same pkiCert-in-one-call approach as the
  webserver, avoiding cert/key mismatch from independent issuances (see ADR-016).

---

## Consequences

- The deployment sequence gains two new phases after webserver: `services/postgres/` then
  `services/keycloak/`, followed by a manual Keycloak realm setup and a final
  `vault-config/` re-apply for OIDC.
- Vault's audit log (`/vault/logs/audit.log`) captures all OIDC login events, database
  credential requests, and KV reads — providing a complete audit trail across all
  credential types from a single log stream.
- The `operator` userpass account should be retired after OIDC is verified. Keeping both
  active is a transient state, not a target state.
- Keycloak bootstrap admin credentials are stored in Vault KV v2. The admin account
  should be converted to a Keycloak-native account (not the bootstrap superuser) after
  initial realm configuration.
- Future application services that need human-facing authentication should integrate with
  Keycloak via OIDC/OAuth2 — they should not interact with Vault's auth methods directly.
  Vault is for machine-to-machine and operator identity; Keycloak is for human identity.
- Adding MFA, social login, or a custom login theme to Keycloak does not require any
  changes to Vault configuration.
