# ADR-009: Vault Agent sidecar for service identity

**Status:** Accepted

## Context

Services need TLS certificates provisioned from Vault PKI and automatically renewed
before expiry. Several approaches were considered:

- **Direct API calls from the service** — The service authenticates to Vault itself,
  fetches a cert, and manages renewal. This couples every service to Vault's auth
  mechanics and requires Vault SDK integration or curl scripting in every service image.
- **Second process within the service container** — Run Vault Agent alongside the
  service in the same container via a process supervisor (e.g., supervisord). Process
  lifecycles are coupled: if the agent crashes, cert renewal stops silently; if the
  service crashes, the agent keeps running unobserved. Health checks become ambiguous.
- **Vault Agent as a sidecar container** — A separate container running `bao agent`
  handles all Vault interaction and writes certs to a shared volume. The service reads
  cert files; it has no knowledge of Vault.

## Decision

Each service that requires Vault-issued certificates runs a **Vault Agent sidecar
container** alongside it in the same compose service group. Both containers share a
named volume for certificate files. The service container has no Vault dependency in
its image or code.

## Consequences

- Service containers are Vault-agnostic — they read cert files from a known path,
  regardless of how those files were provisioned.
- Agent and service have independent lifecycle, health checks, and restart policies.
  A crashed agent is observable and restartable without affecting the service.
- Certificate renewal is handled entirely by the agent. The service is signalled
  (e.g., nginx reload) by the agent's template renderer when certs are renewed.
- Adds one container per service. For a demo this is acceptable overhead; in
  production Kubernetes environments this maps directly to the standard Vault Agent
  injector/sidecar pattern.
- This pattern translates directly to Kubernetes (Vault Agent Injector, Vault Secrets
  Operator) without conceptual changes.
