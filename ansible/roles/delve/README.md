# delve

Deploys the [Delve](https://github.com/McIndi/delve) audit-search platform
(Django 5 + DRF) into the armory cluster, per the
[Delve audit-search integration plan](../../../doc/handoffs/delve-audit-integration-plan.md).
**Phase 1** stood Delve up on Postgres at `https://delve.armory.local` with
local Django auth; **Phase 3** (this role's `pki.yml` + `oidc_client.yml`) adds
Keycloak human SSO and internal-TLS ingress re-encrypt. **Phase 2** (this role's
`ingestion_auth.yml` + `shippers.yml`) adds machine ingestion — a `delve-ingest`
client-credentials client, bearer-JWT-authenticated feeds, and the audit feed
shippers. Machine ingestion is independent of Phase 3's human SSO.

## What it does

1. `db.yml` — reads-or-generates the Postgres password and Django `SECRET_KEY`,
   persists them to OpenBao at `secret/delve/db`, VSO-syncs them into the
   `delve` namespace as `delve-db-secret`, then provisions a single-replica
   Postgres StatefulSet (role-owned, **not** in the chart) and waits for it to
   be Ready.
2. `pki.yml` *(Phase 3, gated on `delve_oidc_enabled`)* — issues the internal
   TLS cert (`delve-internal-tls`, from `openbao-pki-internal`) the web pod
   serves HTTPS from for ingress re-encrypt.
3. `oidc_client.yml` *(Phase 3, gated on `delve_oidc_enabled`)* — creates/updates
   the confidential `delve` Keycloak client (redirect URI
   `https://delve.armory.local/oidc/callback/`), ensures a `groups`
   group-membership mapper, persists the credentials to `secret/delve/oidc`, and
   VSO-syncs them into the `delve` namespace as `delve-oidc` **before** the Helm
   release. Logins are the shared `armory` realm users; the Delve-side
   `DelveOIDCBackend` maps `armory-admins`→superuser, `armory-operators`→staff,
   `armory-viewers`→read.
4. `ingestion_auth.yml` *(Phase 2, gated on `delve_ingest_enabled`)* — creates/
   updates the `delve-ingest` Keycloak client (service accounts / client-
   credentials only: `standardFlowEnabled: false`, `directAccessGrantsEnabled:
   false`), ensures an audience mapper so the access token's `aud` carries
   `delve-ingest`, persists the credentials to `secret/delve/ingest`, and
   VSO-syncs them into ns `delve` as `delve-ingest`. The web pod reads these for
   bearer-JWT validation; the shippers read them to fetch tokens.
5. `deploy.yml` — provisions the external ingress TLS certificate, maps the
   ingress host locally, resolves the issuer host to the ingress IP (pod
   `hostAlias`), renders the chart values (flipping `oidc.enabled`/`tls.enabled`/
   `ingest.enabled` and the `backend-protocol: HTTPS` annotation when SSO is on),
   and releases the vendored `charts/delve` Helm chart (`delve-web`,
   `delve-worker`, and a pre-install `migrate` hook).
6. `shippers.yml` *(Phase 2, gated on `delve_ingest_enabled`)* — provisions a
   read-only Keycloak DB role (`delve_keycloak_reader`, SELECT on the two Tier-1
   event tables) with creds in `secret/delve/keycloak-reader`, then deploys three
   audit feed shippers in ns `delve`, all running the **Delve image** (which
   bundles `utilities/cli/tail-files.py` + `keycloak-events.py`) and
   authenticating to `api/events/` with a `delve-ingest` bearer token:
   - **openbao_audit** (Deployment) — tails the OpenBao audit log via the
     local-path host dir of its PVC (resolved at deploy time), read-only.
   - **k8s_audit** (DaemonSet) — tails the host kube-apiserver audit log
     (hostPath, read-only); requires `k3s_audit_enabled`.
   - **keycloak_event** (Deployment + cursor PVC) — scheduled query of the
     Keycloak Tier-1 tables with a persisted high-water-mark cursor.

### Bearer-JWT vs. ingress/ (Phase 2 decision)

The plan named both "reuse `tail-files.py`" and "POST to `ingress/`", which
conflict (`tail-files.py` batch-POSTs to `api/events/`). We reuse `tail-files.py`
and ship to `api/events/`; the bearer-JWT guarantee is enforced there by the
Delve-side `events.authentication.IngestJWTAuthentication`
(`DEFAULT_AUTHENTICATION_CLASSES`). The `ingress/` view was also converted to a
DRF view so the same auth/permission pipeline (and the same rejection of forged/
expired/wrong-aud/`alg=none` tokens) applies there too.

## Cross-role wiring (not in this role)

These live elsewhere because role defaults are invisible across roles
(see AGENTS.md):

- **`inventories/development/group_vars/all.yml`** — `delve_namespace`,
  `delve_vso_sa_name`, `delve_openbao_policy_name`, `delve_openbao_k8s_role`,
  `delve_openbao_db_path`, `delve_openbao_oidc_path`, `delve_openbao_ingest_path`,
  `delve_openbao_keycloak_reader_path`, `delve_enabled`, and `delve` in
  `trust_manager_internal_ca_target_namespaces`.
- **`roles/openbao`** — `delve` is in `openbao_provisioner_kv_prefixes`
  (defaults), and `consumer_wiring.yml` writes the `delve-vso` ACL policy and
  Kubernetes auth role that let VSO in the `delve` namespace read
  `secret/delve/db`, `secret/delve/oidc`, `secret/delve/ingest`, and
  `secret/delve/keycloak-reader`.
- **`roles/k3s`** — the k8s_audit feed needs `k3s_audit_enabled` (group_vars,
  on in dev), which drops the API-server audit policy and points the apiserver at
  it; the shipper tails the resulting host audit log.

## Deviation from the plan

The Phase 1 plan (§1.3) sketched the VSO custom resources as chart templates.
They live **role-side** (`db.yml`) instead, because `delve-db-secret` must be
synced *before* the Helm release: the Postgres StatefulSet reads the DB
password from it and the chart's pre-install `migrate` hook connects to the DB.
A chart-side VaultStaticSecret would not exist until after the pre-install hook
had already run.

## Phase 1 image policy

Tracks `ghcr.io/mcindi/delve:latest` (public package, no pull secret) per
[decisions/0005](../../../doc/decisions/0005-track-latest-upstream.md). Pinned
to a digest at the end-of-project pinning step. `delve_image_pull_secrets` is a
values-driven hook should the package become private.
