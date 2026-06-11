# Agent Stack + External Keycloak — Requirements for project-garrison

Status: reference (evaluation stage — captures what is known, not a build plan)
Audience: whoever builds project-garrison to deploy the BeeAI/Agent Stack Helm
chart against an **external** Keycloak provided by project-armory.
Companion: [`keycloak-extraction-plan.md`](handoffs/keycloak-extraction-plan.md) (armory side).

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
will likely need to reproduce.

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

1. **The realm.** Pick a realm name (e.g. `agentstack`) and create it in armory's
   Keycloak. `externalOidcProvider.issuerUrl` must point at
   `https://<armory-host>/realms/<realm>`.
2. **The two clients.**
   - `agentstack-ui` — confidential, standard (authorization-code) flow; redirect
     URIs / web origins for the Agent Stack UI ingress host.
   - `agentstack-server` — the API/resource client; its client ID is the expected
     token audience.
   Client IDs must match `uiClientId` / `serverClientId`.
3. **Client secrets.** Generate secrets for both clients, set them on the Keycloak
   clients, and seed them into a k8s Secret referenced by
   `externalOidcProvider.existingSecret` under keys `uiClientSecret` and
   `serverClientSecret`. (Garrison should reuse the OpenBao + VSO pattern armory
   uses today for credential delivery.)
4. **The audience mapping.** The server validates `aud: agentstack-server`
   (`auth.validateAudience: true`). Tokens issued to `agentstack-ui` must carry
   that audience. In armory's current bundled setup the chart created the
   `agentstack-server-audience` client scope with the **wrong** audience and a
   post-install fixup corrects it ([`keycloak_oidc_fix.yml`](../ansible/roles/beeai_agentstack_tofu/tasks/keycloak_oidc_fix.yml)).
   Garrison must bake the correct audience mapping into its realm definition from
   the start (exact shape per [`keycloak_oidc_fix.yml`](../ansible/roles/beeai_agentstack_tofu/tasks/keycloak_oidc_fix.yml)):
   - a client scope (e.g. `agentstack-server-audience`) containing a protocol
     mapper with `protocolMapper: oidc-audience-mapper` and config
     `included.custom.audience: agentstack-server` (the chart ships this with the
     wrong value `= <public_base_url>`);
   - that scope assigned as a **default** scope on the `agentstack-ui` client, so
     tokens minted for the UI carry `aud: agentstack-server`;
   - this pairs with `auth.validateAudience: true` + `serverClientId: agentstack-server`
     on the server side (§2). Get all three consistent or the API returns 401.
5. **Roles + role mapping.** `rolesPath: realm_access.roles` means roles are read
   from the realm-access roles claim. Define the realm role(s) Agent Stack expects
   (at minimum `agentstack-admin`) so they appear in `realm_access.roles`.
6. **Seed users.** The bundled chart created an admin user via
   `keycloak.auth.seedAgentstackUsers` (unused in external mode). Garrison must
   create its admin user and assign `agentstack-admin` in armory's Keycloak realm.

## 4. In-cluster issuer + TLS engineering to reproduce

armory currently runs a set of Deployment patches on the Agent Stack UI and
server to make in-cluster OIDC work. With Keycloak now in a *different project*
(and reached over armory's TLS-terminating ingress), these concerns persist and
may grow. Garrison should expect to reproduce equivalents of
([`beeai_agentstack_tofu/tasks/main.yml:742`](../ansible/roles/beeai_agentstack_tofu/tasks/main.yml) onward).

> **armory-side facts now locked (per [`keycloak-operator-implementation-plan.md`](handoffs/keycloak-operator-implementation-plan.md)):**
> armory deploys Keycloak via the **Keycloak Operator** with **edge TLS**
> (`spec.http.httpEnabled: true`, TLS terminated at nginx, `spec.proxy.headers: xforwarded`).
> - In-cluster service: **`<cr-name>-service.keycloak.svc:8080`** (plain HTTP). The
>   old `keycloak:8336` is gone.
> - Public issuer: `https://<armory-host>/realms/agentstack` (garrison's realm),
>   served through nginx on `armory-tls`.
> - armory's own consumers use a **separate `armory` realm**; garrison owns the
>   `agentstack` realm exclusively.

1. **Dual issuer (internal vs external).** Browsers must be redirected to the
   public issuer; in-cluster token validation must reach a resolvable issuer.
   armory today sets `AUTH__OIDC__ISSUER` (internal) and
   `AUTH__OIDC__EXTERNAL_ISSUER` (public) on the server, and `OIDC_PROVIDER_ISSUER`
   on the UI. `externalOidcProvider` exposes a **single** `issuerUrl` — verify
   whether the chart's native external mode handles the internal/external split,
   or whether garrison must keep patching these env vars. **This is the top
   unknown.** Note: tokens embed the issuer they were minted under, so the
   internal and public issuer **strings must match** for signature/issuer
   validation — you cannot freely point validation at `…svc:8080` while browsers
   use the public host unless Keycloak is told they are the same issuer
   (`hostname` config). Easiest correct path if same-cluster: route in-cluster
   discovery through the **public issuer URL** too (requires items 2+3 below),
   rather than the raw service.
2. **Hostname resolution for pods.** If garrison pods use the public issuer URL,
   they must resolve `<armory-host>` to the nginx ingress. armory injects
   `hostAliases` for exactly this. Garrison pods need an equivalent path
   (hostAliases → ingress IP, in-cluster service DNS if same cluster, or real DNS).
3. **TLS trust.** armory's Keycloak ingress uses `armory-tls` (OpenBao-PKI CA).
   Agent Stack pods doing OIDC discovery/validation over `https://<armory-host>`
   must trust that CA. armory mounts the CA and sets `NODE_EXTRA_CA_CERTS`
   ([`main.yml:780`](../ansible/roles/beeai_agentstack_tofu/tasks/main.yml)).
   Garrison must obtain armory's CA (the `ca.crt` in the `armory-tls` secret, or
   the OpenBao PKI CA PEM) and do the same. This is **mandatory** if validation
   goes through the public HTTPS issuer.
4. **Proxy/trust flags.** `AUTH_TRUST_HOST`, `TRUST_PROXY_HEADERS`,
   `AUTH__OIDC__INSECURE_TRANSPORT` are set today to work behind the nginx
   ingress; reproduce as appropriate. (armory's Keycloak now expects
   `X-Forwarded-*` via `proxy.headers: xforwarded`, so nginx must set them — it
   does for the armory ingress; garrison's UI/API ingress should match.)

## 5. Network / topology questions to resolve

- **Same cluster or separate?** If garrison runs in the same k3s cluster as
  armory, pods can reach Keycloak via cross-namespace service DNS
  (`<cr-name>-service.keycloak.svc:8080`, plain HTTP) — but see §4.1: the issuer
  string must still match what browsers use, so same-cluster does **not** remove
  the issuer-consistency/CA-trust work, it only removes the DNS hop. If separate
  clusters, all Keycloak access is via armory's ingress + real DNS + CA trust.
  This decision drives §4 heavily.
- **Realm ownership.** Garrison owns the `agentstack` realm and its clients
  end-to-end; armory must not depend on it. (armory's own consumers — Headlamp,
  k3s — use armory's separate realm; see companion doc.)
- **Theme.** The bundled Keycloak used `keycloak-themed:26.5.4` (Agent Stack
  login theme). armory's stock Keycloak will not have it. If the themed login is
  desired, garrison/armory must decide whether to import the theme into armory's
  Keycloak or accept the default. Cosmetic, but a known delta.

## 6. Carried-over assets garrison should reuse

- Agent Stack realm/client provisioning can follow the REST pattern already
  proven in armory:
  [`keycloak_oidc_fix.yml`](../ansible/roles/beeai_agentstack_tofu/tasks/keycloak_oidc_fix.yml)
  and [`headlamp/tasks/oidc_client.yml`](../ansible/roles/headlamp/tasks/oidc_client.yml)
  show idempotent GET-then-PUT/POST against the Keycloak admin API.
- The two-pass Helm apply, credential generation, and VSO wiring in
  [`beeai_agentstack_tofu/tasks/main.yml`](../ansible/roles/beeai_agentstack_tofu/tasks/main.yml)
  migrate with the role; the Keycloak StatefulSet patch and the bundled-Keycloak
  bits drop (now armory's).

## 7. Open items checklist

- [ ] Confirm `externalOidcProvider.issuerUrl` single-issuer handling vs the
      internal/external split (§4.1) — the make-or-break detail for garrison.
- [ ] Decide same-cluster vs separate-cluster topology (§5).
- [ ] Define the `agentstack` realm: clients, secrets, audience scope+mapper,
      roles, seed admin (§3).
- [ ] Establish CA-trust delivery from armory to garrison pods (§4.3).
- [ ] Confirm `existingSecret` shape: keys `uiClientSecret` / `serverClientSecret`.
- [ ] Validate `rolesPath: realm_access.roles` against the roles garrison defines.
