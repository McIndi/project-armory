# 0002 — Standalone Keycloak; Agent Stack moves to project-garrison

Status: implemented
Source: [handoffs/keycloak-extraction-plan.md](../handoffs/keycloak-extraction-plan.md),
[handoffs/keycloak-operator-implementation-plan.md](../handoffs/keycloak-operator-implementation-plan.md),
[handoffs/cutover-beeai-removal-handoff.md](../handoffs/cutover-beeai-removal-handoff.md)

## Context

Keycloak (plus its PostgreSQL) originally came bundled inside the BeeAI
Agent Stack Helm chart. Armory components (k3s OIDC, Headlamp) piggybacked
on the realm that chart provisioned — armory pulled in an entire application
chart to obtain an identity provider.

## Decision

1. Deploy Keycloak standalone: official Keycloak Operator → `Keycloak` CR,
   backed by a plain PostgreSQL StatefulSet (official image, no second
   operator). Realm `armory` is armory-owned, seeded by `KeycloakRealmImport`.
2. Remove Agent Stack from armory. It moves to a sister project
   (project-garrison) and consumes armory's Keycloak as an external OIDC
   provider ([../agentstack-keycloak-reqs-for-garrison.md](../agentstack-keycloak-reqs-for-garrison.md)).
3. Bitnami's Keycloak chart was evaluated and rejected (2025 catalog change
   made it unviable; operator is upstream and 1:1 with Keycloak releases).
4. VSO is the single credential path: OpenBao → VSO → one k8s Secret,
   consumed by both Postgres and the Keycloak CR. VSO was extracted into its
   own role as a prerequisite
   ([handoffs/vso-extraction-plan.md](../handoffs/vso-extraction-plan.md)).

## Consequences

Armory is a self-contained identity provider; the cutover is controlled by
`keycloak_enabled` in group_vars. Per-client configuration (e.g. the
Headlamp client) stays imperative via the admin REST API because realm
re-import semantics are unsafe for incremental updates.
