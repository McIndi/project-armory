# ADR-012: Local tfstate accepted as demo limitation

**Status:** Accepted

## Context

OpenTofu state files (`terraform.tfstate`) store the full resource graph including
sensitive values. In this project, state contains:

- The TLS CA private key and server private key (from the `tls` provider)
- AppRole `secret_id` wrapping tokens (from the `vault` provider)

Local state files are unencrypted plaintext on disk. They are gitignored but
unprotected at the filesystem level. Any user with read access to the project
directory can extract these values.

For a single-user local demo this is an accepted limitation. For a shared or
production environment it is not acceptable.

## Decision

Accept local state for the demo deployment. Document the limitation explicitly in
the README security trade-offs section. Do not implement remote state for the demo.

The production path is: remote state backend with encryption at rest. Options include:
- S3 + KMS (AWS)
- GCS + CMEK (GCP)
- Azure Blob + Key Vault
- Terraform Cloud / HCP Terraform (managed)
- Self-hosted OpenTofu state backend

## Consequences

- The demo is simpler to set up — no cloud credentials or external services required.
- State files must not be copied to shared locations or committed to version control
  (gitignore enforces the latter).
- Anyone reproducing the demo gets a clean state from `tofu apply`; there is no shared
  state to corrupt or leak.
- Production use requires migrating to a remote backend before the first non-demo
  deployment. This should be the first infrastructure change when operationalising
  the project.
