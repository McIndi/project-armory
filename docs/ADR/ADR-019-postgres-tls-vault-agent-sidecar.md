# ADR-019: PostgreSQL TLS via Vault Agent sidecar

**Status:** Accepted

---

## Context

The Vault Database secrets engine connection was initially configured with
`?sslmode=disable` as a temporary workaround to unblock deployment while PostgreSQL
had no TLS configured. Credentials flowing between Vault and PostgreSQL in plaintext
is not acceptable for a security-focused reference architecture.

The standard pattern in this project for TLS certificate issuance and rotation is the
**Vault Agent sidecar** (established in ADR-009, applied in ADR-016 for the webserver
and ADR-018 for Keycloak). PostgreSQL should follow the same pattern.

Two CA choices exist: the external CA (`pki_ext/`) and the internal CA (`pki_int/`).

---

## Decision

Issue the PostgreSQL TLS certificate from the **internal CA** (`pki_int/armory-server`),
not the external CA.

PostgreSQL runs on `armory-net` and is never published to the host or the internet.
Only other containers on `armory-net` (Vault, Keycloak) connect to it. Those services
already trust the internal chain. Using the external CA for an internal-only service
would be unnecessary exposure and inconsistent with the architecture's separation of
trust domains.

The `armory-server` PKI role (`allowed_domains = ["armory.internal"]`,
`allow_subdomains = true`) requires a CN of the form `<name>.armory.internal`. The
PostgreSQL cert CN is `armory-postgres.armory.internal`.

### Agent template design — two stanzas, one certificate

Vault Agent's `pkiCert` function caches the issued certificate by argument fingerprint
within a render cycle. Two `template` stanzas that call `pkiCert` with identical
arguments receive the **same** certificate and key — no second issuance occurs. This
allows writing `postgres.crt` (cert + CA chain) and `postgres.key` (private key) as
separate files with separate permissions, which PostgreSQL requires.

### Key file permissions workaround

PostgreSQL refuses to start if `ssl_key_file` is not mode 0600 owned by the server
process. Vault Agent runs as root (uid 0) inside the rootless Podman namespace and
cannot `chown` the key file to the postgres uid (70 in the Alpine image).

The solution is a startup wrapper in the Compose `command:`:

```sh
cp /vault/certs/postgres.key /tmp/server.key
chmod 600 /tmp/server.key
exec docker-entrypoint.sh postgres \
  -c ssl=on \
  -c ssl_cert_file=/vault/certs/postgres.crt \
  -c ssl_key_file=/tmp/server.key
```

When `cp` runs, the new file in `/tmp` is owned by the postgres user (the process
running inside the container). `chmod 600` then satisfies PostgreSQL's permission check.
`/tmp` is tmpfs — the key is never persisted to the host bind-mount.

### Downstream sslmode changes

Once PostgreSQL has TLS, all clients must use it:

- `vault-config/database.tf`: `?sslmode=disable` → `?sslmode=require`
- `services/keycloak/templates/compose.yml.tpl`: `KC_DB_URL` gets `?ssl=true&sslmode=require`

---

## Consequences

- **PostgreSQL credentials are encrypted in transit** between Vault, Keycloak, and
  Postgres — removes the last plaintext credential path in the stack.
- **`services/postgres/` now requires a Vault token at apply time**, just like
  `vault-config/` and `services/keycloak/`. The apply order is:
  1. `services/vault/`
  2. `vault-config/` (AppRole mount + PKI mounts must exist before postgres AppRole is created)
  3. `services/postgres/`
  4. `vault-config/ -var database_roles_enabled=true` (after Postgres is healthy)
  5. `services/keycloak/`
- **Certificate rotation is automatic**: Vault Agent renews the cert before expiry and
  rewrites the files. PostgreSQL picks up the new cert on the next connection cycle
  (existing connections are unaffected until they reconnect). A container restart is
  needed to pick up a renewed key in `/tmp/server.key`.
- **The `/tmp/server.key` copy** means cert rotation alone is insufficient without a
  Postgres restart. Acceptable for a demo stack; production use would benefit from a
  `command {}` stanza in the agent config that signals Postgres to reload (e.g.,
  `pg_ctl reload`).
