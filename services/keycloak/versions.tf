terraform {
  required_version = ">= 1.8.0"
  required_providers {
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.8" }
    null  = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

provider "vault" {
  address      = var.vault_addr
  token        = var.vault_token
  ca_cert_file = var.vault_cacert
}
