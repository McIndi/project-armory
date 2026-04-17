# ADR-015: pytest + hvac for End-to-End Integration Testing

**Status:** Accepted

---

## Context

The deployment involves three sequential phases — `vault/` apply, key ceremony, `vault-config/` apply — that must all succeed before the system is usable. Validating correctness manually after each change was error-prone: it required remembering the root token between steps, running ad-hoc commands, and interpreting output by eye. A failed validation left no record and gave no clear signal about which layer broke.

Two testing layers are conventional for infrastructure-as-code:

- **Module-level (`tofu test`)** — tests OpenTofu resource attributes and outputs without requiring a running system. Fast, no external dependencies.
- **Integration (operational)** — exercises the live system end-to-end: TLS handshake, PKI issuance, auth method availability. Requires a real Vault instance.

The immediate priority was the integration layer, since that is where the deployment failures had been occurring.

---

## Decision

Use **pytest** with the **hvac** Python client for end-to-end integration tests. A single session-scoped fixture in `conftest.py` manages the full lifecycle:

1. Destroy any existing state (`vault-config/`, then `vault/`)
2. Apply `vault/` — deploys the container
3. Poll until the Vault API responds
4. `bao operator init` — captures unseal key and root token from stdout
5. `bao operator unseal`
6. Poll until `is_self: true` in the status JSON (OpenBao active state indicator)
7. Apply `vault-config/` — PKI hierarchy and AppRole, with token passed via `TF_VAR_vault_token` env var (never written to disk)
8. Yield to tests
9. Collect container logs to `tests/logs/vault_<timestamp>.log`
10. Destroy both modules (unless `ARMORY_NO_TEARDOWN=1`)

Tests are split across three files by concern: `test_tls.py` (bootstrap TLS), `test_pki.py` (PKI issuance), `test_auth.py` (auth methods).

**Terratest was considered and rejected.** It is the most widely used integration testing framework for Terraform and would be the natural choice in a Go-heavy environment. For this project it would add a Go toolchain dependency with no other benefit — pytest and hvac cover the same assertions with less overhead.

**`tofu test`** covers module-level correctness (output values, TLS SAN routing, PKI resource configuration, role settings) independently of a running Vault. No containers, no network — fast feedback on configuration changes. The integration suite covers what `tofu test` cannot: live TLS handshakes, actual cert issuance, and Vault API behaviour.

---

## Consequences

**Positive:**
- Full validation runs with a single command: `pytest tests/`
- No manual steps, no env vars required before running
- Root token exists only in memory for the duration of the test run
- Logs always collected, timestamped, and retained regardless of test outcome
- `ARMORY_NO_TEARDOWN=1` leaves the environment running for debugging failed tests
- Discovered and fixed a missing default issuer configuration in `vault-config/pki.tf` that had been masked by prior manual testing on pre-configured Vault instances

**Negative / Trade-offs:**
- Tests take ~3–4 minutes per run (full destroy-rebuild cycle)
- Requires Python 3 and the `.venv` to be set up (`python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt`)
- Tests must run on a host with Podman and OpenTofu available — they are not container-portable without additional scaffolding
- `tofu test` requires `mock_resource` overrides for computed list attributes (e.g. `imported_issuers`) that mocked vault provider returns as empty — a minor friction point that surfaces any time a new resource uses list indexing on a computed attribute
