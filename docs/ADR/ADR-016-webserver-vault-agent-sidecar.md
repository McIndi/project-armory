# ADR-016: Webserver Service — Vault Agent Sidecar for Certificate Delivery

**Status:** Accepted

---

## Context

The webserver is the first service module in Project Armory. Its primary purpose
is to validate the full service identity workflow end-to-end before more complex
services are built. It is intentionally minimal — nginx serving a static page
over HTTPS — and will be discarded once the pattern is proven.

The core problem it exercises is **how a service obtains and maintains a TLS
certificate from Vault without embedding long-lived credentials in its container
image or compose file.**

Three delivery mechanisms were considered:

1. **Pre-provisioned certs** — OpenTofu issues the cert and writes it to disk before the container starts. Simple, but certs are static; rotation requires a reapply.
2. **Application-native Vault SDK** — the service calls Vault directly. Puts Vault auth logic in application code; not appropriate for nginx.
3. **Vault Agent sidecar** — a dedicated agent process handles auth, issues the cert, writes it to a shared volume, and handles renewal. The application (nginx) is Vault-unaware.

---

## Decision

Deploy Vault Agent as a **separate sidecar container** in the same Compose project,
sharing a host-path volume with nginx for certificate delivery.

Key design choices:

**Sidecar container, not a second process.** Running Vault Agent as a second process inside the nginx container would require a process supervisor, complicates health checks, and mixes concerns. A separate container has its own lifecycle, logs, and resource limits.

**AppRole with response-wrapped secret_id (ADR-010).** The `services/webserver/` OpenTofu module creates its own AppRole role and policy, and generates a response-wrapped secret_id via the Vault provider. The wrapped token is written to a host-path file mounted into the agent container. Vault Agent unwraps it on first boot and deletes the file. The role_id is not sensitive and is embedded in the agent config.

**External PKI (`pki_ext`).** The webserver serves external users. Its certificate is issued from the external intermediate CA (`pki_ext/issue/armory-external`), consistent with the PKI hierarchy design in ADR-002.

**`pkiCert` template function.** Vault Agent's `pkiCert` function issues and caches the cert+key atomically, renewing before expiry. Two separate `template` stanzas (one for cert, one for key) reference the same cached secret, avoiding the non-idempotency of the PKI issue endpoint.

**Host-path volume for certs.** Consistent with the rest of the project (ADR-012), a host directory (`deploy_dir/certs/`) is used rather than a named Docker volume. This makes cert files inspectable on the host without entering a container.

**Localhost-only port binding.** Port 443 is published as `127.0.0.1:443:443`, consistent with ADR-007. Configurable via `host_ip` variable for environments that require external access.

**Separate OpenTofu module with its own state.** `services/webserver/` follows the same pattern as `vault-config/` — independent module, independent state, applied after vault-config/. The module is responsible for its own Vault policy, AppRole role, file rendering, and container lifecycle.

---

## Consequences

- nginx is fully Vault-unaware; it reads certs from a path that Vault Agent maintains.
- Certificate rotation is automatic — Vault Agent renews before the configured `min_ttl` threshold without restarting nginx (uses `exec` reload or SIGHUP).
- The wrapped secret_id is single-use. On each `tofu apply`, a new wrapped token is generated. If the agent container is destroyed and recreated, reapplying generates a new wrapped token for the new agent to unwrap.
- The `services/webserver/` module requires vault-config/ to be applied first (AppRole mount and pki_ext role must exist).
- The module adds a third phase to the deployment sequence: vault/ → key ceremony → vault-config/ → services/webserver/.
- This module is a **toy example** and will be replaced by real service modules. The pattern it establishes (AppRole + Vault Agent + host-path cert volume) is the template for all future services.
