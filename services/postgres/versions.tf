terraform {
  required_version = ">= 1.8.0"
  required_providers {
    local = { source = "hashicorp/local", version = "~> 2.8" }
    null  = { source = "hashicorp/null", version = "~> 3.0" }
  }
}
