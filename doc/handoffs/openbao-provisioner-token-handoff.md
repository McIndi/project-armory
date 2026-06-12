# Handoff — Replace Root Token with Scoped Provisioner Token

> **ARCHIVED — executed. Kept for history; do not follow as current
> instructions.** Durable rationale lives in [../decisions/](../decisions/).

Status: ready for implementation (handoff to Copilot)
Scope: stop using the OpenBao root token as the everyday Ansible automation
credential. Move consumer ACL-policy and k8s-auth-role authorship into the
openbao role's bootstrap phase (root, where it belongs — cert-manager
precedent); mint a scoped, periodic `ansible-provisioner` token during the
openbao role run; switch the keycloak, headlamp, and readiness_check roles to
it; reserve the root token for bootstrap (openbao role only) and break-glass.
Preconditions: `site.yml` deploys and `readiness_check.yml` passes on main
(including the audit-device work from
`doc/handoffs/openbao-audit-device-handoff.md`).
Deployment model: **fresh rebuild only.** Validation is a clean
`vagrant destroy -f && vagrant up` + full `site.yml`. No migration path for
existing deployments is needed or provided.
Backlog ref: `backlog.md` → "Stop using the OpenBao root token…".

## How to use this doc (Copilot)
Execute tasks in order. Each task lists exact files and the change. Match
existing role conventions exactly: `ansible.builtin.uri` against the role's
`*_openbao_api_addr` with `X-Vault-Token`,
`no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"`,
`when: not ansible_check_mode`, GET-then-conditional-write idempotency. The
model for policy creation is the cert-manager policy task in
`roles/openbao/tasks/configure.yml` ("Write cert-manager policy (sign certs
via PKI)") — note it uses `method: POST` and sets no `changed_when` (the uri
module reports ok by default); copy that shape and add `changed_when: false`
only where this doc says to. The model for the encrypted-file storage is the
init-keys flow in `roles/openbao/tasks/init.yml` (write `.plain` →
`ansible-vault encrypt` → remove `.plain`). The model for cross-role shared
variables is the `keycloak_enabled` block at the top of
`inventories/development/group_vars/all.yml` (values both producer and
consumer roles must see live there, not in role defaults). Run validation
(§10) after each phase. Do not invent new abstractions. Ask before deviating.

## 1. Current state (measured inventory)

`common/tasks/load_openbao_root_token.yml` decrypts the root token from
`/opt/openbao/init-keys.yml` and these call sites use it:

| File | Method + path (defaults resolved) |
|---|---|
| `keycloak/tasks/main.yml` | GET+POST `secret/data/keycloak/db`, GET+POST `secret/data/keycloak/realm-admin`, GET+POST `secret/data/keycloak/bootstrap-admin`, POST `sys/policies/acl/keycloak-vso`, POST `auth/kubernetes/role/keycloak-vso` (8 uri tasks) |
| `keycloak/tasks/rotator.yml` | POST `secret/data/keycloak/rotator`, POST `sys/policies/acl/keycloak-realm-admin-rotator`, POST `auth/kubernetes/role/keycloak-realm-admin-rotator` (3 uri tasks) |
| `headlamp/tasks/deploy.yml` | POST `sys/policies/acl/headlamp-vso`, POST `auth/kubernetes/role/headlamp-vso` (2 uri tasks) |
| `headlamp/tasks/oidc_client.yml` | GET `pki-ext/ca/pem` (root CA PEM for OIDC trust), POST `secret/data/headlamp/oidc` (2 uri tasks) |
| `readiness_check/tasks/check_openbao.yml` | GET `sys/audit` (1 uri task) |
| `openbao/tasks/configure.yml`, `init.yml`, `unseal.yml` | bootstrap: mounts, PKI, auth, policies, audit — **stays on root** (see §2) |

These call sites split into two groups, and the split is the design:

- **Bootstrap wiring (one-time, content is static templating of defaults):**
  the `sys/policies/acl/*` and `auth/kubernetes/role/*` writes. These move
  into the openbao role (Task 2) and stay on root.
- **Per-run provisioning (values change across runs):** the KV reads/writes,
  the PKI CA PEM read, and the readiness `sys/audit` read. These switch to
  the provisioner token, and *only these* define the provisioner policy (§5).

## 2. Design decisions (do not relitigate)

- **The openbao role keeps the root token.** init/unseal/configure create
  mounts, PKI, auth backends, and policies — root-level by nature, and the
  role already obtains the token from its own init/unseal facts, not from the
  common loader. Everything *downstream* of the openbao role switches.
- **Consumer ACL policies and k8s auth roles are bootstrap, not
  provisioning.** The keycloak-vso, keycloak-realm-admin-rotator, and
  headlamp-vso policies and their k8s auth roles are written by the openbao
  role with root (new `consumer_wiring.yml`, Task 2), exactly as the
  cert-manager policy already is in `openbao/tasks/configure.yml`. The
  provisioner token gets **no** `sys/policies/acl/*` or
  `auth/kubernetes/role/*` capabilities. Rationale: a token that can author
  policy content and bind policies to identities can mint itself (or a pod)
  arbitrary capabilities — granting those paths would make the provisioner
  root-adjacent and the scoping theater. ACL `allowed_parameters` cannot fix
  this (a policy body is an opaque HCL string), so authorship moves to root
  at bootstrap instead. Ordering is safe: openbao runs before
  keycloak/headlamp in `site.yml`, and OpenBao does not validate that bound
  service accounts exist when an auth role is written.
- **Shared wiring values live in `group_vars/all.yml`** (Task 1). The policy
  bodies and auth-role bindings reference names currently defined in
  keycloak/headlamp role defaults (KV paths, SA names, namespaces). Role
  defaults are invisible across roles, so those values **move** (not copy —
  single source of truth) to `inventories/development/group_vars/all.yml`,
  following the existing `keycloak_enabled` precedent documented at the top
  of that file.
- **Credential type: periodic orphan service token**, period `768h` (32 days),
  policy `ansible-provisioner`, default policy attached. Periodic = never
  hard-expires while renewed; every playbook run renews it. Orphan = survives
  later revocation of its parent. Not k8s auth: Ansible runs on the VM host,
  not in a pod, so there is no native k8s identity to bind — token auth with
  encrypted-at-rest storage mirrors the existing init-keys handling.
- **Storage:** `/opt/openbao/provisioner-token.yml`, Ansible-Vault-encrypted
  with the existing `{{ openbao_vault_pass_file }}`, same pattern and
  permissions as `init-keys.yml`. (Same threat-model caveat as init-keys —
  the pass file sits beside it; accepted for this demo, tracked separately.)
- **Self-healing:** the openbao role validates the stored token via
  `lookup-self` on every run and re-mints with root if it is missing,
  invalid, revoked, **or undecryptable** (a failed `ansible-vault decrypt`
  counts as invalid, not as a play failure). Consumers never touch root; if
  their token is bad, the fix is `--tags openbao`, and their failure message
  must say so.
- **Break-glass:** root token stays where it is today (encrypted in
  `init-keys.yml`, mirrored to KV `secret/openbao/init`).
  `common/tasks/load_openbao_root_token.yml` is retained but demoted to a
  documented break-glass helper with zero in-repo consumers outside the
  openbao role.
- **`sys/audit` is a root-protected endpoint**: reading it requires the
  `sudo` capability. The policy grants `["read", "sudo"]` on `sys/audit`
  only — capabilities gate the HTTP method, so this cannot be used to enable
  or disable audit devices.
- **Residual risk (document, don't fix):** the provisioner can read and
  overwrite every secret it provisions — including
  `secret/data/keycloak/bootstrap-admin`, i.e. Keycloak admin takeover.
  That is irreducible (provisioning secrets is its job) and is ordinary
  least-privilege blast radius, not escalation. The README section in Task 6
  states this explicitly.

## 3. Task 1 — Shared values + defaults

**(a) `ansible/inventories/development/group_vars/all.yml`** — add a new
commented block (style of the existing `keycloak_enabled` block). These
variables **move here from role defaults**; delete each from
`roles/keycloak/defaults/main.yml` / `roles/headlamp/defaults/main.yml` in
the same commit. Criterion for inclusion: the openbao role's new bootstrap
wiring (Task 2) consumes it AND a consumer role also consumes it.

```yaml
# OpenBao consumer wiring — shared between the openbao role (which writes the
# consumer ACL policies and k8s auth roles at bootstrap, with root) and the
# keycloak/headlamp roles (which write KV secrets with the provisioner
# token). Must live here, NOT in role defaults, because role defaults are
# invisible across roles. Single source of truth: the role-default copies of
# these names have been removed.
keycloak_namespace: keycloak
keycloak_vso_sa_name: keycloak-vso
keycloak_openbao_policy_name: keycloak-vso
keycloak_openbao_k8s_role: keycloak-vso
keycloak_openbao_db_path: keycloak/db
keycloak_openbao_realm_admin_path: keycloak/realm-admin
keycloak_openbao_rotator_path: keycloak/rotator
keycloak_rotator_sa_name: keycloak-realm-admin-rotator
keycloak_rotator_openbao_policy_name: keycloak-realm-admin-rotator
keycloak_rotator_openbao_k8s_role: keycloak-realm-admin-rotator
headlamp_namespace: headlamp
headlamp_vso_sa_name: headlamp-vso
headlamp_openbao_policy_name: headlamp-vso
headlamp_openbao_k8s_role: headlamp-vso
headlamp_openbao_oidc_path: headlamp/oidc
```

Values copied verbatim from the current role defaults (`keycloak/defaults`
lines 6, 94–97, 100, 124, 126–128; `headlamp/defaults` lines 7, 66, 77–79).
`keycloak_openbao_bootstrap_admin_path` stays in keycloak defaults (no
cross-role consumer). `openbao_kv_mount` stays in openbao defaults — the new
wiring tasks run inside the openbao role and see it natively; consumer
`*_openbao_kv_mount` derivation chains (`openbao_kv_mount |
default('secret')`) are unchanged. After deleting the role-default copies,
verify nothing else breaks:
`grep -rn "keycloak_vso_sa_name\|headlamp_vso_sa_name\|keycloak_namespace\|headlamp_namespace" ansible/` —
every hit must be a consumer of the variable, not a second definition.
(Note: development is the only inventory; any future inventory must define
this block.)

**(b) `ansible/roles/openbao/defaults/main.yml`** — add (comment style of
neighbors):

```yaml
# Ansible provisioner token: scoped credential minted by this role and used
# by downstream roles (keycloak, headlamp, readiness_check) instead of the
# root token. Root remains bootstrap/break-glass only. Consumer ACL policies
# and k8s auth roles are written by this role at bootstrap (consumer_wiring)
# so the provisioner needs no sys/policies or auth/role capabilities.
openbao_provisioner_policy_name: ansible-provisioner
openbao_provisioner_token_file: "{{ openbao_work_dir }}/provisioner-token.yml"
openbao_provisioner_token_period: 768h
openbao_provisioner_token_display_name: ansible-provisioner
# KV path prefixes (under openbao_kv_mount) the provisioner may write. Keep
# in sync with the keycloak/headlamp *_path values in group_vars/all.yml.
openbao_provisioner_kv_prefixes:
  - keycloak
  - headlamp
```

**(c) `ansible/roles/common/defaults/main.yml`** — add alongside the existing
`common_openbao_*` fallbacks (these exist precisely because openbao role
defaults are invisible to other roles — the new loader needs the same
treatment):

```yaml
# Fallback path for the provisioner token file when the openbao role's
# defaults are not in scope (consumer roles including this loader).
common_openbao_provisioner_token_file: /opt/openbao/provisioner-token.yml
```

## 4. Task 2 — Consumer wiring moves to the openbao role

New file `ansible/roles/openbao/tasks/consumer_wiring.yml`, imported in
`ansible/roles/openbao/tasks/main.yml` **after** `configure.yml` (before
`audit_rotate.yml`), tags `[openbao, openbao_consumer_wiring]`. All tasks:
root token auth, standard `no_log`, `when: not ansible_check_mode`, modeled
on the cert-manager policy task. Six uri tasks, content **moved verbatim**
(URL host becomes `{{ openbao_api_addr }}`, mount/path variables resolve via
group_vars from Task 1; preserve policy bodies exactly, including the
`metadata` read paths and the `ttl` values):

1. POST `sys/policies/acl/{{ keycloak_openbao_policy_name }}` — body from
   `keycloak/tasks/main.yml` "Write OpenBao ACL policy for Keycloak DB
   credentials (VSO read)" (data+metadata read on db and realm-admin paths).
2. POST `auth/kubernetes/role/{{ keycloak_openbao_k8s_role }}` — body from
   "Configure OpenBao Kubernetes auth role for Keycloak VSO sync"
   (`keycloak_vso_sa_name` / `keycloak_namespace`, ttl 24h).
3. POST `sys/policies/acl/{{ keycloak_rotator_openbao_policy_name }}` — body
   from `keycloak/tasks/rotator.yml` "Write OpenBao ACL policy for the
   rotator" (read rotator path, create/update/read realm-admin path).
4. POST `auth/kubernetes/role/{{ keycloak_rotator_openbao_k8s_role }}` — body
   from "Configure OpenBao Kubernetes auth role for the rotator"
   (`keycloak_rotator_sa_name` / `keycloak_namespace`, ttl 10m).
5. POST `sys/policies/acl/{{ headlamp_openbao_policy_name }}` — body from
   `headlamp/tasks/deploy.yml` "Write OpenBao ACL policy for Headlamp OIDC
   secret" (data+metadata read on oidc path).
6. POST `auth/kubernetes/role/{{ headlamp_openbao_k8s_role }}` — body from
   "Configure OpenBao Kubernetes auth role for Headlamp VSO sync"
   (`headlamp_vso_sa_name` / `headlamp_namespace`, ttl 24h).

Write all six unconditionally (no gating on `keycloak_enabled` — writing
wiring for a disabled consumer is harmless and keeps this file static).
**Delete** the six source tasks from the consumer roles in the same commit:

- `keycloak/tasks/main.yml`: the policy + auth-role tasks (currently
  lines ~188–233).
- `keycloak/tasks/rotator.yml`: the policy + auth-role tasks (currently
  lines ~209–245).
- `headlamp/tasks/deploy.yml`: the policy + auth-role tasks (currently
  lines ~9–48) **and** the now-orphaned "Load OpenBao root token" import at
  the top — after this deletion, deploy.yml makes no OpenBao API calls.

After this task: `site.yml` must still deploy green (consumers still use the
root token for their remaining KV/PKI calls until Task 5), and
`grep -rln "sys/policies/acl\|auth/kubernetes/role" ansible/roles/keycloak ansible/roles/headlamp`
must return nothing.

## 5. Task 3 — Provisioner policy + token mint (openbao role)

New file `ansible/roles/openbao/tasks/provisioner_token.yml`, imported in
`ansible/roles/openbao/tasks/main.yml` **after** `consumer_wiring.yml`
(before `audit_rotate.yml`), tags `[openbao, openbao_provisioner]`. All
tasks: root token auth, standard `no_log`, `when: not ansible_check_mode`.
Sequence:

1. **Write provisioner policy** — POST
   `{{ openbao_api_addr }}/v1/sys/policies/acl/{{ openbao_provisioner_policy_name }}`,
   `status_code: [200, 204]`, `changed_when: false` (root rewrites the
   policy each run so policy edits in git always converge), body `policy:`
   built with a Jinja loop over `openbao_provisioner_kv_prefixes` and
   `{{ openbao_kv_mount }}` / `{{ openbao_pki_external_mount }}` (inline
   `policy: |` block, matching the cert-manager policy task — do not
   hardcode mount names). Rendered content with defaults:

   ```hcl
   # KV v2 application secrets owned by consumer roles
   path "secret/data/keycloak/*" { capabilities = ["create", "read", "update"] }
   path "secret/data/headlamp/*" { capabilities = ["create", "read", "update"] }
   # Root CA PEM read for Headlamp OIDC trust (headlamp/tasks/oidc_client.yml)
   path "pki-ext/ca/pem" { capabilities = ["read"] }
   # Readiness: list audit devices (sudo gates the path, read gates the method)
   path "sys/audit" { capabilities = ["read", "sudo"] }
   # Token self-maintenance
   path "auth/token/lookup-self" { capabilities = ["read"] }
   path "auth/token/renew-self"  { capabilities = ["update"] }
   ```

   No `sys/policies/acl/*`, no `auth/kubernetes/role/*` — that wiring is
   root-at-bootstrap (Task 2). Nothing may be added to this policy without
   updating §2's design decisions.

2. **Probe stored token** — `ansible.builtin.stat` on
   `{{ openbao_provisioner_token_file }}`. If present: decrypt via
   `ansible-vault decrypt --output -` (same command shape as
   `common/load_openbao_root_token.yml`) with `failed_when: false` — a
   decrypt failure means re-mint, never a play failure. On successful
   decrypt, parse `provisioner_token:` from the YAML, then GET
   `/v1/auth/token/lookup-self` **using that token**,
   `status_code: [200, 403]`, `failed_when: false`. Token is *valid* iff
   decrypt succeeded, status 200, and `json.data.policies` contains
   `openbao_provisioner_policy_name`.
3. **Mint when needed** — when the file is absent, undecryptable, or the
   lookup failed: POST `/v1/auth/token/create` (root) with body:

   ```yaml
   body:
     policies: ["{{ openbao_provisioner_policy_name }}"]
     period: "{{ openbao_provisioner_token_period }}"
     no_parent: true
     display_name: "{{ openbao_provisioner_token_display_name }}"
   ```

   (`no_parent` requires sudo — the root token has it.) Then persist exactly
   like init-keys: write
   `{{ openbao_provisioner_token_file }}.plain` (mode `0400`, root:root,
   content `provisioner_token: <client_token>` as YAML), `ansible-vault
   encrypt --vault-password-file {{ openbao_vault_pass_file }} --output
   {{ openbao_provisioner_token_file }}`, remove `.plain`.
4. **Renew on every run** — when the stored token was valid: POST
   `/v1/auth/token/renew-self` with the provisioner token,
   `status_code: 200`, `changed_when: false`.

Idempotency contract: second consecutive run = policy POST (`changed_when:
false`), stat, decrypt, lookup-self 200, renew-self — zero changed.

## 6. Task 4 — Common loader

New file `ansible/roles/common/tasks/load_openbao_provisioner_token.yml`,
mirroring `load_openbao_root_token.yml` line-for-line in structure —
**including the fallback-default pattern**, which is what makes the loader
work when included from roles that cannot see openbao defaults:

- Decrypt
  `{{ openbao_provisioner_token_file | default(common_openbao_provisioner_token_file) }}`
  with `{{ openbao_vault_pass_file | default(common_openbao_vault_pass_file) }}`
  when `openbao_provisioner_token` is undefined;
  `set_fact: openbao_provisioner_token` from the YAML.
- Assert non-empty with failure message:
  `"OpenBao provisioner token is not available. Run 'ansible-playbook
  playbooks/site.yml --tags openbao' to mint it."`
- Standard `no_log` on every task.

Also in this task: add a header comment to
`common/tasks/load_openbao_root_token.yml`:
`# BREAK-GLASS ONLY. Day-to-day automation must use
load_openbao_provisioner_token.yml. Do not add new consumers.`
Update `roles/common/README.md` to document both loaders and their intended
use.

## 7. Task 5 — Switch the consumers

Mechanical, per file. Replace the `include_role`/`import_role` +
`tasks_from: load_openbao_root_token.yml` with
`load_openbao_provisioner_token.yml`, and replace every
`X-Vault-Token: "{{ openbao_root_token }}"` with
`X-Vault-Token: "{{ openbao_provisioner_token }}"`. Counts are
**post-Task-2** (the policy/auth-role tasks are already gone):

- `ansible/roles/keycloak/tasks/main.yml` (loader + 6 uri tasks: GET+POST
  db, realm-admin, bootstrap-admin)
- `ansible/roles/keycloak/tasks/rotator.yml` (loader + 1 uri task: POST
  rotator KV)
- `ansible/roles/headlamp/tasks/oidc_client.yml` (loader + 2 uri tasks: GET
  CA PEM, POST oidc KV)
- `ansible/roles/readiness_check/tasks/check_openbao.yml` (loader + 1 uri
  task: GET `sys/audit`) — **also move the loader include out from under its
  `when: openbao_audit_enabled | default(true) | bool` gate** (currently
  lines ~119–123): Task 6's new check needs the token even when audit is
  disabled.

(`headlamp/tasks/deploy.yml` no longer appears here — Task 2 removed its
loader and both uri tasks.)

After this task the following grep must return **only** files inside
`roles/openbao/` and `roles/common/`:

```bash
grep -rln "openbao_root_token" ansible/roles
```

Anything else is a missed call site — fix it, do not proceed.

## 8. Task 6 — Readiness, teardown, docs

- `ansible/roles/readiness_check/tasks/check_openbao.yml`: add one result row
  `component: OpenBao, check_name: 'Provisioner token valid'` — GET
  `/v1/auth/token/lookup-self` with the provisioner token (`failed_when:
  false` on the probe), `pass` when status 200 **and**
  `openbao_provisioner_policy_name | default('ansible-provisioner')` is in
  `json.data.policies`, else `fail`. Use `| default(...)` on every
  openbao-role variable referenced here (role-defaults scoping — same reason
  the audit check defaults `openbao_audit_enabled`).
- `ansible/roles/openbao/tasks/teardown.yml`: best-effort revoke — POST
  `/v1/auth/token/revoke-self` with the provisioner token, `failed_when:
  false`; then remove `{{ openbao_provisioner_token_file }}`
  (`state: absent`, `failed_when: false`), matching existing teardown tone.
- `README.md`: add an "Automation Credentials" subsection (near "Sensitive
  Output"): what the provisioner token is, its exact scope (point at the
  policy in `provisioner_token.yml`), where it is stored, that consumer ACL
  policies and k8s auth roles are written only at bootstrap by the openbao
  role (so the provisioner cannot author policies or bind identities —
  direct or indirect privilege escalation paths are closed), the residual
  blast radius (the token can read/overwrite the app secrets it provisions,
  including the Keycloak bootstrap-admin credentials), that root is
  bootstrap/break-glass only, the break-glass procedure (decrypt
  `init-keys.yml` or read KV `secret/openbao/init`), and the re-mint command
  (`--tags openbao`).

## 9. Out of scope

Revoking/regenerating the root token itself; moving Ansible to k8s/AppRole
auth; rotating the `.vault-pass` co-location issue (tracked in backlog);
scoping VSO's own k8s-auth roles (already least-privilege per consumer);
audit log shipping.

## 10. Validation

Lint after each phase (inside the VM, from `${ARMORY_ANSIBLE_ROOT}` with
`.env` sourced):

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
```

Final validation is a from-scratch rebuild (host, repo root):

```bash
vagrant destroy -f && vagrant up
```

Then inside the VM:

```bash
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml          # full second run: provisioner tasks report zero changed
ansible-playbook playbooks/readiness_check.yml
```

Scope verification (the new token must work where intended and *only* there):

```bash
TOKEN=$(sudo ansible-vault view --vault-password-file /opt/openbao/.vault-pass \
  /opt/openbao/provisioner-token.yml | awk '/provisioner_token:/ {print $2}')
ADDR=https://openbao.openbao.svc.cluster.local:8200
# Allowed: 200
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/secret/data/keycloak/db
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/pki-ext/ca/pem
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/sys/audit
# Denied: 403
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/sys/mounts
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/secret/data/openbao/init
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" \
  -X PUT -d '{"type":"file"}' $ADDR/v1/sys/audit/evil
# Denied: 403 — escalation paths must be closed (policy authorship, role binding)
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" \
  -X PUT -d '{"policy":"path \"*\" { capabilities = [\"sudo\"] }"}' \
  $ADDR/v1/sys/policies/acl/keycloak-vso
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" \
  -X POST -d '{"policies":["root"]}' $ADDR/v1/auth/kubernetes/role/keycloak-vso
```

Self-healing check:

```bash
curl -sk -H "X-Vault-Token: $TOKEN" -X POST $ADDR/v1/auth/token/revoke-self
ansible-playbook playbooks/site.yml --tags openbao    # re-mints
ansible-playbook playbooks/site.yml --tags keycloak_install   # consumers work again
```

Acceptance: readiness shows `OpenBao / Provisioner token valid: pass` and
`Audit device enabled: pass`; the §7 grep is clean; the scope-verification
matrix returns exactly 200/200/200 then 403/403/403/403/403; VSO-synced
secrets still appear (k8s auth roles written at bootstrap still work:
`kubectl get secret -n keycloak`, `-n headlamp`); revoke + `--tags openbao`
self-heals; full second `site.yml` run reports zero changed for provisioner
tasks.
