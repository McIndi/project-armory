# nginx Ingress State — Armory

> nginx Ingress Controller replaces k3s's bundled Traefik. It is the single entry point for all external HTTP/HTTPS traffic to the cluster.

---

## Deployment

| Setting | Value |
|---|---|
| Namespace | `ingress-nginx` |
| Helm release | `ingress-nginx` (chart: `ingress-nginx/ingress-nginx`) |
| Controller service type | NodePort |
| HTTP NodePort | `30080` |
| HTTPS NodePort | `30443` |
| External IP | `192.168.0.150` (set via `externalIPs`) |
| Ingress class name | `nginx` |
| TLS certificate | `armory-tls` Secret in `ingress-nginx` ns (issued by cert-manager → OpenBao PKI) |

Clients on the local network reach nginx at `192.168.0.150:80` (HTTP, will redirect to HTTPS) and `192.168.0.150:443` (HTTPS). The `externalIPs` setting on the NodePort Service makes the standard ports work without specifying the NodePort number.

---

## TLS Configuration

| Setting | Value |
|---|---|
| Certificate resource | `armory-tls` (kind: `Certificate`) in `ingress-nginx` ns |
| Issuer | `openbao-pki` (kind: `ClusterIssuer`) |
| Issuer type | cert-manager Vault type → OpenBao `pki/sign/armory-dot-local` |
| DNS SAN | `armory.local` |
| IP SAN | `192.168.0.150` |
| Duration | 1 year (`8760h`) |
| Auto-renew before | 30 days (`720h`) |
| TLS Secret name | `armory-tls` |
| cert-manager auth to OpenBao | Kubernetes auth, role `cert-manager`, policy `cert-manager` |

cert-manager automatically renews the certificate 30 days before expiry. No manual rotation required.

---

## Current Ingress Rules

All rules use `ingressClassName: nginx` and reference the `armory-tls` Secret for TLS termination. SSL redirect is enforced (`nginx.ingress.kubernetes.io/ssl-redirect: "true"`).

### `agentstack-ui` — BeeAI User Interface

| Field | Value |
|---|---|
| Namespace | `agentstack` |
| Host | `armory.local` |
| Path | `/` (Prefix) |
| Backend service | `agentstack-ui:3000` |
| TLS | `armory-tls` |

### `agentstack-api` — BeeAI REST API

| Field | Value |
|---|---|
| Namespace | `agentstack` |
| Host | `armory.local` |
| Path | `/api(/|$)(.*)` (ImplementationSpecific, with rewrite) |
| Rewrite target | `/$2` |
| Backend service | `agentstack:8080` |
| TLS | `armory-tls` |

The rewrite strips the `/api` prefix before forwarding to the backend so the API service sees requests at its root paths.

### `agentstack-keycloak` — Keycloak OIDC Endpoints

| Field | Value |
|---|---|
| Namespace | `agentstack` |
| Host | `armory.local` |
| Path | `/realms` (Prefix) |
| Backend service | `agentstack-keycloak:8080` |
| TLS | `armory-tls` |

---

## Traffic Flow

```
Client (browser / curl)
  │
  ▼ 192.168.0.150:443 (HTTPS)
nginx NodePort Service (30443)
  │  TLS terminated here, cert from OpenBao PKI
  ▼
nginx Ingress Controller Pod
  │
  ├─ Host: armory.local, Path: /          → agentstack-ui:3000    (BeeAI UI)
  ├─ Host: armory.local, Path: /api/*     → agentstack:8080       (BeeAI API)
  └─ Host: armory.local, Path: /realms/*  → agentstack-keycloak:8080 (Keycloak)
```

HTTP requests (`192.168.0.150:80` / NodePort `30080`) are redirected to HTTPS by nginx.

---

## Firewall Rules (added by `nginx_ingress` role)

| Port/Proto | NodePort | Purpose |
|---|---|---|
| `30080/tcp` | HTTP | Redirect to HTTPS |
| `30443/tcp` | HTTPS | TLS-terminated application traffic |

---

## Client Trust

To reach `https://armory.local` without certificate warnings, clients need:

1. **DNS / hosts entry:** Add `192.168.0.150 armory.local` to `/etc/hosts` (or local DNS)
2. **CA trust:** Install the `Armory Root CA` certificate (retrievable from OpenBao at `http://127.0.0.1:32200/v1/pki/ca/pem` from the VM) into the client's trust store

For `curl` without installing the CA:
```bash
# Download CA from OpenBao (run from VM or where port 32200 is reachable)
curl -s http://127.0.0.1:32200/v1/pki/ca/pem -o armory-ca.pem

# Use with curl
curl --cacert armory-ca.pem https://armory.local/
```

---

## Potential Future Use Cases

### Additional Hostnames
nginx can serve multiple virtual hosts on the same IP. Adding a second domain (e.g., `vault.armory.local` for OpenBao UI, `grafana.armory.local`) requires only a new `Certificate` resource and a new `Ingress` resource. The `openbao-pki` ClusterIssuer handles cert issuance automatically for any domain matching `*.armory.local` (subdomains allowed in the PKI role).

### Path-Based Routing for Additional Services
Any new service deployed to k3s can be exposed by adding an `Ingress` resource with `ingressClassName: nginx`. No changes to the controller or TLS configuration required.

### Rate Limiting
nginx Ingress supports rate limiting via annotations:
```yaml
nginx.ingress.kubernetes.io/limit-rps: "10"
nginx.ingress.kubernetes.io/limit-connections: "5"
```
Useful for the BeeAI API endpoint to prevent abuse in demo environments.

### Basic Auth Overlay
A quick way to add an authentication layer in front of any service without modifying the application:
```yaml
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: basic-auth-secret
nginx.ingress.kubernetes.io/auth-realm: "Armory — Authentication Required"
```

### Upstream TLS (Backend Encryption)
Currently all backend connections are plain HTTP (in-cluster). If BeeAI services are configured to serve TLS, the Ingress can be annotated to use HTTPS upstream:
```yaml
nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
```

### WebSocket Support
The BeeAI API may use WebSockets for agent streaming. nginx Ingress supports WebSocket proxying natively; no extra configuration is needed unless timeouts require tuning:
```yaml
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

### CORS Headers
If the BeeAI UI is accessed from a different origin (e.g., during development), CORS headers can be injected by nginx:
```yaml
nginx.ingress.kubernetes.io/enable-cors: "true"
nginx.ingress.kubernetes.io/cors-allow-origin: "https://armory.local"
```

### Custom Error Pages
nginx can serve custom 4xx/5xx pages from a ConfigMap, providing a consistent branded experience even when backends are down.

### ModSecurity WAF
The nginx Ingress Helm chart supports enabling ModSecurity as a Web Application Firewall via `controller.modsecurity.enabled: true`. Adds OWASP Core Rule Set protection to all ingress routes.

### Observability
nginx Ingress exposes Prometheus metrics at `/metrics` on port `10254` of the controller pod. Adding a `ServiceMonitor` (if Prometheus Operator is deployed) would capture request rates, error rates, and latency per Ingress rule.

---

## Known Constraints

| Constraint | Detail |
|---|---|
| Single-node, no HA | One controller pod. If the node restarts, nginx is unavailable until k3s reschedules the pod. |
| NodePort external access | Standard ports 80/443 work via `externalIPs`, but this is a k3s single-node workaround — not a proper load balancer. MetalLB would be the next step for a more robust setup. |
| CA not trusted by default | Browsers and tools will show certificate warnings until the Armory Root CA is installed in the client trust store. |
| Keycloak path routing | Only `/realms` prefix is routed to Keycloak. The Keycloak admin console path (`/admin`) is not currently exposed via Ingress — access requires port-forwarding or a separate Ingress rule. |
