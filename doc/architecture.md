# Architecture

How the platform components fit together and why they are ordered this way.
For day-to-day commands see [operations.md](operations.md). For tunables see
[configuration.md](configuration.md). For security posture see
[security.md](security.md).

## Overview

Project Armory deploys an OpenShift-focused platform with centralized secrets,
internal PKI, and OIDC identity. Provisioning is Ansible-driven.

Components:

| Component | Namespace | Deployed by role | Purpose |
|---|---|---|---|
| OpenBao | `tex26-vault` (default) | `openbao` | Secrets (KV v2) + PKI root of trust + audit device |
| cert-manager | `cert-manager` (shared cluster component) | `cert_manager` | Uses OpenBao-backed ClusterIssuers for certificate issuance |
| Keycloak + PostgreSQL | `tex26-oidc` (default) | `keycloak` | OIDC identity provider and realm/user management |
| OpenBao OIDC wiring | `tex26-vault`, `tex26-oidc` | `openbao_oidc` | Configures OpenBao OIDC auth against Keycloak |
| Envoy edge | `tex26-gateway` (default) | `envoy_proxy` | Public edge for Keycloak/OpenBao traffic |
| Optional registry | `tex26-oci-registry` (default) | `registry` | In-cluster OCI registry for armory-owned workflows |
| Readiness checks | n/a | `readiness_check` | End-of-run platform verification |

The `common` role provides shared helpers consumed by other roles (OpenBao root
state loading, CA secret copy, internal HTTPS caller setup, and tunnel cleanup).

## Role execution order

`playbooks/site.yml` runs roles in dependency order:

```
env_guard -> helm -> openbao -> cert_manager -> keycloak -> openbao_oidc -> envoy_proxy -> registry (optional) -> readiness_check
```

Ordering constraints that matter:

- `openbao` before `cert_manager`: ClusterIssuers depend on OpenBao PKI mounts.
- `cert_manager` before `keycloak`/`envoy_proxy`: cert issuance must be available
  before edge and workload TLS artifacts are applied.
- `keycloak` before `openbao_oidc`: OpenBao OIDC wiring requires a live issuer.
- `envoy_proxy` runs after upstream services exist so routes/clusters resolve
  cleanly on first apply.
- `readiness_check` runs last and is skipped in check mode.

`playbooks/bootstrap.yml` is intentionally separate and privileged: it creates
projects, service accounts, and cluster-scoped grants needed before scoped
automation can run safely.

## Secrets flow

OpenBao KV v2 (`secret/`) is the source of truth for generated credentials.
The playbook writes KV values and then applies Kubernetes Secrets directly where
needed.

```
Ansible (generate/read) -> OpenBao KV v2 -> Kubernetes Secret apply
secret/keycloak/db                         -> keycloak-db-secret
secret/keycloak/realm-admin                -> keycloak-realm-admin
secret/keycloak/bootstrap-admin            -> keycloak-bootstrap-admin
```

This branch does not use Vault Secrets Operator resources for sync. Rotation
sync loops are out of scope; re-run the relevant playbook tags to refresh
secrets after a rotation event.

Ansible automation authenticates to OpenBao with a scoped periodic
`ansible-provisioner` token (`/opt/openbao/provisioner-token.yml`, vaulted).
Root token usage is reserved for bootstrap and break-glass paths.

## PKI and trust

OpenBao is the CA source. cert-manager consumes OpenBao-backed ClusterIssuers
for internal/external certificates.

High-level PKI model:

```
pki-root
  |- pki-int  (internal service certs)
  '- pki-ext  (public edge certs)
```

The OpenBao CA secret is copied into namespaces that need trust anchors for
service-to-service or controller-to-service TLS validation.

## Identity and OIDC

Keycloak (realm `armory`) is the identity provider used by OpenBao OIDC auth.
Keycloak bootstrap/admin and realm credentials are generated and stored in
OpenBao KV, with required Kubernetes Secrets materialized by Ansible.

OpenBao UI authentication uses OIDC redirect to Keycloak and applies OpenBao
policies according to configured user/group mapping.

## Network and edge

OpenShift Routes are the external entry point, and each Route uses
`termination: reencrypt` to hand traffic to the in-namespace Envoy service over
TLS. This two-hop shape is deliberate: OpenShift's router is HAProxy-based and
does not provide the trace-context boundary behavior this stack requires.

The Envoy layer is therefore the explicit trust boundary for trace headers.
Traffic enters through Route and lands on Envoy, where boundary behavior is
enforced before proxying to Keycloak/OpenBao upstream services.

This is why the OpenShift migration kept Envoy in front of workloads rather than
replacing it with Route-only exposure.

Operational hostnames/domains are inventory-driven (`ARMORY_PUBLIC_DOMAIN`,
`armory_keycloak_host`, `armory_openbao_host`).

## Implementation conventions

- Prefer declarative `kubernetes.core.k8s` object apply for Kubernetes resources.
- Keep role defaults opinionated and move OpenShift-only invariants into defaults.
- Keep inventory variables for environment facts (domains, namespaces, labels,
  storage classes, and explicit feature toggles).
- Keep local validation first: `--syntax-check`, `--list-tasks`, `--check`,
  lint, and static grep gates before any real cluster execution.
