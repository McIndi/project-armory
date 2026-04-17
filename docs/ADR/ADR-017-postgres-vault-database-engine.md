# ADR-017: PostgreSQL with Vault Database Secrets Engine

**Status:** Accepted

---

## Context

Keycloak requires a relational database. Several services planned for the platform
(Keycloak, future app backends) need database credentials that follow least-privilege
principles and support automatic rotation.

Two concerns were combined in this decision:

1. **What database and topology to use** — single Postgres instance vs. separate instances
   per service.
2. **How credentials should be managed** — static credentials in a config file vs. Vault
   Database secrets engine (dynamic or static roles).

### Static vs. dynamic roles

The Vault Database secrets engine supports two credential modes:

- **Dynamic roles** create a new PostgreSQL role per request with a configured TTL and
  automatic expiry. On expiry, Vault issues a revocation query. The application gets
  a credential that is short-lived and unique per invocation.
- **Static roles** manage an *existing* PostgreSQL account. Vault periodically rotates
  the password and stores the current credential at a deterministic path. The application
  reads that path and gets the current password.

Keycloak maintains a connection pool. When Vault rotates a dynamic credential, the old
credential expires and all pool connections that hold it become invalid mid-session.
Recovering requires draining and re-establishing the pool, which in practice means a
service restart or a custom connection validation hook. Keycloak's JDBC driver does not
support transparent credential refresh.

Static roles solve this: the `keycloak` PostgreSQL account always exists, and Vault
rotates its password on a schedule (24 h). The next Vault Agent template render picks up
the new password; Keycloak can restart cleanly with the new credential at the next
natural restart cycle. No mid-session surprise.

### Instance topology

Options considered:

- **One Postgres instance per service** — strong blast-radius isolation; separate WAL
  streams, separate backup schedules. Appropriate for large-scale or multi-tenant
  production environments.
- **One Postgres instance, separate databases** — one container, separate logical
  databases (`keycloak`, `app`). Credential isolation comes from Vault, not the instance
  boundary.

For a single-user demo project, instance-level isolation provides no meaningful security
benefit. Vault's Database engine provides the credential isolation that matters: each
service gets a separate PostgreSQL role with grants only to its own database, managed
through separate Vault paths and policies. The `vault_mgmt` account cannot issue
credentials for the wrong database because the Vault role configuration specifies which
database each role targets.

A single instance is operationally simpler and appropriate for the demo scope.

### `vault_mgmt` privilege design

The Vault Database engine connects to Postgres as `vault_mgmt` to create and revoke
dynamic roles. The minimum necessary privileges are:

- `LOGIN` — connect to the database
- `CREATEROLE` — issue `CREATE ROLE ... WITH LOGIN` for dynamic credentials
- `NOSUPERUSER NOCREATEDB` — no escalation paths
- Membership in template roles `WITH ADMIN OPTION` — allows `GRANT keycloak_role TO
  <new_user>` and `GRANT app_role TO <new_user>` without superuser

The `ADMIN OPTION` grant is required in PostgreSQL 16+ where non-superuser `CREATEROLE`
can only grant roles they hold with admin option. Template roles are pre-created in
`init.sql` with grants scoped to their respective database. Dynamic credentials
inherit only what the template role has been explicitly granted.

### Connection verification

The `vault_database_secret_backend_connection` resource has a `verify_connection`
attribute that defaults to `true`. With `true`, Vault tests the PostgreSQL connection
at Terraform apply time and fails the apply if Postgres is unreachable.

Setting `verify_connection = false` allows `vault-config/` to be applied in a single
pass before the Postgres container is started. The connection is still validated the
first time a credential is actually requested (when the Keycloak Vault Agent calls
`database/static-creds/keycloak`). This keeps the deployment order simple:
vault-config/ once → postgres/ → keycloak/.

---

## Decision

- Deploy a single PostgreSQL 16 instance (`services/postgres/`) with two databases:
  `keycloak` and `app`.
- Use the Vault Database secrets engine (`vault-config/database.tf`) as the sole
  credential management path for database access.
- Use a **static role** (`keycloak`) for Keycloak due to its connection pool behaviour.
  Rotation period: 24 h. Keycloak reads the credential via Vault Agent template rendering
  at startup and at each agent renewal cycle.
- Use a **dynamic role** (`app`) for future application services. Default TTL: 1 h.
  Short-lived credentials are appropriate for stateless workloads.
- The `vault_mgmt` PostgreSQL account uses `NOSUPERUSER NOCREATEDB CREATEROLE` with
  `ADMIN OPTION` on template roles — minimum privilege for the engine to operate.
- Set `verify_connection = false` so `vault-config/` can be fully applied before Postgres
  is started. Connection validity is checked at first credential request.

---

## Consequences

- Keycloak and future app services have zero-knowledge of Vault. They read credentials
  from files rendered by Vault Agent.
- Static role rotation (24 h) is automatic. A service restart is required to pick up the
  new credential; the Vault Agent template re-renders on rotation but Keycloak must
  reconnect. In a demo context, restarting Keycloak after rotation is acceptable.
- The `vault_mgmt` password is stored in `vault-config/terraform.tfstate` in plaintext.
  This is consistent with the project's documented `tfstate` limitation (ADR-012).
- Adding a second Postgres instance (for stronger isolation between services) is a
  straightforward future change: add a second `vault_database_secret_backend_connection`
  with a new host and replicate the role/policy structure.
- The `init.sql` bootstrap script only runs on first container start (when `pgdata/` is
  empty). Re-running `services/postgres/` apply against an existing database is safe —
  compose restarts the existing container without re-running init.
