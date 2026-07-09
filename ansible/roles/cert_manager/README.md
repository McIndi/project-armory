# cert_manager role

## Purpose
Deploy cert-manager and provision the OpenBao-backed ClusterIssuer used by
cluster workloads.

## Supported platforms
- Fedora (all)

## Dependencies
- Runtime dependencies:
  - k3s cluster must be available.
  - Helm must be installed.
- Cross-role dependencies:
  - Requires OpenBao PKI and auth configuration from the `openbao` role.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `certmanager_namespace` | `cert-manager` | Namespace for cert-manager release. |
| `certmanager_release_name` | `cert-manager` | Helm release name for cert-manager. |
| `certmanager_chart_repo` | `https://charts.jetstack.io` | cert-manager chart repository. |
| `certmanager_chart_name` | `cert-manager` | cert-manager chart name. |
| `certmanager_chart_version` | `""` | Chart version override; empty uses latest. |
| `certmanager_tofu_timeout_seconds` | `600` | Helm wait timeout for cert-manager install/upgrade. |
| `certmanager_tofu_chart_values` | `crds.enabled=true` | Helm values for cert-manager release. |
| `certmanager_openbao_cluster_addr` | `https://openbao.openbao.svc.cluster.local:8200` | In-cluster OpenBao URL for ClusterIssuer. |
| `certmanager_openbao_cluster_issuers` | pki-int / pki-ext | PKI mounts + roles per ClusterIssuer. |
| `certmanager_openbao_k8s_role` | `cert-manager` | OpenBao Kubernetes auth role name for cert-manager. |

## Task flow
1. Install cert-manager via Helm and wait for webhook readiness (`install.yml`).
2. Grant the cert-manager ServiceAccount permission to mint a bound token for
  itself via the TokenRequest API so OpenBao ClusterIssuers using ambient
  Kubernetes auth can authenticate (`rbac.yml`).
3. Copy the OpenBao CA secret (`openbao-ca`) into the `cert-manager` namespace
  (`issuer.yml`). This copy always runs, including in declarative mode: this role
  executes before `trust_manager` in site.yml and anchors the trust chain, so it
  must self-bootstrap rather than depend on trust-manager-managed Secrets.
4. Apply OpenBao-backed ClusterIssuer and wait for Ready condition (`issuer.yml`).

## Usage
```yaml
- hosts: all
  roles:
    - role: cert_manager
```

## Troubleshooting
- cert-manager webhook does not become available.
  Action: inspect cert-manager pod status and logs in `cert-manager` namespace.
- ClusterIssuer never becomes Ready.
  Action: verify OpenBao PKI mount/role values and OpenBao k8s auth role setup.
- ClusterIssuer reports `cannot create resource "serviceaccounts/token"`.
  Action: verify the `cert-manager-tokenrequest` Role and RoleBinding exist in
  the `cert-manager` namespace and bind the `cert-manager` ServiceAccount.
