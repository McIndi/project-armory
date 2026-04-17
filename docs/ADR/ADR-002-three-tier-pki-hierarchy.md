# ADR-002: Three-tier PKI hierarchy

**Status:** Accepted

## Context

Project Armory requires X.509 certificates for two distinct purposes:

1. **Internal service identity** — mTLS between services on the compose network,
   under a controlled namespace (`armory.internal`).
2. **External-facing services** — TLS for services that expose ports to clients,
   potentially under user-controlled domain names.

A single CA issuing all certificates would conflate these concerns and make it
impossible to apply different trust and issuance policies per use case. Issuing
directly from a root CA is a security anti-pattern — compromise of an issuing CA
should not compromise the root.

## Decision

Deploy a three-mount PKI hierarchy in Vault:

```
pki/        Root CA  (10-year validity)
            └─ signs intermediates only, never leaf certs
pki_int/    Internal Intermediate CA  (5-year, constrained to *.armory.internal)
            └─ role: armory-server  (leaf certs, max 90 days)
pki_ext/    External Intermediate CA  (5-year, domain configurable)
            └─ role: armory-external  (leaf certs, max 90 days)
```

The root CA's private key never leaves Vault and is used only to sign intermediate
certificates. The external intermediate role defaults to unconstrained
(`allow_any_name = true`) with enforcement delegated to ACL policies; it can be
constrained to specific domains by setting `PKI_EXT_ALLOWED_DOMAINS` at setup time.

Internal services use `pki_int`. Services that expose a host port use `pki_ext`.

## Consequences

- Compromise of an intermediate CA does not compromise the root or the other
  intermediate.
- Internal and external trust domains are clearly separated.
- A CA bundle (`ca-bundle.pem`) containing all three CAs must be distributed to
  clients and imported into trust stores for issued certificates to be trusted.
- The unconstrained external role default follows common practice for self-managed
  PKI where domain enforcement happens at the policy layer. Teams requiring domain
  constraint should set `PKI_EXT_ALLOWED_DOMAINS` at deploy time.
