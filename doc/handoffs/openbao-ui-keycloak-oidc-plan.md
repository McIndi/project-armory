# Handoff: Expose OpenBao Web UI + Keycloak OIDC Login

> **ARCHIVED — executed. Kept for history; do not follow as current instructions.** Rationale and architectural notes live in this document; full implementation details in the role-based PRs/commits.

Status: complete · Created: 2026-06-15 · Executed: 2026-06-16

## Goal

Expose OpenBao's built-in web UI through nginx ingress at
`openbao.<ARMORY_PUBLIC_DOMAIN>` and let humans log in with their Keycloak
realm credentials (the `admin` / `operator` / `viewer` users created
2026-06-12), so the demo can show the full SSO stack end to end. Authorization
is group-driven via OpenBao identity groups mapped to ACL policies, mirroring
the three-tier Kubernetes RBAC model.

This is a **demo capability**. Read "Security considerations" before starting —
exposing the OpenBao UI widens the attack surface and the ACL tiers below are
deliberately coarse.

## What this builds on (2026-06-12 RBAC work — reuse, do not reinvent)

The per-role RBAC change established every pattern this item needs:

- **Keycloak OIDC client provisioning via admin REST** —
  `ansible/roles/headlamp/tasks/oidc_client.yml`. Full idempotent flow: get
  admin token → look up client → create-or-update (PUT with `combine`) →
  ensure `groups` protocol mapper → read effective client secret → persist to
  OpenBao KV with the provisioner token. **Copy this file** as the basis for
  the OpenBao client.
- **`groups` claim end to end** — the realm users belong to `armory-admins` /
  `armory-operators` / `armory-viewers` (`keycloak_realm_groups`,
  `keycloak_realm_users` in `ansible/roles/keycloak/defaults/main.yml`); the
  group-membership mapper emits a `groups` claim
  (`oidc_client.yml:252-277`). OpenBao consumes the same claim.
- **Public-issuer + hostAlias + CA-pem resolution** — Headlamp configures OIDC
  against the *public* issuer `https://<domain>/realms/armory`
  (`headlamp_oidc_issuer_url`) and makes the in-cluster pod resolve that public
  hostname to the ingress ClusterIP via a `hostAliases` patch
  (`headlamp/tasks/deploy.yml:250-287`, vars `headlamp_oidc_resolver_*`), with
  the OpenBao root CA supplied as the trust anchor
  (`headlamp_oidc_ca_pem_url` → `pki-ext/ca/pem`). OpenBao's discovery needs
  the identical treatment (see Piece 3).
- **cert-manager Certificate for an ingress host** —
  `ansible/roles/headlamp/tasks/pki.yml:23-37` calls
  `common/apply_certificate.yml` against the `openbao-pki-external`
  ClusterIssuer. Reuse for the OpenBao host cert.
- **Generate-once-persist-to-KV** — `headlamp/tasks/oidc_client.yml:107-126`
  (generate client secret only when absent) and the KV write at lines 341-362.
- **Bootstrap auth wiring under root** — `openbao/tasks/consumer_wiring.yml`
  writes ACL policies and binds Kubernetes auth roles with the **root token**,
  because authoring policies and binding auth roles is bootstrap-time root work
  the scoped provisioner is deliberately *not* allowed to do
  ([decisions/0007](../decisions/0007-scoped-provisioner-token.md),
  [security.md](../security.md#credential-model)). The OpenBao OIDC wiring in
  this plan follows the same rule — see "Token model" below.

## Token model (read before writing any task)

The scoped `ansible-provisioner` token **cannot** enable auth methods, write
ACL policies, bind/author auth roles, or manage identity groups — by design.
Everything in Pieces 2 and 3 that touches `sys/auth/*`, `sys/policies/acl/*`,
`auth/oidc/*`, or `identity/*` is **bootstrap wiring and must use the root
token**, loaded via the existing `common/tasks/load_openbao_root_token.yml`
(same as `configure.yml` / `consumer_wiring.yml`).

Do **not** extend the provisioner policy to cover OIDC/policy/identity writes —
that would re-grant exactly the capabilities ADR 0007 removed. The only
provisioner-token use here is the existing KV-write pattern for persisting the
generated Keycloak client secret; add an `openbao` KV prefix for that
(`openbao_provisioner_kv_prefixes`, `openbao/defaults/main.yml:150`) and store
under e.g. `secret/openbao/ui-oidc`.

## Ordering problem (drives the role split)

`site.yml` order is `… openbao → nginx_ingress → vso → keycloak → headlamp →
readiness_check`. The OpenBao role runs **before** Keycloak exists, so it can
do the Keycloak-independent work (enable UI, ingress, enable the `oidc` auth
method, write ACL policies, create identity groups) but **cannot** configure
`auth/oidc/config` (needs the Keycloak discovery URL + a client secret).

Therefore split the work:

- **Pieces 1–2** land in the existing `openbao` role (no Keycloak dependency).
- **Piece 3** is a new `openbao_oidc` role inserted **after `keycloak`**
  (alongside / just before `headlamp`), structurally a sibling of the Headlamp
  OIDC client provisioning.

## Relevant facts

- UI is currently force-disabled in **two** places in
  `ansible/roles/openbao/templates/values.yaml.j2`: the server HCL block
  (`ui = false`, line 9) and the chart's top-level `ui.enabled: false`
  (line 75). Both must flip. There is **no** `openbao_ui_enabled` var yet
  despite the backlog wording — add it.
- The OpenBao Service is `ClusterIP`, HTTPS on 8200 with a self-managed server
  cert (`openbao-server-tls`). The UI rides the same 8200 listener, so the
  ingress backend protocol is **HTTPS** and the upstream cert is signed by the
  internal CA — the ingress must trust it (annotation
  `nginx.ingress.kubernetes.io/proxy-ssl-secret` / `...-verify`, or
  `backend-protocol: HTTPS` + the OpenBao CA). Mirror how the Keycloak ingress
  re-encrypts to an internal-CA upstream (see `security.md` TLS table).
- External (browser-facing) host certs come from the `openbao-pki-external`
  ClusterIssuer; `allow_subdomains` is true on the external PKI role and
  `allowed_domains = ARMORY_PUBLIC_DOMAIN`, so `openbao.armory.local` signs
  cleanly.
- The OpenBao chart supports `server.ingress.*` (enabled, ingressClassName,
  annotations, hosts, tls) — prefer it over a hand-rolled Ingress manifest, for
  consistency with the Headlamp chart-ingress approach.
- OpenBao OIDC UI callback paths are
  `https://<host>/ui/vault/auth/oidc/oidc/callback` and
  `https://<host>/oidc/callback`. Both must be in the Keycloak client
  `redirectUris` **and** the OpenBao role's `allowed_redirect_uris`.
- Sensitive tasks use
  `no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"`.
- Lint: `ansible-lint -c .ansible-lint` (production profile),
  `yamllint -c .yamllint .` (document-start always, 160-col max).

## Plan — 4 pieces, in order

### Piece 1 — Enable the UI and expose it via ingress (openbao role)

1. New defaults in `ansible/roles/openbao/defaults/main.yml`:
   ```yaml
   openbao_ui_enabled: false        # demo opt-in; set true in group_vars
   openbao_ingress_enabled: "{{ openbao_ui_enabled }}"
   openbao_ingress_host: "{{ lookup('ansible.builtin.env', 'ARMORY_OPENBAO_HOST') | default('openbao.' + (lookup('ansible.builtin.env', 'ARMORY_PUBLIC_DOMAIN') | default('armory.local', true)), true) }}"
   openbao_ingress_class: nginx
   openbao_ingress_tls_secret_name: openbao-ui-tls
   openbao_ingress_tls_issuer_name: openbao-pki-external
   openbao_cert_duration: "8760h"
   openbao_cert_renew_before: "720h"
   ```
2. `values.yaml.j2`: drive `ui = {{ openbao_ui_enabled | bool | lower }}` in
   the HCL block and `ui.enabled: {{ openbao_ui_enabled | bool | lower }}` at
   the top level. Add a `server.ingress` block gated on
   `openbao_ingress_enabled`, with `backend-protocol: HTTPS`,
   `ssl-redirect: true`, host `openbao_ingress_host`, and tls
   `openbao_ingress_tls_secret_name`. Ensure the ingress trusts the internal
   upstream cert (proxy-ssl-secret to the OpenBao CA, or document the
   `proxy-ssl-verify off` demo shortcut and list it as a gap).
3. Issue the external host cert. **Ordering gotcha:** the `openbao` role runs
   *before* `cert_manager` in `site.yml` (line 22 vs 25), so the
   `openbao-pki-external` ClusterIssuer does **not** exist during the openbao
   role's run — you cannot copy `headlamp/tasks/pki.yml` here (Headlamp runs
   long after cert-manager). Two clean options:
   - **Preferred — cert-manager ingress-shim:** annotate the chart-managed
     ingress with `cert-manager.io/cluster-issuer: "{{ openbao_ingress_tls_issuer_name }}"`
     and let cert-manager auto-create the cert into
     `openbao_ingress_tls_secret_name` once it's up. No ordering dependency;
     nginx serves its default cert for the brief window before the real one
     lands.
   - **Alternative:** create the ingress in the openbao role but issue the
     `Certificate` (via `common/apply_certificate.yml`) in the later
     `openbao_oidc` role (Piece 3), which runs well after cert_manager.
4. Add a `/etc/hosts` mapping task for `openbao_ingress_host` → ingress LB IP
   for VM-local access, copying `headlamp/tasks/deploy.yml:53-82`.
5. Enable in `inventories/development/group_vars/all.yml`:
   `openbao_ui_enabled: true`. Add `ARMORY_OPENBAO_HOST` to `.env.example`.

Acceptance: `https://openbao.<domain>` serves the OpenBao UI; a human can log
in with a **token** (root/provisioner) — proving ingress + TLS before OIDC
exists.

### Piece 2 — OpenBao OIDC scaffolding: auth method, ACL tiers, identity groups (openbao role, root token, bootstrap)

Add to `openbao/tasks/consumer_wiring.yml` (or a new
`tasks/oidc_scaffold.yml` imported from `main.yml` right after
`consumer_wiring`). All tasks use `openbao_root_token`, status `[200, 204]`,
`no_log`, `when: not ansible_check_mode` — match the existing style exactly.

1. **Enable the `oidc` auth method** at `sys/auth/oidc` (guard on
   `'oidc/' not in auth mounts`, like the kubernetes-auth guard at
   `configure.yml:289-291`).
2. **Write three ACL policies** (`sys/policies/acl/<name>`), demo-coarse but
   tiered — new vars in defaults so they're reviewable:
   - `armory-ui-admin`: read/list `secret/*` + read `sys/mounts`,
     `sys/health`, `sys/policies` (so an admin can browse). Avoid granting
     `sudo` or write to `sys/*` unless the demo needs it.
   - `armory-ui-operator`: read/list `secret/data/*` + `secret/metadata/*`.
   - `armory-ui-viewer`: list `secret/metadata/*` only (no value reads), or a
     single demo path — decide and document.
3. **Create three external identity groups** (`identity/group`, `type:
   external`) named `armory-admins` / `armory-operators` / `armory-viewers`,
   each with `policies` set to the matching ACL policy above. Capture each
   group's returned `id`.
4. **Read the oidc auth accessor** (`sys/auth` → `oidc/`.`accessor`) and
   **create a group-alias** (`identity/group-alias`) per group: `name` = the
   Keycloak group name as it appears in the `groups` claim,
   `mount_accessor` = the oidc accessor, `canonical_id` = the group id. This is
   the "identity-group → policy" mapping; OpenBao attaches the policy when a
   user's token carries that group in the configured `groups_claim`.

Idempotency: `identity/group` POST is upsert by name; group-alias needs a
lookup-or-create (GET `identity/group-alias/id` list, create on absence) — or
just POST and accept that re-creating with the same name+mount is rejected,
then ignore the duplicate status. Keep it re-runnable.

### Piece 3 — Keycloak client + OpenBao OIDC config (new `openbao_oidc` role, after keycloak)

Create `ansible/roles/openbao_oidc/` (defaults, meta, tasks/main.yml) and add
it to `playbooks/site.yml` **after `keycloak`** (before or after `headlamp` is
fine), tagged `openbao_oidc`. Load the root token via
`common/load_openbao_root_token.yml`.

1. **Provision the Keycloak `openbao` OIDC client** — copy
   `headlamp/tasks/oidc_client.yml` wholesale, changing:
   - client id → `openbao` (new var `openbao_oidc_client_id`);
   - `redirectUris` → the two OpenBao UI callbacks above;
   - `webOrigins` / `rootUrl` → `https://<openbao_ingress_host>`;
   - keep the `groups` protocol-mapper task verbatim (OpenBao needs the
     `groups` claim);
   - persist the effective client secret to OpenBao KV at
     `secret/openbao/ui-oidc` **using the provisioner token** (the only
     provisioner use here — add `openbao` to `openbao_provisioner_kv_prefixes`).
2. **Make the OpenBao pod resolve the public issuer** — patch the OpenBao
   StatefulSet with a `hostAliases` entry mapping
   `<ARMORY_PUBLIC_DOMAIN>` (the issuer hostname) → ingress-nginx ClusterIP,
   copying `headlamp/tasks/deploy.yml:250-287` (`*_oidc_resolver_*`). Restart
   the pod so the alias applies (StatefulSet rollout). The pod then unseals →
   re-run unseal may be needed; sequence carefully or use a hostAlias baked
   into the chart `server.statefulSet` values instead of a post-hoc patch
   (preferred — avoids the reseal dance).
3. **Configure `auth/oidc/config`** (root token):
   - `oidc_discovery_url`: `https://<domain>/realms/armory` (public issuer;
     reuse the `headlamp_oidc_issuer_url` derivation);
   - `oidc_discovery_ca_pem`: OpenBao root CA PEM, fetched from
     `pki-ext/ca/pem` (same source as `headlamp_oidc_ca_pem_url`);
   - `oidc_client_id`: `openbao`;
   - `oidc_client_secret`: the effective secret from step 1;
   - `default_role`: `armory-ui`.
4. **Configure the OIDC role** `auth/oidc/role/armory-ui` (root token):
   - `user_claim`: `preferred_username` (matches k3s/Headlamp);
   - `groups_claim`: `groups`;
   - `allowed_redirect_uris`: the two OpenBao UI callbacks;
   - `oidc_scopes`: `["openid", "profile", "email"]` (the client's group
     mapper emits `groups` regardless of scope, as in Headlamp);
   - `token_policies`: a minimal floor only (e.g. `default`) — real authz comes
     from the identity-group aliases in Piece 2, not the role.

Acceptance: at `https://openbao.<domain>` the "Sign in with OIDC" method
appears; logging in as `admin` lands with `armory-ui-admin` policy, `operator`
with operator, `viewer` with viewer; a user in no `armory-*` group gets only
`default` and can see nothing sensitive.

### Piece 4 — Readiness, docs, security write-up

1. **Readiness** (`readiness_check`): new `tasks/check_openbao_ui.yml` (gated
   on `openbao_ui_enabled`) asserting: UI ingress responds 200 over HTTPS with
   a trusted cert; `oidc` auth method is enabled; the three ACL policies and
   three external identity groups + aliases exist; `auth/oidc/config` has a
   non-empty `oidc_client_id`. Follow the json-parse-in-Jinja approach used in
   `check_headlamp.yml` (avoid command-module jsonpath quote-stripping).
2. **Docs**:
   - `doc/operations.md` — add OpenBao UI URL + "log in as admin/operator/
     viewer" to the access section; note the hosts-file + CA-trust prereqs.
   - `doc/security.md` — add OpenBao human OIDC to the credential model table;
     describe the three ACL tiers and the identity-group mapping; **add a
     demo-vs-production gap row** for "OpenBao UI exposed".
   - `doc/configuration.md` — document `openbao_ui_enabled`,
     `openbao_ingress_*`, `ARMORY_OPENBAO_HOST`, and the OIDC vars.
   - Consider a short ADR in `doc/decisions/` (UI exposure + OIDC authz model).
3. Update `doc/handoffs/rbac-per-role-users-plan.md`'s "Out of scope" note to
   point here, and flip this doc's status header on completion.

## Security considerations (call out, don't bury)

- **Exposing the OpenBao UI is the biggest posture change in the repo.** It
  puts a secrets-manager login on the ingress. Keep it behind
  `openbao_ui_enabled` (default **false**); only `group_vars` for the
  development/demo inventory turns it on.
- **Tier the ACL policies for real.** A viewer must not read secret *values*;
  an operator should not reach `sys/*` or PKI signing. Default to least
  privilege and widen only for what the demo actually shows.
- **Root token stays out of the UI flow.** OIDC login replaces token login for
  humans; root remains break-glass (`init-keys.yml` / `secret/openbao/init`).
- **The provisioner boundary holds.** Auth/policy/identity writes use root at
  bootstrap; the provisioner only writes the one KV path. Do not widen it.
- **Audit:** every UI action is now attributable to a Keycloak identity in the
  OpenBao audit log (`auth.display_name`) — a demo upside; mention it.

## Verification recipe

```bash
set -a; source .env; set +a
cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
yamllint -c .yamllint .
ansible-playbook playbooks/site.yml --tags openbao,openbao_oidc,headlamp
ansible-playbook playbooks/readiness_check.yml
```

Manual: browse `https://openbao.<domain>` → "Sign in with OIDC" → log in as
`viewer` (no value reads), `operator` (read secrets, no sys), `admin` (browse
broadly). Confirm the OpenBao audit log shows the Keycloak username.
