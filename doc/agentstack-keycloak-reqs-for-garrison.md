# Agent Stack + External Keycloak — Requirements for project-garrison

Status: **updated** (extraction complete as of current repo state; open items resolved below)
Audience: whoever builds project-garrison to deploy the BeeAI/Agent Stack Helm
chart against an **external** Keycloak provided by project-armory.
Companion: [`keycloak-extraction-plan.md`](keycloak-extraction-plan.md) (armory side).

## 0. Current Armory State (updated)

The Keycloak extraction described in the companion doc is **complete**. Key facts
that change or refine what garrison must do:

- `beeai_agentstack_tofu` role has been **deleted** from armory. It does not
  exist in the repo. Anything it did that garrison needs is documented here.
- Armory runs a standalone **Keycloak Operator** deployment (`keycloak` role,
  `keycloak` namespace). The CR name is `keycloak`; the operator-created Service
  is `keycloak-service.keycloak.svc.cluster.local`.
- k3s API-server OIDC and Headlamp both now point at the `armory` realm
  (`k3s_oidc_issuer_url: .../realms/armory`, `headlamp_keycloak_realm: armory`).
  The `agentstack` realm does **not** exist in armory — it is entirely garrison's
  responsibility.
- The armory admin credential secret is `keycloak-bootstrap-admin` in the
  `keycloak` namespace, with keys `username` and `password`. Username value:
  `armory-admin`. This is the **master admin** for the master realm; garrison uses
  it to bootstrap the `agentstack` realm via the admin REST API.

## 1. Context

Agent Stack is moving out of project-armory into project-garrison. armory will
run a standalone Keycloak as a shared identity provider. Garrison will deploy
the Agent Stack chart with its bundled Keycloak **disabled**
(`keycloak.enabled: false`) and point it at armory's Keycloak via the chart's
`externalOidcProvider` settings.

The chart supports this mode. The catch: **in external mode the chart provisions
nothing in Keycloak** — it assumes a realm and pre-configured clients already
exist. Everything the bundled Keycloak used to set up automatically becomes
garrison's responsibility. This document enumerates that responsibility, plus
the in-cluster issuer/TLS engineering armory currently performs that garrison
will need to reproduce.

Values quoted below are verbatim from the chart
([`helm/values.yaml`](https://github.com/i-am-bee/beeai-platform/blob/main/helm/values.yaml),
[`helm/Chart.yaml`](https://github.com/i-am-bee/beeai-platform/blob/main/helm/Chart.yaml)).

## 2. The chart's external-OIDC contract

Setting `keycloak.enabled: false` activates `externalOidcProvider`:

```yaml
externalOidcProvider:
  issuerUrl: ""                       # OIDC issuer (realm) URL
  name: "OIDC"
  id: "oidc"
  rolesPath: "realm_access.roles"     # where roles are read from in the token
  uiClientId: "agentstack-ui"
  uiClientSecret: ""
  uiClientSecretKey: "uiClientSecret" # key within existingSecret
  serverClientId: "agentstack-server"
  serverClientSecret: ""
  serverClientSecretKey: "serverClientSecret"
  existingSecret: ""                  # secret holding the two client secrets
```

Related flags that stay relevant in external mode:

```yaml
auth:
  validateAudience: true              # server validates aud == serverClientId
  nextauthSecret: ""
  nextauthUrl: "http://localhost:8334"
  apiUrl: "http://localhost:8333"
encryptionKey: ""                     # still required
```

Chart dependencies (none is Keycloak — confirms external mode is first-class):
`common`, `postgresql` (`postgresql.enabled`), `seaweedfs` (`seaweedfs.enabled`),
`phoenix-helm` (`phoenix.enabled`), `redis` (`redis.enabled`).

## 3. What the chart will NOT do in external mode

When `keycloak.enabled: false`, the chart does **not** create any of the
following. Garrison must provision them in armory's Keycloak (realm-import or
REST) before/with the Agent Stack release:

1. **The realm.** Create realm `agentstack` in armory's Keycloak.
   `externalOidcProvider.issuerUrl` must point at
   `https://<armory-host>/realms/agentstack`.
2. **The two clients.**
   - `agentstack-ui` — confidential, standard (authorization-code) flow; redirect
     URIs / web origins for the Agent Stack UI ingress host.
   - `agentstack-server` — the API/resource client; its client ID is the expected
     token audience.
   Client IDs must match `uiClientId` / `serverClientId`.
3. **Client secrets.** Generate secrets for both clients, set them on the Keycloak
   clients, and seed them into a k8s Secret referenced by
   `externalOidcProvider.existingSecret` under keys `uiClientSecret` and
   `serverClientSecret`. Garrison should reuse the OpenBao + VSO pattern armory
   uses today for credential delivery (see §6).
4. **The audience mapping.** The server validates `aud: agentstack-server`
   (`auth.validateAudience: true`). Tokens issued to `agentstack-ui` must carry
   that audience. In armory's old bundled setup the chart created the
   `agentstack-server-audience` client scope with the **wrong** audience and a
   post-install fixup corrected it. Garrison must bake the correct audience
   mapping in from the start:
   - a client scope (e.g. `agentstack-server-audience`) containing a protocol
     mapper with `protocolMapper: oidc-audience-mapper` and config
     `included.custom.audience: agentstack-server` (not the public base URL);
   - that scope assigned as a **default** scope on the `agentstack-ui` client, so
     tokens minted for the UI carry `aud: agentstack-server`;
   - this pairs with `auth.validateAudience: true` + `serverClientId: agentstack-server`
     on the server side (§2). Get all three consistent or the API returns 401.
5. **Roles + role mapping.** `rolesPath: realm_access.roles` means roles are read
   from the realm-access roles claim. Define the realm role(s) Agent Stack expects
   (at minimum `agentstack-admin`) so they appear in `realm_access.roles`.
6. **Seed users.** Create an admin user with `agentstack-admin` assigned in the
   `agentstack` realm.

## 4. In-cluster issuer + TLS engineering to reproduce

### 4.1 Dual issuer — RESOLVED

**This was §4.1's "top unknown". The pattern is now proven by armory's Headlamp
deployment and can be reused verbatim.**

Armory resolves the dual-issuer problem for Headlamp pods by injecting a
`hostAlias` into the Deployment that maps the public hostname (e.g. `armory.local`)
to the nginx ingress controller's in-cluster ClusterIP. This means pods use the
**public issuer URL** (`https://<armory-host>/realms/agentstack`) for all OIDC
operations — discovery, token validation, browser redirects — with no URL
divergence. The `hostname.strict: false` in the Keycloak CR prevents in-cluster
HTTP redirects to the public hostname.

Garrison must apply the same pattern to AgentStack UI and server pods:

```python
# Pseudocode — exact steps per armory's headlamp/tasks/deploy.yml lines 296–333
ingress_cluster_ip = kubectl get svc ingress-nginx-controller -n ingress-nginx \
                     -o jsonpath='{.spec.clusterIP}'

kubectl patch deployment <agentstack-ui> --type=strategic --patch '{
  "spec": {"template": {"spec": {
    "hostAliases": [{"ip": "<ingress_cluster_ip>",
                     "hostnames": ["<armory-host>"]}]
  }}}
}'
# Repeat for the agentstack server deployment
```

See [`headlamp/tasks/deploy.yml` lines 296–333](../ansible/roles/headlamp/tasks/deploy.yml)
for the exact idempotent Ansible implementation to copy.

### 4.2 Armory Keycloak is now HTTPS-only internally

**This is a significant change from what earlier notes described.**

The Keycloak CR in armory has `http.httpEnabled: false`. There is **no plain-HTTP
port 8080**. All in-cluster access — admin REST API calls, OIDC discovery, token
endpoints — goes through **HTTPS on port 8443** (`keycloak-service.keycloak.svc.cluster.local:8443`).

The internal TLS cert (`keycloak-internal-tls`) is issued by cert-manager from
the **`openbao-pki-internal` ClusterIssuer** (backed by OpenBao's `pki-int` mount).
Its SAN is `keycloak-service.keycloak.svc.cluster.local`.

**Implication for garrison**: Any in-cluster call garrison makes to armory's
Keycloak admin REST API (e.g. to provision the `agentstack` realm) must:
- Target `https://keycloak-service.keycloak.svc.cluster.local:8443`
- Present armory's **internal CA** (`GET /v1/pki-int/ca/pem` from OpenBao, or
  read the `openbao-ca` secret from the `keycloak` namespace) for cert validation.

The `prepare_internal_https_caller.yml` common task encapsulates this CA
acquisition pattern. See [`headlamp/tasks/oidc_client.yml` lines 1–22](../ansible/roles/headlamp/tasks/oidc_client.yml)
for a complete working example.

### 4.3 TLS trust — two CA roots required

Garrison pods need to trust **two separate CA chains** from armory's OpenBao PKI:

| Use | CA | OpenBao endpoint | Secret |
|---|---|---|---|
| In-cluster Keycloak admin REST API calls | Internal Issuing CA (`pki-int`) | `GET /v1/pki-int/ca/pem` | `openbao-ca` in `openbao` ns |
| OIDC discovery/token validation over public URL (browser + pod) | External Issuing CA (`pki-ext`) | `GET /v1/pki-ext/ca/pem` | CA embedded in `armory-tls` secret |

In practice: for Ansible provisioning tasks calling the internal API, use the
internal CA bundle. For AgentStack pods doing OIDC validation against the public
issuer URL (via the hostAlias → nginx path), use the external CA mounted as
`NODE_EXTRA_CA_CERTS` (or equivalent). The external CA signs the nginx ingress
`armory-tls` certificate.

trust-manager `Bundle` CRDs can distribute either CA bundle to garrison namespaces
without manual copying — the preferred approach at scale.

### 4.4 Proxy/trust flags

Armory's Keycloak CR sets `proxy.headers: xforwarded` and armory's nginx ingress
passes `X-Forwarded-*` headers. Garrison's UI/API ingress must also set these
headers (nginx does this by default when configured correctly). The flags
`AUTH_TRUST_HOST`, `TRUST_PROXY_HEADERS`, and `AUTH__OIDC__INSECURE_TRANSPORT`
that armory previously set on AgentStack pods via Deployment patches are no longer
managed in armory — garrison owns them.

## 5. Network / topology

**Same-cluster confirmed.** The current armory implementation uses cross-namespace
service DNS (`keycloak-service.keycloak.svc.cluster.local`) for all in-cluster
Keycloak access. The same-cluster topology is the working path.

- **Realm ownership**: Garrison owns the `agentstack` realm end-to-end. Armory's
  `armory` realm (used by Headlamp and k3s OIDC) has no dependency on it.
- **Theme**: Armory runs a stock Keycloak image (not `keycloak-themed`). The Agent
  Stack login theme is not present. If the themed login is desired, garrison or
  armory must import it separately. Cosmetic delta, not a blocker.
- **Separate-cluster path**: Not currently implemented. If garrison ever runs in a
  separate cluster, all Keycloak access goes via the public ingress
  (`https://<armory-host>/realms/agentstack`), DNS must resolve, and only the
  external CA is needed. The same-cluster internal API calls are replaced by
  ingress-routed calls, which requires the ingress to expose Keycloak admin
  endpoints (currently not done and not needed for same-cluster).

## 6. Carried-over assets garrison should reuse

- **Realm/client provisioning pattern**: The GET→POST/PUT idempotent REST pattern
  in [`headlamp/tasks/oidc_client.yml`](../ansible/roles/headlamp/tasks/oidc_client.yml)
  is the proven template for provisioning clients in armory's Keycloak.
  Adapt it to target the `agentstack` realm instead of `armory`.
- **Admin token acquisition**: Use the `keycloak-bootstrap-admin` Secret (keys:
  `username`, `password`) in the `keycloak` namespace. POST to
  `https://keycloak-service.keycloak.svc.cluster.local:8443/realms/master/protocol/openid-connect/token`
  with `client_id: admin-cli`, `grant_type: password`. Pass the internal CA
  bundle (`ca_path`) for TLS validation.
- **Credential delivery (OpenBao + VSO)**: The `VaultConnection` → `VaultAuth` →
  `VaultStaticSecret` pattern in [`keycloak/templates/`](../ansible/roles/keycloak/templates/)
  is the reference for storing client secrets in OpenBao KV and syncing them
  into k8s Secrets. Use the same pattern for `agentstack-ui` and `agentstack-server`
  client secrets, then reference the resulting Secret via
  `externalOidcProvider.existingSecret`.
- **Realm import (declarative)**: The `KeycloakRealmImport` CRD pattern in
  [`keycloak/templates/realmimport.yaml.j2`](../ansible/roles/keycloak/templates/realmimport.yaml.j2)
  is the preferred way to bootstrap a realm. Note the comment in that template:
  do **not** declare `clientScopes` in the import — it suppresses Keycloak's
  built-in scopes and breaks OIDC sign-in. Bootstrap the realm via import; add
  clients and scopes via REST after the realm exists.
- **hostAlias pattern**: [`headlamp/tasks/deploy.yml` lines 296–333](../ansible/roles/headlamp/tasks/deploy.yml)
  implements the ingress-IP hostAlias injection. Replicate for AgentStack pods.
- **Internal HTTPS caller setup**: [`common/tasks/prepare_internal_https_caller.yml`](../ansible/roles/common/tasks/prepare_internal_https_caller.yml)
  fetches the OpenBao internal CA and writes a trusted bundle to a temp path,
  ready for `ca_path:` in `ansible.builtin.uri` calls. Use this for all
  in-cluster Keycloak admin API calls.

## 7. Open items checklist

- [x] ~~Confirm `externalOidcProvider.issuerUrl` single-issuer handling vs the
      internal/external split (§4.1)~~ — **RESOLVED**: use public issuer URL
      everywhere + hostAlias injection for DNS resolution inside pods.
- [x] ~~Decide same-cluster vs separate-cluster topology (§5)~~ — **RESOLVED**:
      same-cluster confirmed.
- [ ] Define the `agentstack` realm: clients, secrets, audience scope+mapper,
      roles, seed admin (§3). This is garrison's primary build task.
- [x] ~~Establish CA-trust delivery from armory to garrison pods (§4.3)~~  —
      **RESOLVED**: internal CA (`pki-int`) for admin API calls; external CA
      (`pki-ext`) for OIDC validation over public URL. trust-manager `Bundle`
      CRDs are the preferred distribution mechanism.
- [ ] Confirm `existingSecret` shape: keys `uiClientSecret` / `serverClientSecret`.
      (Unchanged from original — verify against current chart version before building.)
- [ ] Validate `rolesPath: realm_access.roles` against the roles garrison defines.
- [ ] Decide whether to import the Agent Stack Keycloak login theme into armory's
      Keycloak, or accept the default theme. Coordinate with armory if importing.
- [ ] Confirm which proxy/trust env vars (`AUTH_TRUST_HOST`, `TRUST_PROXY_HEADERS`,
      `AUTH__OIDC__INSECURE_TRANSPORT`) are still required by the current Agent
      Stack chart version and set them on the appropriate deployments.
