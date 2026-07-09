# 0009 — Replace ingress-nginx with Envoy Gateway; trace identity minted at the edge

Status: implemented

## Context

ingress-nginx is retired/maintenance-mode upstream, and the stack needed a
Gateway API edge. Separately, the edge honored inbound W3C Trace Context
(`traceparent`/`tracestate`/`baggage`), letting untrusted callers control
trace identity and sampling on unauthenticated paths — worst on the Keycloak
login routes, where a forced `sampled=1` or colliding trace-id enables
denial-of-monitoring and audit pollution.

## Decision

Adopt **Envoy Gateway** (`gateway.envoyproxy.io/gatewayclass-controller`).
Cilium was rejected (requires replacing flannel on k3s); Traefik and NGINX
Gateway Fabric were rejected for a weaker tracing-policy surface. k3s's
bundled Traefik stays disabled (`k3s_disable`).

The gateway is the **trust boundary for trace identity** — identity is minted
at the boundary, never accepted from outside (the same principle as
AppRole/dynamic credentials for non-human identity):

- A `ClientTrafficPolicy` with `earlyRequestHeaders` strips
  `traceparent`, `tracestate`, `baggage`, and `b3`/legacy headers before the
  tracing decision, uniformly on all external routes — no per-route exception
  list (closes the forgotten-unauthenticated-route failure mode).
- The gateway mints a random trace-id; its span is the trace root. Sampling
  (100%) is decided at the gateway, never from an inbound flag. Internal
  propagation behind the perimeter is untouched.
- The inbound `traceparent` is copied to `x-external-traceparent` first and
  recorded as span attribute `external.traceparent` — forensic correlation
  without trusting the identifier.
- OIDC login-flow requests each get their own trace (correct per spec);
  login attempts correlate via Keycloak event `session_id`, not by preserving
  a browser-controlled trace-id across redirects.
- Authenticated machine callers may later honor inbound context via a
  dedicated mTLS listener gated on the auth signal (deferred).

Structure: `GatewayClass`/`Gateway`/`EnvoyProxy`/`ClientTrafficPolicy` and the
consolidated edge cert belong to the `envoy_gateway` role (edge-tls-admin);
per-workload `HTTPRoute` + `BackendTLSPolicy` belong to the owning roles.
Since k3s also disables `servicelb`, the Envoy Service is ClusterIP patched
with the node IP as `externalIP` (replacing nginx's hostNetwork arrangement).
Backend re-encryption is now verified: each workload mirrors its serving
cert's issuing CA into a ConfigMap for `BackendTLSPolicy` validation (the old
nginx edge never verified backends).

## Consequences

One consolidated edge certificate (all public hosts + IP SAN) lives in the
gateway namespace; per-workload edge certs are gone. In-cluster resolution of
the public issuer host now targets the label-resolved Envoy Service
(`common/tasks/lookup_gateway_service.yml`) instead of a fixed
`ingress-nginx-controller` name. The readiness suite gained a trace-boundary
stage that forges an external trace context and asserts strip/mint/capture
against an ephemeral echo backend. Gateway spans ship to a minimal in-cluster
OTLP collector (debug exporter) until a real trace store lands.
