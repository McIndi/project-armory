# common role

## Purpose
Shared utility tasks used by multiple roles.

## Included task files
- `tasks/load_openbao_provisioner_token.yml`: Ensures `openbao_provisioner_token` is available by reading the vaulted provisioner token file. Use this for day-to-day automation calls to OpenBao.
- `tasks/load_openbao_root_token.yml`: BREAK-GLASS helper that ensures `openbao_root_token` is available by reading the vaulted OpenBao init keys file when needed. Do not add new routine consumers.
- `tasks/prepare_internal_https_caller.yml`: Prepares internal HTTPS callers by ensuring local FQDN resolution, writing a root CA file from a secret, fetching the issuer CA from OpenBao PKI, and writing a combined trust bundle with fail-fast assertions.
