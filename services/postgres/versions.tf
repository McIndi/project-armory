terraform {
  required_version = ">= 1.8.0"
  required_providers {
    local = { source = "hashicorp/local", version = "~> 2.8" }
    null  = { source = "hashicorp/null",  version = "~> 3.0" }
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}

provider "vault" {
  address      = var.vault_addr
  token        = var.vault_token
  ca_cert_file = coalesce(var.vault_cacert, "${var.armory_base_dir}/vault/tls/ca.crt")
}
