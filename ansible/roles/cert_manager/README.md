# cert_manager role

## Purpose
Reuse an existing cert-manager installation and provision the OpenBao-backed
ClusterIssuer used by cluster workloads.

## Supported platforms
- Fedora (all)

## Dependencies
- Runtime dependencies:
  - A Kubernetes/OpenShift cluster must be available.
  - cert-manager must already be installed in the cluster.
- Cross-role dependencies:
  - Requires OpenBao PKI and auth configuration from the `openbao` role.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `cert_manager_namespace` | `cert-manager` | Namespace for cert-manager release. |
| `cert_manager_release_name` | `cert-manager` | ServiceAccount name stem used by ClusterIssuer auth. |
| `cert_manager_openbao_cluster_addr` | `https://openbao.openbao.svc.cluster.local:8200` | In-cluster OpenBao URL for ClusterIssuer. |
| `cert_manager_openbao_cluster_issuers` | pki-int / pki-ext | PKI mounts + roles per ClusterIssuer. |
| `cert_manager_openbao_k8s_role` | `cert-manager` | OpenBao Kubernetes auth role name for cert-manager. |

## Task flow
1. Copy the OpenBao CA secret (`openbao-ca`) into the `cert-manager` namespace
  (`issuer.yml`). This copy always runs, including in declarative mode: this role
  executes before `trust_manager` in site.yml and anchors the trust chain, so it
  must self-bootstrap rather than depend on trust-manager-managed Secrets.
2. Apply OpenBao-backed ClusterIssuer and wait for Ready condition (`issuer.yml`).

Note: the cert-manager ServiceAccount's permission to mint a bound token for
itself (TokenRequest API, for OpenBao ClusterIssuers using ambient Kubernetes
auth) is **not** something this role manages. cert-manager's own install
already ships the `cert-manager-tokenrequest` Role/RoleBinding natively;
armory used to create a redundant copy under the same name, which briefly
deleted the live object on every bootstrap/teardown cycle until cert-manager's
own controller reconciled it back.

## Usage
```yaml
- hosts: all
  roles:
    - role: cert_manager
```

## Troubleshooting
- ClusterIssuer never becomes Ready.
  Action: verify OpenBao PKI mount/role values and OpenBao k8s auth role setup.
- ClusterIssuer reports `cannot create resource "serviceaccounts/token"`.
  Action: verify cert-manager's own `cert-manager-tokenrequest` Role and
  RoleBinding exist in the `cert-manager` namespace and bind the
  `cert-manager` ServiceAccount — this comes from the cert-manager install
  itself, not from armory. If missing, that's a cert-manager installation
  issue, not something to recreate here.
