# headlamp Ansible Role

This role automates the deployment and integration of the Headlamp Kubernetes dashboard into the BeeAI Agent Stack. It provides:
- Automated deployment via Helm/OpenTofu
- External HTTPS access via nginx ingress
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
- nginx ingress: External HTTPS exposure
- k3s: Cluster-wide RBAC for admin users

## Tasks
- Create/update Keycloak OIDC client for Headlamp
- Persist effective OIDC credentials in OpenBao KV
- Configure OpenBao policy and auth role for Headlamp VSO sync
- Issue Headlamp ingress TLS certificate via cert-manager + OpenBao
- Deploy Headlamp Helm chart with OpenTofu
- Validate readiness through the shared readiness_check role

## Variables
See `defaults/main.yml` for configurable options, including ingress host,
OIDC realm/client, OpenBao paths, and plugin-manager settings.

## Usage
Include this role after `beeai_agentstack_tofu` so Keycloak is already deployed.
