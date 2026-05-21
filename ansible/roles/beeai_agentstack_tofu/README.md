# beeai_agentstack_tofu role

## Purpose
Deploy BeeAI Agent Stack using OpenTofu and Helm, with credentials sourced from OpenBao and synced through Vault Secrets Operator (VSO).

## Supported platforms
- Fedora (all)

## Dependencies
- Runtime dependencies:
  - k3s cluster must be available.
  - Helm and OpenTofu must be installed.
- Cross-role dependencies:
  - `openbao` role must run first to create BeeAI credentials and encryption key.
  - `nginx_ingress` should run before this role if ingress TLS endpoints are required immediately.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `beeai_tofu_work_dir` | `/opt/beeai-agentstack-tofu` | Working directory for OpenTofu files and state operations. |
| `beeai_vso_tofu_work_dir` | `/opt/beeai-vso-tofu` | Working directory for the VSO (Vault Secrets Operator) OpenTofu state. |
| `beeai_tofu_kubeconfig_path` | `/etc/rancher/k3s/k3s.yaml` | Kubeconfig used for kubectl/helm/tofu operations. |
| `beeai_firewall_manage` | `false` | Whether to manage firewalld for BeeAI-specific ports. |
| `beeai_firewall_zone` | `public` | firewalld zone used when firewall management is enabled. |
| `beeai_firewall_ports` | `[]` | Explicit ports to open when firewall management is enabled. |
| `beeai_tofu_release_name` | `agentstack` | Helm release name managed via OpenTofu. |
| `beeai_tofu_namespace` | `agentstack` | Namespace where agentstack resources are deployed. |
| `beeai_tofu_create_namespace` | `true` | Whether to create namespace during Helm deployment. |
| `beeai_tofu_chart_repository` | `oci://ghcr.io/i-am-bee/agentstack/chart` | Helm chart repository URI. |
| `beeai_tofu_chart_name` | `agentstack` | Helm chart name. |
| `beeai_tofu_chart_version` | `""` | Chart version override; empty uses latest. |
| `beeai_tofu_timeout_seconds` | `1200` | Helm timeout passed via OpenTofu variables. |
| `beeai_tofu_wait` | `true` | Wait for resources during Helm operation. |
| `beeai_tofu_atomic` | `false` | Enable atomic Helm install/upgrade behavior. |
| `beeai_tofu_cleanup_on_fail` | `false` | Enable Helm cleanup on failed operation. |
| `beeai_admin_username` | `admin` | Seeded BeeAI/Keycloak admin username. |
| `beeai_admin_email` | `admin@armory.local` | Seeded BeeAI/Keycloak admin email. |
| `beeai_admin_first_name` | `Admin` | Seeded BeeAI/Keycloak admin first name. |
| `beeai_admin_last_name` | `User` | Seeded BeeAI/Keycloak admin last name. |
| `beeai_vso_chart_repo` | `https://helm.releases.hashicorp.com` | Helm repository for VSO chart. |
| `beeai_vso_release_name` | `vault-secrets-operator` | VSO Helm release name. |
| `beeai_vso_chart_name` | `vault-secrets-operator` | VSO chart name. |
| `beeai_vso_chart_version` | `""` | VSO chart version override. |
| `beeai_vso_namespace` | `vault-secrets-operator-system` | Namespace for VSO deployment. |
| `beeai_openbao_cluster_addr` | `https://openbao.openbao.svc.cluster.local:8200` | OpenBao address used by VSO connection resources. |
| `beeai_openbao_tls_server_name` | `openbao.openbao.svc.cluster.local` | TLS server name used by VSO VaultConnection resources. |
| `beeai_openbao_ca_secret_name` | `openbao-ca` | Secret name containing the OpenBao CA in each consuming namespace, including the VSO namespace. |
| `beeai_openbao_vso_sa_name` | `beeai-vso` | Service account name bound in OpenBao role config. |
| `beeai_openbao_k8s_role` | `beeai-vso` | OpenBao Kubernetes auth role name for VSO. |
| `beeai_vso_credentials_secret` | `beeai-credentials` | Destination k8s secret for BeeAI credentials. |
| `beeai_vso_enckey_secret` | `beeai-encryption-key` | Destination k8s secret for encryption key. |
| `beeai_public_base_url` | `https://armory.local` | External URL used in chart values. |
| `beeai_oidc_internal_issuer_url` | `{{ beeai_public_base_url }}/realms/agentstack` | HTTPS OIDC issuer forced into UI deployment. |
| `beeai_ui_deployment_name` | `agentstack-ui` | UI deployment name targeted by post-apply patch. |
| `beeai_oidc_resolver_host` | `{{ beeai_public_base_url \| urlsplit('hostname') }}` | Hostname added to UI pod hostAliases for issuer resolution. |
| `beeai_oidc_resolver_ip` | `{{ nginx_ingress_ip \| default(ansible_facts.default_ipv4.address \| default('127.0.0.1')) }}` | IP mapped to resolver host inside UI pod. |
| `beeai_oidc_ca_secret_name` | `armory-tls` | Secret containing CA chain used to validate issuer TLS certs from UI pod. |
| `beeai_oidc_ca_secret_key` | `ca.crt` | Secret key mounted as trusted CA file. |
| `beeai_oidc_ca_mount_path` | `/etc/armory-ca` | Mount path for CA secret inside UI container. |
| `beeai_oidc_ca_file_path` | `{{ beeai_oidc_ca_mount_path }}/{{ beeai_oidc_ca_secret_key }}` | File path exported via `NODE_EXTRA_CA_CERTS`. |
| `beeai_ui_secret_name` | `agentstack-ui-secret` | UI secret name that stores Auth.js shared secret material. |
| `beeai_ui_auth_secret_key` | `authSecret` | Secret key used for both `NEXTAUTH_SECRET` and `AUTH_SECRET`. |
| `beeai_ui_auth_trust_host` | `true` | Sets `AUTH_TRUST_HOST` for Auth.js when behind ingress/proxy. |
| `beeai_ui_trust_proxy_headers` | `true` | Enables trusted forwarded headers in UI pod runtime. |
| `beeai_server_deployment_name` | `agentstack-server` | API deployment name targeted by post-apply auth patch. |
| `beeai_server_oidc_issuer_url` | `{{ beeai_public_base_url }}/realms/agentstack` | API OIDC issuer URL (set to HTTPS public issuer). |
| `beeai_server_oidc_external_issuer_url` | `{{ beeai_public_base_url }}/realms/agentstack` | API external issuer used in auth metadata/challenges. |
| `beeai_server_oidc_insecure_transport` | `false` | Enables/disables insecure OIDC transport in API pod. |
| `beeai_server_trust_proxy_headers` | `true` | Trust forwarded proto/host from ingress for generated auth metadata URLs. |
| `beeai_ingress_class` | `nginx` | Ingress class expected by chart values/templates. |
| `beeai_ingress_tls_secret` | `armory-tls` | TLS secret referenced by ingress resources. |
| `beeai_tofu_chart_values` | map | Base chart values map merged with generated credentials at runtime. |
| `beeai_api_service_name` | `agentstack-server-svc` | API service name used by ingress template. |
| `beeai_api_service_port` | `8333` | API service port used by ingress template. |
| `beeai_ui_service_name` | `agentstack-ui-svc` | UI service name used by ingress template. |
| `beeai_ui_service_port` | `8334` | UI service port used by ingress template. |
| `beeai_keycloak_service_name` | `keycloak` | Keycloak service name used by ingress template. |
| `beeai_keycloak_service_port` | `8336` | Keycloak service port used by ingress template. |

## Task flow
1. Install/upgrade Vault Secrets Operator and ensure the VSO namespace has the OpenBao CA trust secret before the default VaultConnection is rendered.
2. Apply `VaultConnection`, `VaultAuth`, and `VaultStaticSecret` manifests.
3. Wait for VSO-synced k8s secrets (`beeai-credentials`, `beeai-encryption-key`).
4. Read secret data into Ansible facts (no local credentials file).
5. Render OpenTofu files (`main.tf`, `terraform.tfvars.json`) and initialize OpenTofu.
6. Handle stale Helm/PVC conditions before apply.
7. Apply OpenTofu deployment (first and second pass if needed).
8. Fix Keycloak OIDC audience mapper (`tasks/keycloak_oidc_fix.yml`) — sets
   `agentstack-server-audience` scope mapper to `aud: agentstack-server` and assigns
   it as a default scope on the `agentstack-ui` client. Runs after every deploy
   because the Helm `keycloak-provision` hook overwrites Keycloak config on upgrade.
9. Apply ingress resources.

## Usage
```yaml
- hosts: all
  roles:
    - role: beeai_agentstack_tofu
```

Override example:
```yaml
- hosts: all
  roles:
    - role: beeai_agentstack_tofu
      vars:
        beeai_public_base_url: https://apps.example.local
        beeai_tofu_chart_version: 0.0.0
```

## Troubleshooting
- Missing `beeai-credentials` or `beeai-encryption-key` secrets.
  Action: verify OpenBao role ran successfully and VSO auth resources are valid.
- OpenTofu apply fails.
  Action: inspect files in `beeai_tofu_work_dir` and run `tofu plan` manually for diagnostics.
- UI ingress or auth behavior is incorrect.
  Action: verify `beeai_public_base_url`, ingress TLS secret, and service names/ports align with deployed chart outputs.
