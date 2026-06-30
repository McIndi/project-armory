# delve

Deploys the [Delve](https://github.com/McIndi/delve) audit-search platform
(Django 5 + DRF) into the armory cluster, per the
[Delve audit-search integration plan](../../../doc/handoffs/delve-audit-integration-plan.md).
**Phase 1** stood Delve up on Postgres at `https://delve.armory.local` with
local Django auth; **Phase 3** (this role's `pki.yml` + `oidc_client.yml`) adds
Keycloak human SSO and internal-TLS ingress re-encrypt. Machine ingestion lands
in Phase 2.

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
4. `deploy.yml` — provisions the external ingress TLS certificate, maps the
   ingress host locally, resolves the issuer host to the ingress IP (pod
   `hostAlias`), renders the chart values (flipping `oidc.enabled`/`tls.enabled`
   and the `backend-protocol: HTTPS` annotation when SSO is on), and releases the
   vendored `charts/delve` Helm chart (`delve-web`, `delve-worker`, and a
   pre-install `migrate` hook).

## Cross-role wiring (not in this role)

These live elsewhere because role defaults are invisible across roles
(see AGENTS.md):

- **`inventories/development/group_vars/all.yml`** — `delve_namespace`,
  `delve_vso_sa_name`, `delve_openbao_policy_name`, `delve_openbao_k8s_role`,
  `delve_openbao_db_path`, `delve_openbao_oidc_path`, `delve_enabled`, and
  `delve` in `trust_manager_internal_ca_target_namespaces`.
- **`roles/openbao`** — `delve` is in `openbao_provisioner_kv_prefixes`
  (defaults), and `consumer_wiring.yml` writes the `delve-vso` ACL policy and
  Kubernetes auth role that let VSO in the `delve` namespace read
  `secret/delve/db` and `secret/delve/oidc`.

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
