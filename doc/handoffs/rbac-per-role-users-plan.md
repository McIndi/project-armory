# Handoff: Per-Role Users & Group-Based RBAC

Status: in progress · Owner: Copilot · Validated: 2026-06-12

## Execution status (2026-06-12)

- Piece 1: implemented
- Piece 2: implemented
- Piece 3: implemented (rotation scope unchanged; follow-up still applies)
- Piece 4: implemented
- Review fixes (2026-06-12): credential-retrieval docs switched from root to
  provisioner token; readiness realm-user checks given a hardcoded fallback so
  they run from the standalone readiness playbook; dead
  `headlamp_oidc_admin_group` / `headlamp_cluster_role_name` vars removed;
  operator/viewer password-drift edge documented in operations.md.
  Pending: full rebuild + readiness validation.

## Problem (validated)

Today there is exactly **one human identity** (`admin`) and **one group**
(`armory-admins`) in the platform, and the only authorization grant is
`cluster-admin`. Worse, the grant is **not actually a group mapping**:

1. `ansible/roles/keycloak/templates/realmimport.yaml.j2` seeds one group
   (`{{ keycloak_admin_group }}` = `armory-admins`) and one user (`admin`)
   in that group. Nothing else.
2. `ansible/roles/headlamp/tasks/rbac.yml` binds a **`kind: User`** subject —
   `"<issuer>#admin"` — directly to `cluster-admin`. The group is never
   referenced in any RoleBinding/ClusterRoleBinding (repo-wide grep for
   `kind: Group` returns nothing).
3. The `groups` OIDC claim machinery exists end-to-end
   (`oidc-groups-claim=groups` in `ansible/roles/k3s/templates/config.yaml.j2`,
   group-membership protocol mapper in
   `ansible/roles/headlamp/tasks/oidc_client.yml:252`) but **nothing consumes
   it**. `doc/security.md:90` ("admin group maps to cluster-admin via
   ClusterRoleBinding") is therefore inaccurate.
No viewer/operator tiers, no per-role users.

**Out of scope: OpenBao human access.** OpenBao has no human auth method
(only `kubernetes` auth for workloads plus root/provisioner tokens), but its
UI is not exposed either, so there is nothing for a human user to log into.
Per-role OpenBao access belongs to the existing backlog item "Expose OpenBao
web ui and tie into keycloak OIDC" and should reuse the Keycloak
client-provisioning and group-mapping patterns this plan establishes. The
implementation handoff is
`doc/handoffs/openbao-ui-keycloak-oidc-plan.md`. Do not add OpenBao auth
methods, ACL policies for humans, or identity groups here. (OpenBao KV as
*credential storage* for generated passwords stays — that is existing plumbing,
not human auth.)

## What already exists (inventory — do not rebuild)

Two human logins exist today; only the first is a platform (OIDC) user:

| Login | Realm / layer | Used for | Credential flow |
|---|---|---|---|
| `admin` | `armory` realm, OIDC | Headlamp / k3s | Generated → OpenBao `secret/keycloak/realm-admin` → VSO → `keycloak-realm-admin` Secret; rotated monthly by CronJob |
| `armory-admin` | `master` realm (Keycloak-internal) | Keycloak admin console only | Generated once → OpenBao `secret/keycloak/bootstrap-admin` → applied as `keycloak-bootstrap-admin` Secret, consumed by `spec.bootstrapAdmin.user.secret` |

The master bootstrap admin (`keycloak/tasks/main.yml:118-184`) is **out of
scope**: it authenticates against Keycloak's internal master-realm store, gets
no `groups` claim, and touches neither k3s RBAC nor OpenBao. Leave it alone.

**Reusable patterns** for the pieces below:
- Generate-once-persist credential flow (read KV → keep existing or generate →
  write KV, all `no_log`): `keycloak/tasks/main.yml:118-155` — template for
  Piece 3 user passwords.
- Idempotent Keycloak admin REST provisioning (token → lookup → create/update):
  `headlamp/tasks/oidc_client.yml` — template for Piece 2 groups and Piece 3
  users.
- Least-privilege Keycloak service client (realm-management `manage-users`
  only): `keycloak/tasks/rotator.yml` — proof the realm-management role-scoping
  approach works.

**Optional extension (not core scope):** per-role *Keycloak administration* —
e.g. an operator who may manage `armory`-realm users but not clients — via
realm-management client roles assigned to groups. The rotator client is the
existing miniature of this. File as its own ticket if wanted.

## Relevant facts for implementers

- k3s OIDC flags (`ansible/roles/k3s/defaults/main.yml:76-91`):
  client-id `headlamp`, username-claim `preferred_username`, groups-claim
  `groups`, **no `oidc-groups-prefix` / `oidc-username-prefix`** — so today an
  OIDC group named e.g. `system:masters` would collide with built-ins. Add
  prefixes as part of Piece 1.
- The Headlamp OIDC client and its groups mapper are provisioned via the
  Keycloak admin REST API in `ansible/roles/headlamp/tasks/oidc_client.yml`
  (pattern to copy for any new client).
- Realm import is bootstrap-only; per-client config is done via REST
  post-import (see comment at top of `realmimport.yaml.j2`).
- Secrets convention: generated credentials are written to OpenBao KV v2 at
  `secret/<app>/...` via the provisioner token
  (`common/tasks/load_openbao_provisioner_token.yml`), optionally mirrored to
  k8s Secrets by VSO. Follow this for any seeded user passwords.
- Sensitive tasks use `no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"`.
- Lint: `ansible-lint -c .ansible-lint` (production profile),
  `yamllint -c .yamllint .` (document-start always, 160-col max).

## Plan — 4 independent pieces, in order

### Piece 1 — Make the existing admin grant a real group mapping (small)

1. Add to `k3s` role defaults + `config.yaml.j2`:
   `oidc-groups-prefix=oidc:` and `oidc-username-prefix=oidc:` (new vars
   `k3s_oidc_groups_prefix`, `k3s_oidc_username_prefix`).
2. Replace the `kind: User` subject in `headlamp/tasks/rbac.yml` with
   `kind: Group, name: "oidc:armory-admins"`. Drive it from a new default
   `headlamp_oidc_admin_group` (defaulting to
   `{{ keycloak_admin_group | default('armory-admins') }}`) plus the prefix var.
3. Update `doc/security.md` §RBAC so the doc matches reality.
4. Extend `readiness_check` (`tasks/check_headlamp.yml`) to assert the
   ClusterRoleBinding exists with a Group subject before changing rbac.yml
   (red → green).

Acceptance: `admin` user can still log in to Headlamp with cluster-admin via
group membership only; a user removed from `armory-admins` loses access.

### Piece 2 — Group tiers + variable-driven K8s RBAC (small/medium)

1. New var (keycloak role defaults, overridable in
   `inventories/development/group_vars/all.yml`):
   ```yaml
   keycloak_realm_groups:
     - armory-admins
     - armory-operators
     - armory-viewers
   ```
   Render the `groups:` list in `realmimport.yaml.j2` from it.
2. New var (headlamp role defaults):
   ```yaml
   headlamp_oidc_group_bindings:
     - { group: armory-admins,    cluster_role: cluster-admin }
     - { group: armory-operators, cluster_role: edit }
     - { group: armory-viewers,   cluster_role: view }
   ```
   Loop in `headlamp/tasks/rbac.yml` to render one ClusterRoleBinding per
   entry (name `headlamp-oidc-<group>`), replacing the single hardcoded one
   from Piece 1.
3. Readiness check: one binding per configured entry.

Note: realm import only applies at first creation; for existing realms the
new groups must also be ensured via the admin REST API
(`POST /admin/realms/{realm}/groups`, idempotent on 409) — add this to the
keycloak role alongside the import.

### Piece 3 — Seeded per-role users (medium)

1. New var:
   ```yaml
   keycloak_realm_users:
     - { username: admin,    groups: [armory-admins],    email: "...", openbao_path: keycloak/realm-users/admin }
     - { username: operator, groups: [armory-operators], email: "...", openbao_path: keycloak/realm-users/operator }
     - { username: viewer,   groups: [armory-viewers],   email: "...", openbao_path: keycloak/realm-users/viewer }
   ```
   (Existing `admin` user/password flow folds into this list; keep its
   current OpenBao path `keycloak/realm-admin` for compatibility or migrate
   deliberately.)
2. Per user: generate password → write to OpenBao KV (provisioner token,
   `no_log`) → ensure user via admin REST API (create-or-update, set groups).
   Realm import seeds only what exists at first boot; REST path is the
   idempotent source of truth, mirroring the Piece 2 group logic.
3. Decide: rotation CronJob currently targets only `admin`
   (`keycloak_rotator_*` vars, `realm_admin_rotator.yaml.j2`). Out of scope to
   generalize here — file a follow-up ticket.
4. Readiness check: each configured user exists in the realm and has the
   expected group memberships.

### Piece 4 — Docs + validation sweep (small)

- Update `doc/security.md` access-control table (remove the "Coarse RBAC —
  Backlog" row), `doc/configuration.md` (new vars), `doc/operations.md`
  (how to log in as each role to Headlamp/kubectl).
- Full run: `ansible-playbook playbooks/site.yml` then
  `playbooks/readiness_check.yml` green in the Vagrant VM.

## Verification recipe (all pieces)

```bash
set -a; source .env; set +a
cd "${ARMORY_ANSIBLE_ROOT}"
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
ansible-playbook playbooks/site.yml --tags <piece-tag>
ansible-playbook playbooks/readiness_check.yml
```

Manual: log in to Headlamp as `viewer` → confirm read-only; as `operator`
→ confirm edit but no RBAC changes; as `admin` → confirm cluster-admin.
