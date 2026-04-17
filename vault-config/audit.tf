# ===========================================================================
# Audit logging
# ===========================================================================
#
# OpenBao 2.x removed runtime API management of audit devices. Audit must
# be declared in the server config file (vault.hcl) rather than via the
# API. The file audit device is configured in vault/templates/vault.hcl.tpl.
#
# HashiCorp Vault still accepts the vault_audit provider resource at runtime.
# If this module is used against Vault instead of OpenBao, restore:
#
#   resource "vault_audit" "file" {
#     type    = "file"
#     path    = "file"
#     options = { file_path = "/vault/logs/audit.log" }
#   }
