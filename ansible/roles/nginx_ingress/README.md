# nginx_ingress role

## Purpose
Deploy ingress-nginx and provision ingress TLS resources backed by cert-manager/OpenBao PKI.

## Supported platforms
- Fedora (all)

## Dependencies
- Runtime dependencies:
  - k3s cluster must be available.
  - Helm must be installed.
- Cross-role dependencies:
  - Requires `cert_manager` and OpenBao PKI to be configured before TLS provisioning.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `nginx_ingress_namespace` | `ingress-nginx` | Namespace for ingress-nginx release and TLS certificate resource. |
| `nginx_ingress_release_name` | `ingress-nginx` | Helm release name for ingress-nginx. |
| `nginx_ingress_chart_repo` | `https://kubernetes.github.io/ingress-nginx` | ingress-nginx chart repository. |
| `nginx_ingress_chart_name` | `ingress-nginx` | ingress-nginx chart name. |
| `nginx_ingress_chart_version` | `""` | Chart version override; empty uses latest. |
| `nginx_ingress_domain` | `{{ lookup('ansible.builtin.env', 'ARMORY_PUBLIC_DOMAIN') \| default('armory.local', true) }}` | Domain requested in TLS certificate. |
| `nginx_ingress_ip` | `{{ ansible_facts.default_ipv4.address \| default('127.0.0.1') }}` | Optional IP SAN and local `/etc/hosts` mapping target for `nginx_ingress_domain`. |
| `nginx_ingress_cert_duration` | `8760h` | Certificate duration requested from issuer. |
| `nginx_ingress_cert_renew_before` | `720h` | Renewal threshold before expiry. |
| `nginx_ingress_firewall_manage` | `true` | Whether to open firewall ports `80/tcp` and `443/tcp`. |
| `nginx_ingress_firewall_zone` | `public` | firewalld zone for ingress HTTP/HTTPS rules. |

## Task flow
1. Install ingress-nginx via Helm with host networking enabled and an internal `ClusterIP` Service (`install.yml`).
2. Open firewall rules for ingress ports 80/443 when enabled (`install.yml`).
3. Apply ingress TLS Certificate resource (`tls.yml`).
4. Wait until TLS certificate becomes Ready (`tls.yml`).

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
        nginx_ingress_ip: 10.0.0.25
```

## Troubleshooting
- certificate never becomes Ready.
  Action: validate `openbao-pki` ClusterIssuer status and cert-manager controller health.
- ingress reachable on pod/service but not domain.
  Action: verify DNS/hosts mapping for `nginx_ingress_domain`, firewall ports 80/443, and the node IP used for host-network ingress.
