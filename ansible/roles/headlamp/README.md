# headlamp Ansible Role

This role automates deployment and integration of the Headlamp Kubernetes dashboard. It provides:
- Automated deployment via Helm
- External HTTPS access via the Envoy gateway (HTTPRoute)
- OIDC authentication with Keycloak (automated client setup)
- PKI/TLS management via OpenBao through cert-manager
- Out-of-the-box visibility into k3s and stack components
- Optional plugin-manager support for additional observability plugins

## Default official plugin set

The role enables Headlamp's plugin manager by default with:
- `cert-manager` (official) for cert and issuer visibility

This is intentionally conservative for clean-environment reliability.
You can extend `headlamp_plugins` in inventory/group vars with additional
official plugins from Artifact Hub.

## Integration Points
- Keycloak: OIDC client automation, RBAC mapping
- OpenBao: OIDC secret persistence and VSO sync into Kubernetes
- cert-manager: TLS certificate issuance using OpenBao ClusterIssuer
- envoy_gateway: External HTTPS exposure (edge TLS + trace boundary)
- k3s: Cluster-wide RBAC for admin users

Headlamp also serves HTTPS on the in-cluster service hop using the
`headlamp-internal-tls` certificate issued by `openbao-pki-internal`.
Edge TLS terminates at the gateway; a `BackendTLSPolicy` makes the gateway
re-encrypt to Headlamp's HTTPS service and verify its serving cert.

## Tasks
- Create/update Keycloak OIDC client for Headlamp
- Persist effective OIDC credentials in OpenBao KV
- Configure OpenBao policy and auth role for Headlamp VSO sync
- Issue Headlamp internal serving certificate via cert-manager + OpenBao
- Deploy Headlamp Helm chart directly with Helm
- Validate readiness through the shared readiness_check role

## Internal TLS caller standard
- OIDC provisioning uses Keycloak's internal HTTPS endpoint
	`https://<service>.<namespace>.svc.cluster.local:8443`.
- The caller trust bundle is explicit: OpenBao root CA + internal issuer CA.
- The role now consumes `common/tasks/prepare_internal_https_caller.yml` so DNS
	override, CA extraction, and issuer retrieval are centralized and consistent.

When `use_declarative_ca_distribution: true`, this role expects the OpenBao CA
Secret to be delivered by trust-manager and skips manual namespace CA copy.

## Variables
See `defaults/main.yml` for configurable options, including ingress host,
OIDC realm/client, OpenBao paths, and plugin-manager settings.

## Usage
Include this role after `keycloak` so OIDC resources are already deployed.
