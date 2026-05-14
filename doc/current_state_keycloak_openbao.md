# Keycloak + OpenBao Integration State — Armory

> This document focuses on the interaction surface between identity and secrets: Keycloak for human identity, OpenBao for secrets and machine identity. It covers what exists now, what is adjacent, and what integration patterns are realistic in this stack.

---

## Executive Summary

Today, **Keycloak and OpenBao are only indirectly integrated**.

| Area | Current State |
|---|---|
| Human authentication | Keycloak authenticates BeeAI users via OIDC |
| Machine authentication | OpenBao authenticates in-cluster workloads via Kubernetes auth |
| Secret distribution | OpenBao → VSO → k8s Secrets → BeeAI workloads |
| TLS trust | OpenBao PKI issues the cert served in front of Keycloak and BeeAI |
| Direct Keycloak-to-OpenBao trust | Not implemented |
| OpenBao-issued Keycloak tokens | Not implemented |
| Keycloak-issued OpenBao tokens | Not implemented |

The current architecture already supports the cleanest split of responsibility:

- **Keycloak** is the authority for **human users**.
- **OpenBao** is the authority for **non-human workloads and secrets**.

That split is usually the right baseline.

---

## Current Combined Integration Points

### 1. Keycloak admin seed password originates in OpenBao

This is the only meaningful credential-level linkage currently implemented.

```text
OpenBao KV secret/beeai/credentials
  -> VSO VaultStaticSecret
  -> k8s Secret beeai-credentials
  -> Ansible reads admin_password
  -> Helm value keycloak.auth.seedAgentstackUsers[].password
  -> Keycloak creates/updates the BeeAI admin user
```

This means:

- Keycloak does **not** own the source of truth for the seeded BeeAI admin password.
- OpenBao is the system of record for that password.
- Keycloak consumes that value only during deployment/reconciliation.

### 2. Keycloak is published behind TLS issued by OpenBao PKI

Keycloak is exposed at `https://armory.local/realms/agentstack`, but the trust chain comes from OpenBao:

```text
OpenBao PKI
  -> cert-manager ClusterIssuer openbao-pki
  -> Certificate armory-tls
  -> nginx Ingress TLS termination
  -> Keycloak served behind trusted HTTPS
```

This is not an auth integration, but it is an operational integration point:

- Keycloak's issuer URL depends on the OpenBao-backed certificate chain.
- OIDC clients trust the Keycloak endpoint because nginx serves a cert issued by OpenBao PKI.

### 3. Human and machine identity are already separated by platform design

Current split:

| Identity Type | Authority | Current Mechanism |
|---|---|---|
| Human user | Keycloak | OIDC login to BeeAI |
| In-cluster machine | OpenBao | Kubernetes auth role (`beeai-vso`, `cert-manager`) |
| Deployment automation | OpenBao root token via Ansible bootstrap file | Ansible unseal/configure/write operations |

This is the strongest current pattern in the stack, even though it is not a direct software handshake between the two systems.

---

## What Is Not Currently Happening

These ideas are reasonable, but they are **not** present in the current implementation:

| Idea | Current State |
|---|---|
| OpenBao validating Keycloak JWTs to authenticate humans | Not implemented |
| Keycloak brokering access to OpenBao secrets | Not implemented |
| OpenBao dynamically rotating Keycloak client secrets | Not implemented |
| nginx or another proxy exchanging Keycloak tokens for OpenBao tokens | Not implemented |
| Sidecar/proxy injecting OpenBao secrets based on Keycloak user claims | Not implemented |
| Keycloak storing its own realm/client secrets in OpenBao at runtime | Not implemented |

That distinction matters: some of these are attractive on paper but add substantial operational coupling.

---

## Integration Patterns Worth Considering

## Pattern 1: Humans in Keycloak, Machines in OpenBao

This is the cleanest model for Armory.

### How it works

- A human authenticates to Keycloak using browser-based OIDC.
- The BeeAI UI/API trusts Keycloak tokens for user identity and roles.
- Workloads never use human tokens to fetch secrets.
- Workloads authenticate separately to OpenBao using Kubernetes auth, AppRole, or another machine-oriented auth method.

### Why this is good

- Clear separation of trust domains.
- Least privilege is easier to enforce.
- Secret access remains workload-scoped, not user-scoped.
- No need to hand OpenBao tokens to browsers.

### Fit for Armory

This is effectively the current trajectory and should stay the default.

### Example

```text
User -> Keycloak -> BeeAI UI/API
BeeAI API -> OpenBao -> DB/API credentials
```

The user proves identity to the application. The application proves workload identity to OpenBao.

That is usually better than trying to make the user directly a secret consumer.

---

## Pattern 2: Keycloak for human auth, OpenBao for service auth inside the same app

This is a more explicit form of Pattern 1 and is likely the right long-term application model.

### Flow

1. User logs in through Keycloak.
2. BeeAI API receives a Keycloak JWT.
3. BeeAI API authorizes the user based on roles/claims.
4. BeeAI API separately authenticates to OpenBao as a machine identity.
5. BeeAI API retrieves the secret needed for the requested operation.

### Good use cases

- Per-request access to downstream APIs.
- User-triggered actions that need machine credentials.
- Admin screens where the user is authorized by Keycloak but the app accesses secrets via OpenBao.

### Security property

The human identity controls **authorization**, but the non-human identity controls **secret retrieval**.

That is the core model you asked about: one system authenticates humans, the other authenticates non-humans.

### Fit for Armory

Strong fit. This is the most defensible architecture for a security-first demo.

---

## Pattern 3: Keycloak tokens exchanged for OpenBao tokens

This is the first truly direct Keycloak↔OpenBao integration pattern.

### Concept

OpenBao can be configured with an OIDC or JWT auth method that trusts Keycloak as an external identity provider. A user presents a Keycloak-issued JWT, and OpenBao exchanges that for an OpenBao token with a policy derived from claims.

### Flow

```text
User -> Keycloak login
User gets OIDC token
Client sends Keycloak token to OpenBao auth/jwt or auth/oidc
OpenBao validates token against Keycloak JWKS / issuer
OpenBao returns scoped OpenBao token
Client uses OpenBao token for allowed secret paths
```

### What this enables

- Human users can access OpenBao directly.
- OpenBao policies can be mapped from Keycloak claims such as realm roles or groups.
- Secret access becomes authenticated and audit-logged per user identity instead of per application only.

### Good use cases

- Admin operators retrieving bootstrap values.
- Humans requesting short-lived credentials on demand.
- Developer portals where users need controlled read access to specific secrets.

### Risks

- Secret access moves closer to the user/browser boundary.
- Frontend leakage becomes much more dangerous if a browser receives OpenBao tokens.
- Mapping Keycloak roles to OpenBao policies adds policy-management complexity.

### Fit for Armory

Good for **operator workflows**, weaker for end-user browser flows.

If implemented, it should likely be limited to:

- CLI or admin-only interfaces
- short TTL OpenBao tokens
- narrow policies
- audit logging enabled first

---

## Pattern 4: Proxy-mediated token exchange

This is close to what you described: a proxy or broker sits in the middle and uses Keycloak-authenticated user context to obtain or use OpenBao credentials.

### Variants

#### 4A. oauth2-proxy or auth gateway in front of an internal service

- User authenticates with Keycloak at the proxy.
- Proxy injects identity headers to the upstream app.
- Upstream app, not the browser, talks to OpenBao.

This is not direct token exchange, but it is a clean way to avoid giving OpenBao credentials to the client.

#### 4B. Custom broker service

- User authenticates with Keycloak.
- A backend broker validates the user's token.
- Broker uses its own OpenBao machine identity to fetch secrets or mint short-lived credentials.
- Broker returns only the minimum derived output to the client.

Example outputs:

- temporary DB creds
- signed URLs
- one-time API keys
- redacted config fragments

#### 4C. Token exchange service

- User presents Keycloak token to broker.
- Broker maps claims to OpenBao role/policy.
- Broker performs OpenBao login or acts as an OpenBao control plane.
- Broker returns a short-lived OpenBao token or uses it server-side.

### Fit for Armory

The best version is **broker uses OpenBao server-side and never returns OpenBao token to the browser**.

That gives you:

- Keycloak-authenticated humans
- OpenBao-backed secret access
- no OpenBao token leakage to browsers

---

## Pattern 5: OpenBao rotates Keycloak client secrets

This is one of the most useful future integrations.

### Concept

Keycloak confidential clients need secrets. Those secrets do not need to live in the chart or static YAML. OpenBao can become the source of truth for:

- Keycloak client secrets
- admin API credentials
- realm SMTP credentials
- external IdP client secrets

### Flow

```text
OpenBao KV or dynamic secret
  -> VSO / Agent / broker / init container
  -> Keycloak config import or admin API update
  -> application uses rotated Keycloak client credentials
```

### Examples

- BeeAI UI's confidential OIDC client secret
- Service-account clients used by backend automation
- GitHub/Azure/Google IdP secrets for federation

### Hard part

Keycloak does not magically hot-reload every client secret. Rotation usually requires one of:

- admin API automation
- startup-time import
- restart/reconcile flow

### Fit for Armory

High-value for admin/API clients. Medium complexity. Worth documenting as a phase-2 hardening step.

---

## Pattern 6: OpenBao stores Keycloak realm bootstrap and admin credentials

This is an extension of what you already do with the seeded BeeAI admin password.

### Candidates to move into OpenBao

- Keycloak admin console bootstrap password
- realm import secrets
- SMTP password
- external IdP client secrets
- signing keys for custom integrations
- service-account client secrets

### Current gap

The master admin password is still chart-generated and retrieved from the k8s Secret `keycloak-secret`, not from OpenBao.

### Value

- Single secret authority
- better rotation story
- fewer chart-generated opaque secrets

### Fit for Armory

Strong fit. This is one of the next best direct improvements.

---

## Pattern 7: OpenBao validates Keycloak JWTs for user-scoped secret access

This is the strongest direct integration if you want human-authenticated secret access.

### Concept

Configure OpenBao `auth/jwt` or `auth/oidc` to trust Keycloak.

OpenBao would validate:

- issuer: Keycloak realm URL
- audience: expected client or OpenBao itself
- JWKS: Keycloak public signing keys
- mapped claims: groups, realm roles, client roles, email, subject

### Example policy mapping

| Keycloak Claim | OpenBao Outcome |
|---|---|
| `realm_access.roles` contains `armory-ops` | policy `ops-read` |
| group `/platform/security` | policy `pki-admin` |
| group `/beeai/admins` | policy `beeai-admin-read` |

### Best use cases

- Operator CLI login to OpenBao
- Admin web portal backed by OpenBao
- User-specific audit trail for secret retrieval

### Weak use cases

- Direct browser-side access to broad secrets
- any flow where a frontend stores long-lived OpenBao tokens

### Fit for Armory

Good as an operations/admin feature, not as the default end-user application flow.

---

## Pattern 8: Keycloak as identity, OpenBao as credential minting service

This is often the most compelling demo pattern.

### Flow

1. Human logs in with Keycloak.
2. Backend authorizes action using Keycloak role/group claims.
3. Backend requests a short-lived credential from OpenBao.
4. Credential is used immediately against a downstream system.
5. Credential expires automatically.

### Examples

- short-lived PostgreSQL credentials
- cloud API keys
- signed certificates from PKI
- temporary SSH certificates

### Why this is strong

- Humans never receive standing secrets.
- OpenBao remains the source of sensitive material.
- Keycloak remains the authority for who is allowed to ask.

### Fit for Armory

Excellent fit if you later add:

- OpenBao database engine
- SSH CA or TLS client certificates
- per-operator or per-session credentials

---

## Pattern 9: Secret injection based on user identity

This is the pattern you hinted at: user authenticates via Keycloak, then a proxy or intermediary injects secrets along the way.

### Two ways to interpret it

#### 9A. Inject secrets into the backend request path

This is viable.

- User authenticates to Keycloak.
- Backend or broker sees user identity.
- Backend fetches the secret from OpenBao.
- Backend uses the secret for the request.

The secret never reaches the browser.

#### 9B. Inject secrets into the browser/client directly

This is usually a bad idea.

- Browser becomes a secret holder.
- Revocation becomes harder.
- XSS becomes catastrophic.
- Auditing becomes messy unless each browser gets a unique OpenBao token.

### Recommendation

If you want "injected along the way," do it **server-side**.

That means:

- proxy/gateway authenticates user with Keycloak
- proxy/backend uses workload auth to OpenBao
- proxy/backend injects only derived headers, ephemeral creds, or downstream requests

Do not inject raw OpenBao secrets into the client unless the client is a trusted CLI or admin tool.

---

## Recommended Architecture for Armory

## Tier 1: Keep the current split

- Keycloak authenticates humans.
- OpenBao authenticates workloads and stores secrets.
- BeeAI API acts as the bridge.

This is already consistent with a security-first story.

## Tier 2: Move more Keycloak secrets into OpenBao

Best next steps:

1. Store Keycloak master admin password in OpenBao instead of leaving it chart-generated.
2. Store Keycloak confidential client secrets in OpenBao.
3. Store external IdP secrets in OpenBao.

## Tier 3: Add user-to-OpenBao federation for operators only

Implement OpenBao JWT/OIDC auth against Keycloak for:

- operators
- platform admins
- secret readers

Do not make this the default end-user app flow.

## Tier 4: Add short-lived credential brokering

Build a backend broker that:

- authenticates humans via Keycloak
- authorizes by Keycloak claims
- retrieves or mints credentials from OpenBao
- returns only the minimum necessary result

That is the strongest combined story for demos and real architecture.

---

## Concrete Future Integration Ideas

| Idea | Value | Complexity | Fit |
|---|---|---|---|
| Store Keycloak admin password in OpenBao | High | Low | Strong |
| Store Keycloak client secrets in OpenBao | High | Medium | Strong |
| OpenBao JWT/OIDC auth trusting Keycloak | High | Medium | Strong for operators |
| Broker service: Keycloak human auth + OpenBao secret retrieval | Very high | Medium | Best long-term fit |
| Dynamic DB creds gated by Keycloak-authenticated backend | Very high | High | Strong phase 2 |
| Browser receives OpenBao token directly | Low | Medium | Weak / avoid |
| Proxy injects secrets server-side after Keycloak auth | High | Medium | Strong |
| Use Keycloak client credentials for machines instead of OpenBao auth | Medium | Medium | Usually inferior to OpenBao machine auth |

---

## Anti-Patterns to Avoid

### 1. Using Keycloak as the machine-secret system

Keycloak is not a secrets manager. It can hold client secrets, but it is not the right place to manage broad application secret distribution.

### 2. Giving browsers broad OpenBao tokens

If a browser gets an OpenBao token with meaningful read power, your XSS blast radius becomes your secrets blast radius.

### 3. Coupling every user action to direct secret retrieval

User identity should drive authorization decisions. Secret retrieval should usually remain a backend responsibility.

### 4. Replacing workload auth with human auth

Workloads should continue to authenticate as workloads. Human identity is not a substitute for service identity.

---

## The Short Answer to Your Two Examples

## "Keycloak tokens being rotated by vault and then provided to the client"

That is possible only in a modified form, and the safe version is:

- OpenBao stores or rotates **Keycloak client secrets**, not end-user tokens.
- A backend or broker uses those secrets to interact with Keycloak.
- If a client receives anything, it should be a narrowly scoped, short-lived derivative, not a broad OpenBao token.

OpenBao rotating a Keycloak confidential client secret is a good pattern. OpenBao minting something and handing it straight to a browser is usually the wrong boundary.

## "One service using Keycloak to authenticate human identities and OpenBao to authenticate non-human identities"

Yes. That is the best pattern in this architecture.

Recommended model:

- Keycloak authenticates the human.
- The application authorizes the request using Keycloak claims.
- The application authenticates to OpenBao as a workload.
- OpenBao releases the secret or short-lived credential needed for the action.

That split is precise, scalable, and aligned with security-first design.

---

## Suggested Follow-On Doc Sections

If you want to extend this later, the next useful additions would be:

1. a decision matrix for `auth/jwt` vs `auth/oidc` in OpenBao trusting Keycloak
2. a broker-service reference flow for BeeAI actions
3. a concrete model for rotating Keycloak confidential client secrets from OpenBao
4. an operator-only design for OpenBao login using Keycloak realm roles