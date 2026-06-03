# Keycloak Operator + Postgres StatefulSet — Implementation Plan

Status: proposed (evaluation stage — no changes applied)
Scope: rebuild the work-in-progress `keycloak` role to deploy Keycloak via the
**official Keycloak Operator** backed by a **plain PostgreSQL StatefulSet**, and
fix the blockers found in the first (Bitnami-Helm) pass. project-armory side only.
Supersedes: the Bitnami-chart approach currently in
[`ansible/roles/keycloak`](../ansible/roles/keycloak).
Companions: [`keycloak-extraction-plan.md`](keycloak-extraction-plan.md) (why/architecture),
[`agentstack-keycloak-reqs-for-garrison.md`](agentstack-keycloak-reqs-for-garrison.md) (garrison side).

## 1. Decisions locked

| # | Decision | Rationale |
|---|---|---|
| 1 | **Keycloak Operator** (official, Red Hat / keycloak.org) | Upstream, 1:1 with Keycloak releases, no vendor-catalog risk (Bitnami's 2025 catalog change makes its chart unviable). Declarative CRDs are agent-legible. |
| 2 | **PostgreSQL via plain StatefulSet** (official `postgres` image) | Single DB on one node; no second operator. Maximally legible, reuses existing VSO secret pattern. |
| 3 | **VSO is the single credential path** (resolves first-pass blocker #4) | OpenBao → VSO → one k8s secret, consumed by *both* the PG StatefulSet and the Keycloak CR. Removes the dead/duplicate-secret smell from the Bitnami pass. |
| 4 | **Realm `armory`**, armory-owned; agentstack realm is garrison's | armory stays Agent-Stack-ignorant. |

## 2. What changes vs the current WIP role

The first pass deployed Bitnami via `helm upgrade` with `keycloakConfigCli`. The
operator path replaces the deployment mechanism wholesale.

| Current WIP (`keycloak` role) | Action | Replacement |
|---|---|---|
| `helm upgrade --install` Bitnami chart | **remove** | Operator install + `Keycloak` CR |
| `_keycloak_chart_values` (Bitnami values) | **remove** | `Keycloak` CR spec |
| `keycloakConfigCli.configuration` realm import | **replace** | `KeycloakRealmImport` CR |
| Bitnami ingress block (empty cert/key — blocker #2) | **replace** | own `Ingress` (existing template idiom) or CR `ingress` w/ `armory-tls` |
| manual `keycloak-secret` (kubectl) + unused VSO secret (blocker #4) | **consolidate** | one VSO-synced secret, consumed everywhere |
| OpenBao cred-gen, policy, k8s auth role, CA secret, VaultConnection/Auth | **keep** | unchanged — these are correct |
| `keycloak_*_tofu_*` var names | **rename** | drop "tofu" (repo already de-OpenTofu'd) |

The OpenBao/VSO plumbing in [`tasks/main.yml:33-201`](../ansible/roles/keycloak/tasks/main.yml) is sound and stays. Everything from the realm-import payload and Helm apply onward gets rebuilt.

## 3. Target component layout

```
namespace: keycloak
├─ Keycloak Operator (CRDs + operator Deployment)         [cluster-scoped CRDs]
├─ Secret keycloak-credentials        ← VSO ← OpenBao secret/keycloak/credentials
│     keys: admin_username, admin_password, pg_user, pg_password, pg_admin_password
├─ PostgreSQL StatefulSet  (postgres:<pinned>, 1 replica, local-path PVC)
│     env from keycloak-credentials
├─ Service postgres  (ClusterIP :5432)
├─ Keycloak CR  (instances: 1)
│     spec.db        → host postgres:5432, db keycloak, user/pass from secret
│     spec.bootstrapAdmin → admin user/pass from secret
│     spec.hostname  → public host, strict tuning
│     spec.http / spec.proxy → behind nginx TLS-terminating ingress
├─ KeycloakRealmImport CR  → realm armory (roles, groups mapper, seed admin)
└─ Ingress  (nginx, armory-tls)  → /realms, /resources, admin as scoped
```

## 4. Credential flow (fix blocker #4)

Single source of truth, single synced secret:

VSO manages **only the Postgres credentials**. The Keycloak admin is bootstrapped
by the operator (verified — see §13), so no admin password belongs in OpenBao.

1. Role generates/persists PG creds in OpenBao `secret/keycloak/credentials`
   (cred-gen plumbing already implemented — keep). Required keys:
   `pg_user`, `pg_password`. (Drop `admin_password` / `pg_admin_password`;
   single PG role is sufficient for one DB.)
2. VSO `VaultStaticSecret` syncs → k8s Secret `keycloak-db-secret` in ns `keycloak`
   with keys `username` / `password`.
3. **Both DB consumers read that one secret:**
   - PG StatefulSet: `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` via `secretKeyRef`.
   - Keycloak CR `spec.db.usernameSecret`/`passwordSecret` → `keycloak-db-secret` keys.
4. **Admin:** consumed from the operator-generated `<cr-name>-initial-admin`
   secret (keys `username`/`password`). Headlamp's admin lookup repoints there
   (see §8). No manually-applied `keycloak-secret` — **delete it**.

No two-secret overlap, no unconsumed VSO output, no admin secret to hand-manage.

## 5. Realm definition (fix blocker #3)

`KeycloakRealmImport` CR for realm `armory` must include what the bundled chart
used to seed. Minimum viable:

- **Realm** `armory`, `enabled: true`, `sslRequired: external`.
- **Realm roles** the consumers need (e.g. an admin/cluster-admin role for k3s RBAC).
- **Groups protocol mapper** — k3s expects `oidc-groups-claim: groups`
  ([k3s/defaults](../ansible/roles/k3s/defaults/main.yml)); Keycloak emits no
  `groups` claim without a `group-membership` mapper. Add one + the group(s) that
  map to the k3s admin role.
- **Seed admin user** + role/group assignment — otherwise nobody can log into
  Headlamp.
- **Do NOT** put the `headlamp` client here. The Headlamp role already creates and
  reconciles its own client via REST
  ([headlamp/tasks/oidc_client.yml](../ansible/roles/headlamp/tasks/oidc_client.yml)),
  and that code works. Duplicating it in realm-import causes drift. Realm-import
  owns realm + roles + groups + users; Headlamp owns its client.

> **Realm-import semantics caveat:** `KeycloakRealmImport` is import-oriented;
> behavior on *re-import of an existing realm* varies by operator version (may not
> reconcile every field). Treat the realm JSON as create-time bootstrap; ongoing
> per-client config stays REST-driven (as Headlamp already does). Verify the
> chosen operator version's update behavior during the test gate.

## 6. Ingress / TLS (fix blocker #2)

Never pass empty `certificate`/`key` (the Bitnami pass would have clobbered
`armory-tls`). Decision: **own Ingress + edge TLS termination at nginx.**

- CR: `spec.http.httpEnabled: true`, `spec.ingress.enabled: false`,
  `spec.proxy.headers: xforwarded`, `spec.hostname.hostname: <public URL>`.
  Keycloak speaks plain HTTP in-cluster; nginx terminates TLS.
- Own `Ingress` resource (matches repo idiom): nginx class,
  `tls.secretName: armory-tls` (existing secret, **referenced not created**),
  backend → `<cr-name>-service:8080`.
- `spec.proxy.headers: xforwarded` is required so Keycloak honors nginx's
  `X-Forwarded-*` (correct issuer/redirects behind the proxy). Ensure the nginx
  Ingress sets/overwrites those headers.

## 7. Port — drop the 8336 assumption (fix blocker #1)

`8336` was the Agent Stack themed-chart port and is now irrelevant. The operator's
Keycloak Service exposes **8080 (http)** / **8443 (https)** with name
`<keycloak-cr-name>-service`. Therefore:

- Set `keycloak_service_name` = `<cr-name>-service`, `keycloak_service_port` = `8080`.
- In-cluster consumers (Headlamp REST/admin calls) hit
  `http://<cr-name>-service.keycloak.svc:8080`.
- Public/browser + k3s issuer use the nginx ingress over HTTPS.
- Remove the `beeai_keycloak_service_port|default(8336)` fallbacks once cutover lands.

## 8. Consumer repointing (verify Copilot's first-pass edits against new values)

Copilot already added keycloak-owned vars with `beeai_*` fallbacks. Re-point them
at the operator reality:

- **Headlamp** ([defaults](../ansible/roles/headlamp/defaults/main.yml),
  [oidc_client.yml](../ansible/roles/headlamp/tasks/oidc_client.yml)):
  - `headlamp_keycloak_service_name` → `<cr-name>-service`, port `8080`.
  - `headlamp_keycloak_namespace` → `keycloak`.
  - admin lookup → operator secret `<cr-name>-initial-admin`, keys `username`/`password`
    (note: keys are `username`/`password`, **not** `admin-password` — update the jsonpath).
  - realm → `armory`.
- **k3s** ([defaults](../ansible/roles/k3s/defaults/main.yml)):
  - issuer → `…/realms/armory` (already parametrized on `keycloak_realm`). ✔
  - confirm `oidc-client-id: headlamp` still matches the REST-created client's audience.
- **Group/role claim**: confirm tokens carry `groups` (from §5 mapper) so k3s RBAC binds.

## 9. Readiness

[`check_keycloak.yml`](../ansible/roles/readiness_check/tasks/check_keycloak.yml)
is largely fine. Adjust:
- service name → `<cr-name>-service`; default namespace → `keycloak` (not `agentstack`).
- admin-secret check → `<cr-name>-initial-admin` (and `keycloak-db-secret` for DB).
- add a check on the `Keycloak` CR `status` condition `Ready=true` and the
  `KeycloakRealmImport` `Done=true` condition (operator gives real status — cheaper
  and more reliable than HTTP probing).

## 10. Staging + validation gates

Keep `keycloak_enabled: false` until green. Do **not** remove `beeai_agentstack_tofu`
or flip defaults before all gates pass.

1. Operator installs; CRDs present.
2. PG StatefulSet ready; `keycloak-credentials` synced by VSO; PG accepts creds.
3. `Keycloak` CR → `status.ready: true`.
4. `KeycloakRealmImport` → realm `armory` present with roles + groups mapper + seed admin.
5. Ingress serves `…/realms/armory/.well-known/openid-configuration` over `armory-tls`.
6. Headlamp role creates its client (REST) in realm `armory`; Headlamp login works end-to-end.
7. k3s issuer discovery + `groups` claim → RBAC binds; `kubectl` as seeded admin works.
8. **Only then:** remove `beeai_agentstack_tofu` from [site.yml](../ansible/playbooks/site.yml), flip `keycloak_enabled` default, prune `BEEAI_*` from `.env.example`/`README.md`, retire `check_beeai.yml`.

> Interim foot-gun: with `keycloak_enabled=true` while beeai is still on-path, two
> Keycloaks deploy (beeai bundles its own). Run validation with beeai tags skipped,
> or temporarily comment the beeai role, until step 8.

## 11. Open questions / risks

1. **~~Operator install method~~** — RESOLVED (§13): raw pinned manifests via
   `kubectl apply`, no OLM. Decide only vendored-copy vs fetch-by-URL (URL needs
   VM egress to `raw.githubusercontent.com`; vendoring is air-gap-safe).
2. **~~Keycloak 26 admin bootstrap~~** — RESOLVED (§13): operator generates
   `<cr-name>-initial-admin` (`username`/`password`). No OpenBao admin secret.
3. **Hostname / dual-issuer** — single public issuer for browser + k3s; in-cluster
   Headlamp uses the http service. `spec.proxy.headers: xforwarded` +
   `spec.hostname.hostname` is the verified setting; `spec.hostname.strict` may
   need `false` if in-cluster callers use a non-public host. Confirm at the test
   gate that Headlamp (svc:8080) and k3s (public issuer) both resolve discovery.
4. **PG persistence** — local-path PVC on the single node; no backups by default.
   Acceptable for dev/demo; document it.
5. **Realm-import update semantics** (see §5 caveat) — verify on the pinned version.
6. **Version pin** — pin `keycloak-k8s-resources` tag to the Keycloak image tag
   (e.g. `26.5.x`); operator + CRDs + server image must align.

## 13. Verified operator contracts (Keycloak 26.5.x)

Confirmed against keycloak.org operator docs (`keycloak-k8s-resources`):

- **Install (raw manifests, namespace `keycloak`):**
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/<ver>/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
  kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/<ver>/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
  kubectl -n keycloak apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/<ver>/kubernetes/kubernetes.yml
  ```
- **API group/version:** `k8s.keycloak.org/v2alpha1`.
- **`Keycloak` CR (edge TLS at nginx):**
  ```yaml
  apiVersion: k8s.keycloak.org/v2alpha1
  kind: Keycloak
  metadata: { name: <cr-name>, namespace: keycloak }
  spec:
    instances: 1
    db:
      vendor: postgres
      host: postgres            # PG StatefulSet service
      database: keycloak
      usernameSecret: { name: keycloak-db-secret, key: username }
      passwordSecret: { name: keycloak-db-secret, key: password }
    http: { httpEnabled: true }
    ingress: { enabled: false }  # own Ingress instead
    hostname: { hostname: https://<public-host> }
    proxy: { headers: xforwarded }
  ```
- **Admin:** operator auto-creates secret `<cr-name>-initial-admin` with keys
  `username` / `password`.
- **Service:** `<cr-name>-service`, ports `8080` (http) / `8443` (https).
- **`KeycloakRealmImport` CR:** `spec.keycloakCRName: <cr-name>` + `spec.realm: {…}`
  (full realm representation: roles, groups, group-membership mapper, seed users).

## 12. Out of scope

Garrison (Agent Stack against external OIDC) and the final beeai removal/cutover
(gated on §10). See companion docs.
