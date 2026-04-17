# TLS certificate generation tests for the vault/ module.
#
# null and local providers are mocked so no containers are started and
# no files are written to disk. The tls provider runs for real — all
# crypto happens in-process and produces real, inspectable values.

mock_provider "null" {}
mock_provider "local" {}

# ---------------------------------------------------------------------------
# Default SAN behaviour
# ---------------------------------------------------------------------------

run "default_dns_sans_include_required_names" {
  command = plan

  assert {
    condition     = contains(tls_cert_request.server.dns_names, "localhost")
    error_message = "DNS SANs must always include localhost"
  }

  assert {
    condition     = contains(tls_cert_request.server.dns_names, var.tls_server_cn)
    error_message = "DNS SANs must include tls_server_cn (${var.tls_server_cn})"
  }
}

run "default_ip_sans_include_loopback" {
  command = plan

  assert {
    condition     = contains(tls_cert_request.server.ip_addresses, "127.0.0.1")
    error_message = "IP SANs must always include 127.0.0.1"
  }
}

# ---------------------------------------------------------------------------
# api_addr routing: IP → ip_sans, hostname → dns_sans
# ---------------------------------------------------------------------------

run "api_addr_ip_added_to_ip_sans" {
  command = plan

  variables {
    api_addr = "192.168.1.50"
  }

  assert {
    condition     = contains(tls_cert_request.server.ip_addresses, "192.168.1.50")
    error_message = "IP api_addr must be added to IP SANs"
  }

  assert {
    condition     = !contains(tls_cert_request.server.dns_names, "192.168.1.50")
    error_message = "IP api_addr must not be added to DNS SANs"
  }
}

run "api_addr_hostname_added_to_dns_sans" {
  command = plan

  variables {
    api_addr = "vault.example.com"
  }

  assert {
    condition     = contains(tls_cert_request.server.dns_names, "vault.example.com")
    error_message = "Hostname api_addr must be added to DNS SANs"
  }

  assert {
    condition     = !contains(tls_cert_request.server.ip_addresses, "vault.example.com")
    error_message = "Hostname api_addr must not be added to IP SANs"
  }
}

# ---------------------------------------------------------------------------
# CA certificate properties
# ---------------------------------------------------------------------------

run "ca_cert_is_ca" {
  command = plan

  assert {
    condition     = tls_self_signed_cert.ca.is_ca_certificate
    error_message = "CA cert must have is_ca_certificate = true"
  }
}

run "server_cert_is_not_ca" {
  command = plan

  assert {
    condition     = !tls_locally_signed_cert.server.is_ca_certificate
    error_message = "Server cert must not be a CA certificate"
  }
}

# ---------------------------------------------------------------------------
# Key algorithm
# ---------------------------------------------------------------------------

run "keys_use_ecdsa_p384" {
  command = plan

  assert {
    condition     = tls_private_key.ca.algorithm == "ECDSA"
    error_message = "CA key must use ECDSA"
  }

  assert {
    condition     = tls_private_key.ca.ecdsa_curve == "P384"
    error_message = "CA key must use P-384 curve"
  }

  assert {
    condition     = tls_private_key.server.algorithm == "ECDSA"
    error_message = "Server key must use ECDSA"
  }

  assert {
    condition     = tls_private_key.server.ecdsa_curve == "P384"
    error_message = "Server key must use P-384 curve"
  }
}
