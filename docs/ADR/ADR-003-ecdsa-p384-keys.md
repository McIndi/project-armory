# ADR-003: ECDSA P-384 for all cryptographic keys

**Status:** Accepted

## Context

Key algorithm and curve selection affects security strength, performance, certificate
size, and client compatibility. The project uses TLS and PKI extensively — for Vault's
own API listener, for the CA hierarchy, and for all service certificates.

RSA-2048 is widely compatible but increasingly considered marginal for new deployments.
RSA-4096 offers stronger security at significant performance cost. ECDSA offers
equivalent or better security at much smaller key sizes and faster handshake times.

## Decision

Use **ECDSA P-384** for all generated keys: Vault's TLS certificate, the root CA,
both intermediate CAs, and all leaf certificates issued to services.

P-384 (NIST curve secp384r1) provides 192-bit equivalent security, is approved by
NIST SP 800-57, and is in the NSA Suite B / CNSA suite. It is well-supported by all
modern TLS stacks.

## Consequences

- Certificates and handshakes are smaller and faster than RSA equivalents.
- Very old TLS clients (pre-2012 era) may not support P-384. Not a concern for a
  service-to-service platform where all clients are modern.
- Consistent algorithm selection across all layers simplifies auditing and avoids
  mixed-algorithm certificate chains.
