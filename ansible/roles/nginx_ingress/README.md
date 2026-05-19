# nginx_ingress role

## Purpose
Deploy cert-manager and ingress-nginx, then provision TLS resources backed by OpenBao PKI.

## Supported platforms
- Fedora (all)

## Dependencies
- Runtime dependencies:
  - k3s cluster must be available.
  - Helm must be installed.
- Cross-role dependencies:
  - Requires OpenBao PKI to be configured before TLS provisioning.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `nginx_ingress_namespace` | `ingress-nginx` | Namespace for ingress-nginx release and TLS certificate resource. |
| `nginx_ingress_release_name` | `ingress-nginx` | Helm release name for ingress-nginx. |
| `nginx_ingress_chart_repo` | `https://kubernetes.github.io/ingress-nginx` | ingress-nginx chart repository. |
| `nginx_ingress_chart_name` | `ingress-nginx` | ingress-nginx chart name. |
| `nginx_ingress_chart_version` | `""` | Chart version override; empty uses latest. |
| `certmanager_namespace` | `cert-manager` | Namespace for cert-manager release. |
| `certmanager_release_name` | `cert-manager` | Helm release name for cert-manager. |
| `certmanager_chart_repo` | `https://charts.jetstack.io` | cert-manager chart repository. |
| `certmanager_chart_name` | `cert-manager` | cert-manager chart name. |
| `certmanager_chart_version` | `""` | Chart version override; empty uses latest. |
| `nginx_ingress_domain` | `armory.local` | Domain requested in TLS certificate. |
| `nginx_ingress_ip` | `192.168.0.150` | Optional IP SAN and local `/etc/hosts` mapping target for `armory.local`. |
| `nginx_openbao_cluster_addr` | `http://openbao.openbao.svc.cluster.local:8200` | In-cluster OpenBao URL for ClusterIssuer. |
| `nginx_openbao_pki_mount` | `pki` | PKI mount path used by cert-manager issuer. |
| `nginx_openbao_pki_cert_role` | `armory-dot-local` | PKI role used for certificate requests. |
| `nginx_openbao_certmanager_k8s_role` | `cert-manager` | OpenBao Kubernetes auth role name for cert-manager. |
| `nginx_ingress_cert_duration` | `8760h` | Certificate duration requested from issuer. |
| `nginx_ingress_cert_renew_before` | `720h` | Renewal threshold before expiry. |
| `nginx_ingress_firewall_manage` | `true` | Whether to open firewall ports `80/tcp` and `443/tcp`. |
| `nginx_ingress_firewall_zone` | `public` | firewalld zone for ingress HTTP/HTTPS rules. |

## Task flow
1. Install cert-manager via Helm and wait for webhook readiness (`install.yml`).
2. Install ingress-nginx via Helm with service type `LoadBalancer` (`install.yml`).
3. Open firewall rules for ingress ports 80/443 when enabled (`install.yml`).
4. Apply OpenBao-backed ClusterIssuer and Certificate resources (`tls.yml`).
5. Wait until TLS certificate becomes Ready (`tls.yml`).

## Usage
```yaml
- hosts: all
  roles:
    - role: nginx_ingress
```

Override example:
```yaml
- hosts: all
  roles:
    - role: nginx_ingress
      vars:
        nginx_ingress_domain: apps.example.local
        nginx_ingress_ip: 192.168.0.200
```

## Troubleshooting
- cert-manager webhook does not become available.
  Action: inspect cert-manager pod status and logs in `cert-manager` namespace.
- certificate never becomes Ready.
  Action: validate OpenBao PKI mount/role settings and ClusterIssuer status.
- ingress reachable on pod/service but not domain.
  Action: verify DNS/hosts mapping for `nginx_ingress_domain`, firewall ports 80/443, and ingress service EXTERNAL-IP.
