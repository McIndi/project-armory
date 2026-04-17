# ADR-010: Response wrapping for AppRole secret_id delivery

**Status:** Accepted

## Context

AppRole authentication requires two credentials: a `role_id` (not secret, can be
baked into config) and a `secret_id` (secret, must be delivered securely). The
challenge of securely delivering the `secret_id` to a service on first boot is known
as the "secret zero" problem.

Options considered:

- **Environment variable injection** — `secret_id` passed as an env var at compose
  run time. Simple but requires a human to copy/paste the value, and env vars are
  visible in `docker inspect` / `podman inspect`.
- **Mounted secrets file** — `secret_id` written to a host file and mounted into the
  container. Slightly better than env vars but the file persists on disk with the
  secret in plaintext.
- **Response wrapping** — Vault wraps the `secret_id` in a single-use, short-TTL
  token. The token can only be unwrapped once; afterward it is consumed and worthless.
  Vault Agent natively understands wrapped tokens and unwraps them automatically.
- **Platform auth (AWS IAM, GCP SA, Kubernetes SA)** — Eliminates secret zero
  entirely by using the underlying platform identity. Not applicable here (no
  cloud/k8s platform).

## Decision

Use **Vault response wrapping** via the OpenTofu Vault provider. The
`vault_approle_auth_backend_role_secret_id` resource generates a wrapped secret_id
with a short `wrapping_ttl`. OpenTofu writes the wrapping token to a file alongside
the service deployment. Vault Agent is configured to read and unwrap it on first boot.

## Consequences

- Delivery is fully automated — no manual copy/paste of credentials after
  `tofu apply`.
- The wrapping token is single-use: if intercepted after the agent has consumed it,
  it is worthless.
- The wrapping token is stored in `terraform.tfstate` until consumed. This is the
  same limitation as other sensitive values in local state (see ADR-012). Acceptable
  for a demo; remote encrypted state is required for production.
- If the agent fails to start before the `wrapping_ttl` expires, `tofu apply` must
  be re-run to generate a new wrapping token.
