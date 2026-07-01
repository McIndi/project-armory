# Implementation Plan — Delve Audit-Search Integration (Plan A: in-cluster role)

Status: Phase 1 implemented & deployed (2026-06-30). Phase 3 (human SSO)
implemented (2026-06-30), pending a fresh-rebuild deploy verification. Remaining
work runs in the order **Phase 2 → Phase 4** (see "Execution order & decisions"
below).
Scope: Deploy [Delve](https://github.com/McIndi/delve) (Django 5 + DRF log
platform) into the armory cluster as a first-class component that ingests,
correlates, and dashboards the audit logs from OpenBao, Keycloak, and a new
k8s API-server secret-access audit feed. Two independent auth surfaces:
(1) human SSO via Keycloak OIDC, (2) machine ingestion via a separate
client-credentials client + bearer-JWT.
Preconditions: `keycloak`, `openbao`, `vso`, `cert_manager`, `trust_manager`,
`nginx_ingress`, `headlamp` roles exist and are wired into `site.yml`; the k3s
node can pull from `ghcr.io` during deploy (same as the existing upstream
image/chart pulls). No in-cluster build is needed — Delve images are published
to GHCR on every push to `main`.
Companions: [`openbao-audit-device-handoff.md`](openbao-audit-device-handoff.md),
[`keycloak-event-auditing-tier1-2-plan.md`](keycloak-event-auditing-tier1-2-plan.md),
[`openbao-ui-keycloak-oidc-plan.md`](openbao-ui-keycloak-oidc-plan.md).

## How to use this doc
Each task names exact files and the change. Run the §6 validation after each
phase. Match existing role conventions
([../../AGENTS.md](../../AGENTS.md)) — no new abstractions. The `delve` role
clones the `headlamp` role almost verbatim; read
[`ansible/roles/headlamp/`](../../ansible/roles/headlamp) before starting.
Delve-side code changes happen in the separate `delve` repo and are gated by
feature flags (off by default, preserving Delve's air-gapped default).
The phase **numbers below are stable identifiers, not the run order** — see
the execution order immediately below.

## Execution order & decisions

**Run order: Phase 1 (done) → Phase 3 → Phase 2 → Phase 4.** Phase 3 (human
SSO) is pulled ahead of Phase 2 (audit feeds + machine ingestion) because every
Phase 2 feed is only *verifiable through a browser login*, and SSO is that
login. The two are independent — Phase 2's machine ingestion authenticates with
the `delve-ingest` client-credentials token, never the human OIDC path — so
nothing in Phase 2 blocks on Phase 3 or vice-versa. Phase 4 needs both.

**Credential / login convention (decided 2026-06-30).** Delve follows the
**armory shared-realm** convention, *not* garrison's per-app pattern:
- Delve logins are the shared `armory` realm users (`admin`→superuser,
  `operator`→staff, `viewer`→read), group-mapped. No dedicated Delve realm, no
  Delve admin user, no `delve-admin-credentials` secret in ns `delve`.
- Retrieval is the standard armory way (OpenBao = source of truth, VSO mirrors
  to a k8s secret). The Delve **superuser** login is already retrievable via the
  existing `keycloak-realm-admin` secret (ns `keycloak`). `operator`/`viewer`
  remain **OpenBao-only** (not mirrored) — the accepted exception.
- **No local Django superuser is provisioned.** Interactive browser login to
  Delve therefore arrives with Phase 3; this is intended (nothing to view until
  Phase 2 ingestion, and Phase 2's auth is independent of human SSO).

**Phase 1 deltas vs. the as-written §1 (already implemented).** Three required
changes the original draft omitted, plus two deliberate deviations:
- *Gap fixes (would otherwise break the deploy):* added `delve` to
  `openbao_provisioner_kv_prefixes`; added a `delve-vso` ACL policy + k8s auth
  role in `openbao/tasks/consumer_wiring.yml`; added `delve` to
  `trust_manager_internal_ca_target_namespaces`.
- *Deviation:* the VSO custom resources (VaultConnection/Auth/StaticSecret) and
  the pod ServiceAccount live **role-side in `db.yml`**, not in the chart as §1.3
  first sketched — `delve-db-secret` must be VSO-synced *before* the Helm release
  (the role-owned Postgres reads the DB password from it and the chart's
  pre-install migrate hook connects to the DB). See the `delve` role README.

---

## 0. Design summary

| Item | Value |
|---|---|
| Namespace | `delve` |
| Ingress host | `delve.armory.local` |
| OIDC client (human) | `delve` (standard flow, confidential) |
| OIDC client (machine) | `delve-ingest` (service accounts / client-credentials) |
| OpenBao KV paths | `secret/delve/db`, `secret/delve/oidc`, `secret/delve/ingest` |
| Event store | PostgreSQL (StatefulSet) — **not** sqlite |
| Workloads | `delve-web`, `delve-worker` (django-q), `delve-db` |
| Image | `ghcr.io/mcindi/delve:<tag>` — published on push to `main` (tag = `package.json` version, plus `:latest`). Pulled, not built. |
| Deploy unit | Vendored Helm chart `charts/delve/`, released via `kubernetes.core.helm` (the `charts/vso-hardened/` model) |
| Group → role mapping | `armory-admins`→superuser, `armory-operators`→staff, `armory-viewers`→read (same groups Headlamp/OpenBao use) |

Auth split rationale: human SSO (`mozilla-django-oidc`, session/browser) and
machine ingestion (bearer-JWT on `ingress/`) share an issuer but never a code
path, so the OIDC-SSO work cannot block log ingestion.

---

## 1. Phase 1 — `delve` role skeleton, DB, deploy (local auth only) — ✅ DONE (2026-06-30)

> Implemented and deployed. See "Execution order & decisions" above for the
> gap fixes and the role-side VSO/ServiceAccount deviation from §1.3.

Goal: Delve running in-cluster on Postgres, reachable at
`https://delve.armory.local`, authenticating with a local Django superuser.
No Keycloak coupling yet.

### 1.1 `ansible/roles/delve/` scaffold
Clone the directory shape of `headlamp`: `defaults/main.yml`, `meta/main.yml`,
`README.md`, `tasks/main.yml`, plus the task files below. `tasks/main.yml`
mirrors [`headlamp/tasks/main.yml`](../../ansible/roles/headlamp/tasks/main.yml):
resolve `armory_log_nolog`, then a tagged `block` importing each task file.
Initial `main.yml` imports only `db.yml` and `deploy.yml`.

The deploy unit is a **Helm chart**, not raw manifests, matching armory's
`kubernetes.core.helm` convention.

### 1.2 `tasks/db.yml` — PostgreSQL (provision **and wait**, role-side)
Model on the Keycloak Postgres provisioning. Read-before-generate the DB
password into `secret/delve/db` (never regenerate on re-run, per AGENTS.md),
VSO-sync it to a `delve-db-secret`. Deploy a single-replica Postgres
StatefulSet + headless Service + PVC in ns `delve`. Internal TLS optional for
phase 1.

**The DB lives role-side in `db.yml`, not in the Helm chart — decided.** This
task must **provision and then `wait` for the StatefulSet to be Ready** (poll
the pod / a `pg_isready` probe) **before** §1.4 runs the Helm release. Reason:
the chart's `pre-install` migrate hook (§1.3) connects to Postgres on install;
Helm hook weights do **not** wait for a separately-managed StatefulSet to be
Ready, so provisioning + waiting here is what makes the first `vagrant up`
deterministic. The chart therefore contains no DB resources.

**Event persistence — decided:** Delve events are **not** to persist across
rebuilds. A standard local-path PVC is correct (it survives pod restarts/
reschedules during a VM's life, which is good demo UX) and is destroyed with
the VM on `vagrant destroy` like everything else. No backup/snapshot story, no
auto-unseal-style durability, and no decision record are needed — losing events
on rebuild is the intended behavior.

### 1.3 Helm chart `charts/delve/`
Vendor a chart under `charts/delve/`, mirroring
[`charts/vso-hardened/`](../../charts/vso-hardened) (`Chart.yaml`, `values.yaml`,
`templates/`, `.helmignore`). Templates:

- `deployment-web.yaml` — `python manage.py serve`; env from the VSO-synced
  secrets; `DELVE_DATABASE_ENGINE=postgresql`,
  `DELVE_ALLOWED_HOSTS=delve.armory.local`, `DELVE_SECRET_KEY` from OpenBao.
- `deployment-worker.yaml` — same image, `python manage.py qcluster`.
- `job-migrate.yaml` — Helm `pre-install`/`pre-upgrade` hook running
  `manage.py migrate` + `collectstatic` (Delve's `Dockerfile` already runs
  collectstatic at build, so this is migrate-focused). Safe because §1.2 has
  already provisioned and waited on the DB before the release runs.
- `service.yaml`, `ingress.yaml` (annotations matching Headlamp's; backend HTTP
  for phase 1, re-encrypt added in Phase 3 with the cert).
- VSO custom resources as templates: `vaultconnection.yaml`, `vaultauth.yaml`,
  `vaultstaticsecret.yaml` — port the three
  `ansible/roles/headlamp/templates/headlamp_*.j2` into the chart (values-driven
  ServiceAccount + OpenBao k8s-auth role per
  [security.md](../security.md) credential model).
- `serviceaccount.yaml` for the web/worker pods.

The chart does **not** template the Postgres StatefulSet/PVC — that is owned by
the role's `db.yml` (§1.2).

`values.yaml` exposes: `image.repository`, `image.tag`, `image.pullPolicy`,
`imagePullSecrets`, `ingress.host`, `oidc.enabled` (default false — Phase 3
flips it), `database.*` (connection coordinates pointing at the role-provisioned
DB), and the VSO mount/role names. Keep it a generic, upstreamable chart (no
armory-only literals); armory passes specifics via the role's values file. This
chart is a candidate to live in the **delve repo** long-term and be vendored
here, exactly as `vso-hardened` is vendored.

### 1.4 `tasks/deploy.yml` — Helm release + image source
- Render a `values.yaml` to the role work dir, then `kubernetes.core.helm`
  with `chart_ref` = the local `charts/delve` path, `release_namespace: delve`,
  `create_namespace: true`, `wait: true`, explicit `kubeconfig` — copy the
  shape of [`vso/tasks/main.yml`](../../ansible/roles/vso/tasks/main.yml) lines
  ~126–138. Runs only after §1.2's DB is Ready.
- **Image source:** pull `ghcr.io/mcindi/delve`. Add `delve_image_tag` default
  `latest` (consistent with armory's track-latest policy,
  [decisions/0005](../decisions/0005-track-latest-upstream.md)). Set via the
  chart's `image.tag`. **Pinning is deferred to the end-of-project pinning
  step — decided.** Note the tension: because Delve *holds the audit trail*,
  it is the component most worth pinning to a digest and the earliest; we
  accept tracking `:latest` during development and pin (to the `package.json`
  version tag / digest) at project close.
- **If the GHCR package is private:** create an `imagePullSecret` in ns `delve`
  (PAT with `read:packages`) and reference it via `imagePullSecrets` in values.
  Confirm package visibility first; public needs no secret.
- **Air-gap note:** pulling from `ghcr.io` needs egress at deploy time, same as
  the existing upstream chart/image pulls. A fully air-gapped run would mirror
  the image into a local registry and override `image.repository` — out of
  scope for phase 1.

### 1.5 Wire into `site.yml`
Add the `delve` role after `headlamp`. Add a `delve_enabled` toggle in
`inventories/development/group_vars/all.yml` (default `true`). Shared values
(keycloak internal FQDN, openbao addrs, CA secret names) already live in
`group_vars/all.yml` — reuse, do not redefine in role defaults.

---

## 2. Phase 2 — k8s secret-access audit, machine ingestion auth, feed shippers

> **Run order: this phase runs AFTER Phase 3.** Machine ingestion here is
> independent of Phase 3's human SSO, but the feeds are only verifiable through
> a browser login, which Phase 3 provides.

> **Status: implemented (pending a fresh-rebuild deploy verification).**
> **Phase 2 deltas vs. the as-written §2 (decisions made during implementation):**
> - *Shipper endpoint (resolved a plan contradiction):* §2.4 named both "reuse
>   `tail-files.py`" and "POST to `ingress/`", but `tail-files.py` batch-POSTs to
>   `api/events/` with Basic auth. Decision: reuse `tail-files.py` and ship to
>   `api/events/` with the `delve-ingest` bearer token. The bearer-JWT guarantee
>   is enforced there via `DEFAULT_AUTHENTICATION_CLASSES`. The `ingress/` view
>   was *also* converted to a DRF view so the same auth/permission pipeline and
>   token rejection apply there too (so §6's "rejected by `ingress/`" still holds).
> - *No separate shipper image:* the shippers run the **Delve image** itself (it
>   already bundles `utilities/cli/tail-files.py` + the new `keycloak-events.py`,
>   `requests`, and `psycopg2`), avoiding a net-new build pipeline (AGENTS.md "no
>   new abstractions"). `tail-files.py` gained a backward-compatible
>   `--auth bearer` client-credentials mode; `keycloak-events.py` is new.
> - *OpenBao audit access (cross-namespace PVC constraint):* the auditStorage PVC
>   is RWO and namespace-scoped to `openbao`, so a pod in `delve` cannot mount it.
>   Instead the shipper (in `delve`) hostPath-mounts the local-path-backed host
>   directory of that PVC read-only (resolved from the PV at deploy time) —
>   functionally identical on single-node k3s, and keeps all three shippers in
>   `delve` under the SA-drop rule. No openbao-role change.
> - *Ingest token `aud`:* added an `oidc-audience` mapper on the `delve-ingest`
>   client so the access token's `aud` carries `delve-ingest` (Delve validates
>   `azp`/`aud`); `exp` is enforced Delve-side regardless of library version.
> - *Keycloak reader creds:* `shippers.yml` provisions a dedicated read-only DB
>   role (`delve_keycloak_reader`, SELECT on the two Tier-1 tables only) by
>   exec'ing `psql` in the keycloak Postgres pod as the bootstrap superuser;
>   creds persist at `secret/delve/keycloak-reader`. Shipper→DB uses
>   `sslmode=require` (encrypt, no cert pin) for the in-cluster demo.
> - *File-tail cursor durability:* the file-tail shippers persist
>   `tail-files.py`'s position file on a host dir so a restart does not re-ingest
>   the current log; the keycloak feed persists its query cursor on a PVC.

Goal: OpenBao, Keycloak, and k8s secret-access audit events flowing into Delve
via the `ingress/` REST endpoint, **authenticated from the start** with the
`delve-ingest` client-credentials token. (Machine auth is folded into this
phase — there is no temporary/throwaway ingestion token.)

Of the three feeds, **Keycloak event auditing is already in place** — the
`armory` realm has `eventsListeners: ["jboss-logging"]` registered, Tier 1
(Postgres event store + retention) and Tier 2 (successful + failed events to
the pod's stdout at INFO via the `spi-events-listener-jboss-logging-*` settings
in [`keycloak.yaml.j2`](../../ansible/roles/keycloak/templates/keycloak.yaml.j2))
are configured by the `keycloak` role's `realm_events.yml`. Onboarding to Delve
is therefore **ship-only**: no listener enablement, no keycloak-role changes.
OpenBao audit is likewise already emitting. Net new config this phase is the
k8s audit policy (2.1), the machine ingestion auth (2.2 / 2.3), and the
shippers (2.4).

### 2.1 k3s API-server audit policy (`k3s` role)
- New `ansible/roles/k3s/templates/audit-policy.yaml.j2`. **Scope: audit
  `secrets` only; drop everything else — decided.** The demo goal (§4) is
  secret-access correlation, and a cluster-wide `Metadata` policy is a firehose
  that django-q + Postgres FTS won't keep up with. Policy shape:
  - **`Metadata` level for `secrets`** (verbs get/list/watch/create/update/
    delete). **Not `RequestResponse`** — a `RequestResponse` on a secret `get`/
    `list` captures the response body, which contains the secret `data` in
    cleartext (base64, not encrypted), and would ship plaintext secrets into
    Delve's Postgres. `Metadata` still records who/when/which-secret/verb, which
    is the entire point of the feed.
  - A trailing rule at `None` level for all other resources (default drop).
  - **Early drop rule** for the platform's own service accounts so the feed
    shows *consumer* secret access, not the platform's own machinery — drop
    `system:serviceaccount:vault-secrets-operator-system:*`,
    `system:serviceaccount:cert-manager:*`, **and the Delve shipper/ingest SA**
    (`system:serviceaccount:delve:*`) so Delve does not audit its own VSO secret
    reads. This SA list is the single most important tuning step.
- Extend [`k3s/templates/config.yaml.j2`](../../ansible/roles/k3s/templates/config.yaml.j2):
  the `kube-apiserver-arg` block already exists (line 12); append
  `audit-policy-file`, `audit-log-path`, `audit-log-maxage`,
  `audit-log-maxbackup`, `audit-log-maxsize`. Gate on a new
  `k3s_audit_enabled` default. Drop the policy file via a task in the k3s role
  before templating config. Triggers the existing k3s restart handler.

### 2.2 `tasks/ingestion_auth.yml` (delve role) — `delve-ingest` client
Clone the client-create flow from
[`headlamp/tasks/oidc_client.yml`](../../ansible/roles/headlamp/tasks/oidc_client.yml)
but create client `delve-ingest` with `serviceAccountsEnabled: true`,
`standardFlowEnabled: false`, `directAccessGrantsEnabled: false`. Store
`OIDC_CLIENT_ID`/`SECRET`/`ISSUER_URL`/`CA_PEM` in `secret/delve/ingest`;
VSO-sync into ns `delve`. Shipper pods read it and fetch a token via the
client-credentials grant.

### 2.3 Delve code — bearer-JWT DRF auth (delve repo)
- New `events/authentication.py`: a DRF `BaseAuthentication` that validates a
  Keycloak-issued bearer JWT. **Do not hand-roll JWT/JWKS verification** — use
  `mozilla-django-oidc`'s token-validation utilities (already added in Phase 3),
  which handle JWKS fetch/caching/rotation and reject
  `alg=none`. Verify signature against the realm JWKS and check
  `azp`/audience = `delve-ingest` and `exp`.
- `requirements.txt`: `mozilla-django-oidc` is already present (added in Phase 3
  for the browser-SSO backend; reused here for token validation).
- Add the auth class to `REST_FRAMEWORK['DEFAULT_AUTHENTICATION_CLASSES']` in
  [`delve/settings.py`](https://github.com/McIndi/delve) **alongside** the
  existing Basic + Session classes (interactive use unaffected).
- New `DELVE_INGEST_*` env (issuer, JWKS URL, audience, CA PEM) from the
  `delve-ingest` VSO secret.

### 2.4 Feed shippers (DaemonSet)
A small shipper image, one DS (or per-source sidecars), each fetching a
`delve-ingest` client-credentials token (§2.2) and POSTing to
`ingress/<index>/<source>/<sourcetype>/` with that bearer token:

| Source | Access | Target sourcetype |
|---|---|---|
| OpenBao audit | mount the audit PVC read-only; tail with Delve's `tail-files.py` | `openbao_audit` |
| Keycloak events | **scheduled DB query** of Tier 1 tables (see below) | `keycloak_event` |
| k8s audit | tail host `audit-log-path` (hostPath, read-only) with `tail-files.py` | `k8s_audit` |

**File-tail feeds (OpenBao, k8s):** use Delve's existing
[`utilities/cli/tail-files.py`](https://github.com/McIndi/delve), which
**closes and reopens on rotation** (follows by inode, not just path), so the
OpenBao rotation timer (`mv audit.log audit.log.<ts>; kill -HUP 1`, prune to
newest 7) and kubelet's audit-log rotation are handled without data loss.
OpenBao audit is already JSON with HMAC'd secrets/tokens — no parser needed
([security.md](../security.md) §Audit logging). Note the RWO `auditStorage` PVC
is mounted read-only into the shipper as well as OpenBao — fine on single-node
k3s; stated here as an explicit dependency.

**Keycloak feed — DB-table ingestion (decided):** instead of tailing
`jboss-logging` stdout (rotation/restart-path churn + `rex` text-parsing), read
the Tier 1 `event_entity` / `admin_event_entity` Postgres tables via Delve's
scheduled-query ingestion. This yields structured rows directly. Requirements:
- The query must select **only new rows** — filter on `event_time` (and tie-
  break on `id`) greater than the last ingested high-water mark.
- The shipper must **persist that cursor** (last-seen `event_time`/`id`) and
  advance it per run, so restarts and reschedules do not re-ingest or skip.
- Read-only DB credentials scoped to those two tables.

---

## 3. Phase 3 — human SSO (Keycloak OIDC) — ✅ IMPLEMENTED (2026-06-30)

> **Run order: ran before Phase 2.** It delivers the browser login used to
> verify every later feed. Logins are the shared `armory` realm users (no
> Delve-specific user); retrieve the superuser login from the existing
> `keycloak-realm-admin` secret (ns `keycloak`).
>
> **Implementation note:** because Phase 3 ran before Phase 2, the
> `mozilla-django-oidc` requirement and the `delve-oidc` OpenBao read on the
> `delve-vso` policy were added *here*, not in Phase 2. The Delve chart also
> gained the OIDC env + internal-TLS re-encrypt plumbing (`oidc.*` / `tls.*`
> values, web-pod CA + TLS mounts, issuer `hostAlias`, `backend-protocol: HTTPS`
> annotation), driven by the role's `delve_oidc_enabled` toggle (default on in
> dev). The web server already supported TLS via `DELVE_SSL_*`, so re-encrypt
> needed no Delve code change.

Goal: browser login to Delve via Keycloak, group-mapped, with local
`ModelBackend` retained as fallback.

### 3.1 `tasks/oidc_client.yml` (delve role)
Near-verbatim clone of
[`headlamp/tasks/oidc_client.yml`](../../ansible/roles/headlamp/tasks/oidc_client.yml):
create/update client `delve` (redirect URIs
`https://delve.armory.local/oidc/callback/`, web origin the ingress host),
ensure the `groups` group-membership protocol mapper, store
`OIDC_CLIENT_ID/SECRET/ISSUER_URL/SCOPES/CA_PEM` in `secret/delve/oidc`,
VSO-sync. Add `pki.yml` (clone headlamp `pki.yml`) so internal TLS uses
`openbao-pki-internal` and the ingress re-encrypts upstream.

### 3.2 Delve code — `mozilla-django-oidc` browser backend (delve repo)
- `requirements.txt`: `mozilla-django-oidc` is already present from Phase 2.
- `settings.py`: make `AUTHENTICATION_BACKENDS` env-toggled — OIDC backend
  first **only when** `DELVE_OIDC_ENABLED` is truthy, `ModelBackend` always
  retained as fallback (preserves break-glass + air-gapped default). **Normalize
  the env parse** (don't compare to the literal string `'True'`):
  ```python
  _oidc_on = os.getenv('DELVE_OIDC_ENABLED', '').strip().lower() in ('1', 'true', 'yes')
  AUTHENTICATION_BACKENDS = tuple(
      (['users.auth.DelveOIDCBackend'] if _oidc_on else [])
      + ['django.contrib.auth.backends.ModelBackend']
  )
  ```
- New `users/auth.py` (`DelveOIDCBackend(OIDCAuthenticationBackend)`): override
  `create_user`/`update_user`/`filter_users_by_claims` to map the `groups`
  claim → Django groups + `is_staff`/`is_superuser`.
- `delve/urls.py`: `path('oidc/', include('mozilla_django_oidc.urls'))`.
- New `DELVE_OIDC_*` env from the `delve-oidc` VSO secret (issuer, client
  id/secret, `OIDC_CA_PEM` for issuer verification — Headlamp already stores
  this key).
- Update `delve/tasks/main.yml` to import `oidc_client.yml` + `pki.yml`, and
  set `DELVE_OIDC_ENABLED=True` in the deploy env.

---

## 4. Phase 4 — correlation & dashboard content

Seed Delve (data migration or `loaddata` fixture) with saved `Query` pipelines
and dashboards correlating the three feeds — e.g. *OIDC login (keycloak_event)
→ token issuance (openbao_audit) → Secret read (k8s_audit)* joined on
user/time. Add django-q scheduled alert searches for anomalous secret access.
This phase is where the three feeds become correlated signal rather than three
log tails.

---

## 5. Risks / accepted gaps

| Risk | Mitigation / status |
|---|---|
| Audit volume vs. Postgres | Scoped to `secrets`-only (§2.1) + drop platform SAs; size PVC; set Delve retention/rotation from day one |
| Plaintext secrets in the audit store | **Resolved:** `secrets` audited at `Metadata`, never `RequestResponse` (§2.1) |
| Self-referential noise (Delve auditing its own VSO secret reads) | §2.1 SA drop rule includes Delve's `delve:*` SA |
| Keycloak DB ingestion drift | Watermark cursor (last `event_time`/`id`) persisted by the shipper; query selects only newer rows (§2.4) |
| Log rotation data loss | `tail-files.py` closes/reopens on inode change; handles OpenBao prune timer + kubelet rotation (§2.4) |
| k3s rebuild model (no upgrade path) | **Resolved:** Delve events intentionally do not persist across rebuilds; standard PVC wiped with the VM, no backup story, no decision record (§1.2) |
| Image holds the audit trail but tracks `:latest` | Accepted in dev per [decisions/0005](../decisions/0005-track-latest-upstream.md); pin to digest at end-of-project pinning step (§1.4) |
| OIDC requires Keycloak reachability | ModelBackend fallback retained; `DELVE_OIDC_ENABLED` toggle keeps air-gapped default working |
| Delve is AGPL, single-maintainer | Feature-flagged code changes are upstreamable; no fork divergence required |

---

## 6. Validation (run after each phase)

Repo conventions ([../operations.md](../operations.md), AGENTS.md):

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
yamllint -c .yamllint .
```

Behavior acceptance is a fresh rebuild: `vagrant destroy -f && vagrant up`,
full `site.yml`, a second run for idempotency, then `readiness_check.yml`.
Phase-specific checks:

- **P1**: `helm` release `delve` deployed (image pulled from GHCR, migrate hook
  succeeded after the role-provisioned DB was Ready); `https://delve.armory.local`
  loads; local superuser login works; events persist in Postgres across a pod
  restart.
- **P2**: `kubectl get secret` by a non-platform SA appears in Delve under
  `k8s_audit` (at `Metadata` — no secret `data` present in the event); OpenBao +
  Keycloak events visible in their indexes; shippers authenticate with the
  `delve-ingest` client-credentials token (no throwaway token exists); a forged,
  expired, **wrong-`aud`**, or **`alg=none`** JWT is rejected by `ingress/`; the
  Keycloak DB-query cursor advances and does not re-ingest on shipper restart.
- **P3**: Keycloak login redirects, group→role mapping correct, ModelBackend
  login still works with `DELVE_OIDC_ENABLED` unset; internal TLS re-encrypt at
  the ingress.
- **P4**: the cross-source correlation query returns linked events; a scheduled
  alert fires on a synthetic anomalous secret read.
