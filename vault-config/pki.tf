# ===========================================================================
# Root CA  (pki/)
# ===========================================================================

resource "vault_mount" "pki_root" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 87600h — 10 years
  description           = "Armory Root CA"
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend      = vault_mount.pki_root.path
  type         = "internal"
  common_name  = "Armory Root CA"
  organization = "Project Armory"
  key_type     = "ec"
  key_bits     = 384
  ttl          = "87600h"
}

resource "vault_pki_secret_backend_issuer" "root" {
  backend                 = vault_mount.pki_root.path
  issuer_ref              = vault_pki_secret_backend_root_cert.root.issuer_id
  issuer_name             = "armory-root"
  issuing_certificates    = ["${var.pki_base_url}/pki/ca"]
  crl_distribution_points = ["${var.pki_base_url}/pki/crl"]
}

resource "vault_pki_secret_backend_config_urls" "root" {
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["${var.pki_base_url}/pki/ca"]
  crl_distribution_points = ["${var.pki_base_url}/pki/crl"]
}

# ===========================================================================
# Internal Intermediate CA  (pki_int/)
# ===========================================================================

resource "vault_mount" "pki_int" {
  path                  = "pki_int"
  type                  = "pki"
  max_lease_ttl_seconds = 157680000 # 43800h — 5 years
  description           = "Armory Internal Intermediate CA"
}

resource "vault_pki_secret_backend_config_urls" "pki_int" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.pki_base_url}/pki_int/ca"]
  crl_distribution_points = ["${var.pki_base_url}/pki_int/crl"]
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend      = vault_mount.pki_int.path
  type         = "internal"
  common_name  = "Armory Internal Intermediate CA"
  organization = "Project Armory"
  key_type     = "ec"
  key_bits     = 384
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend               = vault_mount.pki_root.path
  csr                   = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name           = "Armory Internal Intermediate CA"
  organization          = "Project Armory"
  permitted_dns_domains = ["armory.internal"]
  ttl                   = "43800h"

  depends_on = [vault_pki_secret_backend_issuer.root]
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int.certificate

  depends_on = [vault_pki_secret_backend_config_urls.pki_int]
}

resource "vault_pki_secret_backend_issuer" "int" {
  backend                 = vault_mount.pki_int.path
  issuer_ref              = vault_pki_secret_backend_intermediate_set_signed.int.imported_issuers[0]
  issuer_name             = "armory-internal-ca"
  issuing_certificates    = ["${var.pki_base_url}/pki_int/ca"]
  crl_distribution_points = ["${var.pki_base_url}/pki_int/crl"]
}

resource "vault_pki_secret_backend_config_issuers" "pki_int" {
  backend  = vault_mount.pki_int.path
  default  = vault_pki_secret_backend_issuer.int.issuer_id

  depends_on = [vault_pki_secret_backend_issuer.int]
}

resource "vault_pki_secret_backend_role" "armory_server" {
  backend            = vault_mount.pki_int.path
  name               = "armory-server"
  allowed_domains    = ["armory.internal"]
  allow_subdomains   = true
  allow_bare_domains = true
  key_type           = "ec"
  key_bits           = 384
  max_ttl            = "2160h"
  ttl                = "720h"

  depends_on = [vault_pki_secret_backend_issuer.int]
}

# ===========================================================================
# External Intermediate CA  (pki_ext/)
# ===========================================================================

resource "vault_mount" "pki_ext" {
  path                  = "pki_ext"
  type                  = "pki"
  max_lease_ttl_seconds = 157680000 # 43800h — 5 years
  description           = "Armory External Intermediate CA"
}

resource "vault_pki_secret_backend_config_urls" "pki_ext" {
  backend                 = vault_mount.pki_ext.path
  issuing_certificates    = ["${var.pki_base_url}/pki_ext/ca"]
  crl_distribution_points = ["${var.pki_base_url}/pki_ext/crl"]
}

resource "vault_pki_secret_backend_intermediate_cert_request" "ext" {
  backend      = vault_mount.pki_ext.path
  type         = "internal"
  common_name  = "Armory External Intermediate CA"
  organization = "Project Armory"
  key_type     = "ec"
  key_bits     = 384
}

resource "vault_pki_secret_backend_root_sign_intermediate" "ext" {
  backend      = vault_mount.pki_root.path
  csr          = vault_pki_secret_backend_intermediate_cert_request.ext.csr
  common_name  = "Armory External Intermediate CA"
  organization = "Project Armory"
  ttl          = "43800h"

  depends_on = [vault_pki_secret_backend_issuer.root]
}

resource "vault_pki_secret_backend_intermediate_set_signed" "ext" {
  backend     = vault_mount.pki_ext.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.ext.certificate

  depends_on = [vault_pki_secret_backend_config_urls.pki_ext]
}

resource "vault_pki_secret_backend_issuer" "ext" {
  backend                 = vault_mount.pki_ext.path
  issuer_ref              = vault_pki_secret_backend_intermediate_set_signed.ext.imported_issuers[0]
  issuer_name             = "armory-external-ca"
  issuing_certificates    = ["${var.pki_base_url}/pki_ext/ca"]
  crl_distribution_points = ["${var.pki_base_url}/pki_ext/crl"]
}

resource "vault_pki_secret_backend_config_issuers" "pki_ext" {
  backend  = vault_mount.pki_ext.path
  default  = vault_pki_secret_backend_issuer.ext.issuer_id

  depends_on = [vault_pki_secret_backend_issuer.ext]
}

resource "vault_pki_secret_backend_role" "armory_external" {
  backend            = vault_mount.pki_ext.path
  name               = "armory-external"
  allow_any_name     = var.pki_ext_allowed_domains == ""
  allowed_domains    = var.pki_ext_allowed_domains == "" ? [] : split(",", trimspace(var.pki_ext_allowed_domains))
  allow_subdomains   = true
  allow_bare_domains = true
  allow_ip_sans      = true
  key_type           = "ec"
  key_bits           = 384
  max_ttl            = "2160h"
  ttl                = "720h"

  depends_on = [vault_pki_secret_backend_issuer.ext]
}

# ===========================================================================
# CA bundle — written to vault/ for host trust store import
# ===========================================================================

resource "local_file" "ca_bundle" {
  filename        = "${path.root}/../vault/ca-bundle.pem"
  file_permission = "0644"
  content = join("\n", [
    "# Armory PKI CA Bundle",
    "# Generated by OpenTofu vault-config module",
    "# Import into OS or browser trust store to trust all Armory-issued certificates.",
    "",
    "# Armory Root CA",
    trimspace(vault_pki_secret_backend_root_cert.root.certificate),
    "",
    "# Armory Internal Intermediate CA",
    trimspace(vault_pki_secret_backend_root_sign_intermediate.int.certificate),
    "",
    "# Armory External Intermediate CA",
    trimspace(vault_pki_secret_backend_root_sign_intermediate.ext.certificate),
    "",
  ])
}
