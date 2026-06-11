# Handoff — Replace Root Token with Scoped Provisioner Token

Status: ready for implementation (handoff to Copilot)
Scope: stop using the OpenBao root token as the everyday Ansible automation
credential. Mint a scoped, periodic `ansible-provisioner` token during the
openbao role run; switch the keycloak, headlamp, and readiness_check roles to
it; reserve the root token for bootstrap (openbao role only) and break-glass.
Preconditions: `site.yml` deploys and `readiness_check.yml` passes on main
(including the audit-device work from `handoffs/openbao-audit-device-handoff.md`).
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
`roles/openbao/tasks/configure.yml` ("Write cert-manager policy"). The model
for the encrypted-file storage is the init-keys flow in
`roles/openbao/tasks/init.yml` (write `.plain` → `ansible-vault encrypt` →
remove `.plain`). Run validation (§8) after each phase. Do not invent new
abstractions. Ask before deviating.

## 1. Current state (measured inventory)

`common/tasks/load_openbao_root_token.yml` decrypts the root token from
`/opt/openbao/init-keys.yml` and these call sites use it:

| File | Method + path (defaults resolved) |
|---|---|
| `keycloak/tasks/main.yml` | GET+POST `secret/data/keycloak/db`, GET+POST `secret/data/keycloak/realm-admin`, GET+POST `secret/data/keycloak/bootstrap-admin`, POST `sys/policies/acl/keycloak-vso`, POST `auth/kubernetes/role/keycloak-vso` |
| `keycloak/tasks/rotator.yml` | POST `secret/data/keycloak/rotator`, POST `sys/policies/acl/keycloak-realm-admin-rotator`, POST `auth/kubernetes/role/keycloak-realm-admin-rotator` |
| `headlamp/tasks/deploy.yml` | POST `sys/policies/acl/headlamp-vso`, POST `auth/kubernetes/role/headlamp-vso` |
| `headlamp/tasks/oidc_client.yml` | POST `secret/data/headlamp/oidc` |
| `readiness_check/tasks/check_openbao.yml` | GET `sys/audit` |
| `openbao/tasks/configure.yml`, `init.yml`, `unseal.yml` | bootstrap: mounts, PKI, auth, policies, audit — **stays on root** (see §2) |

That table *is* the required permission set. Nothing else may go in the policy.

## 2. Design decisions (do not relitigate)

- **The openbao role keeps the root token.** init/unseal/configure create
  mounts, PKI, auth backends, and policies — root-level by nature, and the
  role already obtains the token from its own init/unseal facts, not from the
  common loader. Everything *downstream* of the openbao role switches.
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
  `lookup-self` on every run and re-mints with root if it is missing, invalid,
  or revoked. Consumers never touch root; if their token is bad, the fix is
  `--tags openbao`, and their failure message must say so.
- **Break-glass:** root token stays where it is today (encrypted in
  `init-keys.yml`, mirrored to KV `secret/openbao/init`).
  `common/tasks/load_openbao_root_token.yml` is retained but demoted to a
  documented break-glass helper with zero in-repo consumers outside the
  openbao role.
- **`sys/audit` is a root-protected endpoint**: reading it requires the
  `sudo` capability. The policy grants `["read", "sudo"]` on `sys/audit`
  only — read-only method, no `update`/`delete`, so the provisioner cannot
  enable or disable audit devices.

## 3. Task 1 — Defaults

`ansible/roles/openbao/defaults/main.yml`, add (comment style of neighbors):

```yaml
# Ansible provisioner token: scoped credential minted by this role and used
# by downstream roles (keycloak, headlamp, readiness_check) instead of the
# root token. Root remains bootstrap/break-glass only.
openbao_provisioner_policy_name: ansible-provisioner
openbao_provisioner_token_file: "{{ openbao_work_dir }}/provisioner-token.yml"
openbao_provisioner_token_period: 768h
openbao_provisioner_token_display_name: ansible-provisioner
# Consumer surfaces covered by the provisioner policy. Keep in sync with
# keycloak_openbao_* / headlamp_openbao_* defaults if those are overridden.
openbao_provisioner_kv_prefixes:
  - keycloak
  - headlamp
openbao_provisioner_managed_acl_policies:
  - keycloak-vso
  - keycloak-realm-admin-rotator
  - headlamp-vso
openbao_provisioner_managed_k8s_auth_roles:
  - keycloak-vso
  - keycloak-realm-admin-rotator
  - headlamp-vso
```

## 4. Task 2 — Policy + token mint (openbao role)

New file `ansible/roles/openbao/tasks/provisioner_token.yml`, imported in
`ansible/roles/openbao/tasks/main.yml` **after** `configure.yml` (before
`audit_rotate.yml`), tags `[openbao, openbao_provisioner]`. All tasks: root
token auth, standard `no_log`, `when: not ansible_check_mode`. Sequence:

1. **Write provisioner policy** — PUT
   `{{ openbao_api_addr }}/v1/sys/policies/acl/{{ openbao_provisioner_policy_name }}`,
   `status_code: [200, 204]`, body `policy:` built with Jinja loops over the
   three list vars (inline `policy: |` block, matching the cert-manager
   policy task). Rendered content with defaults:

   ```hcl
   # KV v2 application secrets owned by consumer roles
   path "secret/data/keycloak/*"   { capabilities = ["create", "read", "update"] }
   path "secret/data/headlamp/*"   { capabilities = ["create", "read", "update"] }
   # VSO consumer wiring managed by the keycloak/headlamp roles
   path "sys/policies/acl/keycloak-vso"                 { capabilities = ["create", "read", "update"] }
   path "sys/policies/acl/keycloak-realm-admin-rotator" { capabilities = ["create", "read", "update"] }
   path "sys/policies/acl/headlamp-vso"                 { capabilities = ["create", "read", "update"] }
   path "auth/kubernetes/role/keycloak-vso"                 { capabilities = ["create", "read", "update"] }
   path "auth/kubernetes/role/keycloak-realm-admin-rotator" { capabilities = ["create", "read", "update"] }
   path "auth/kubernetes/role/headlamp-vso"                 { capabilities = ["create", "read", "update"] }
   # Readiness: list audit devices (root-protected; read-only)
   path "sys/audit" { capabilities = ["read", "sudo"] }
   # Token self-maintenance
   path "auth/token/lookup-self" { capabilities = ["read"] }
   path "auth/token/renew-self"  { capabilities = ["update"] }
   ```

   Unconditional PUT is correct here (root rewrites the policy each run;
   `changed_when: false` like the cert-manager policy task) so policy edits
   in git always converge.

2. **Probe stored token** — `ansible.builtin.stat` on
   `{{ openbao_provisioner_token_file }}`. If present: decrypt via
   `ansible-vault decrypt --output -` (same command shape as
   `common/load_openbao_root_token.yml`), parse `provisioner_token:` from the
   YAML, then GET `/v1/auth/token/lookup-self` **using that token**,
   `status_code: [200, 403]`, `failed_when: false`. Token is *valid* iff
   status 200 and `json.data.policies` contains
   `openbao_provisioner_policy_name`.
3. **Mint when needed** — when the file is absent or the lookup failed:
   POST `/v1/auth/token/create` (root) with body:

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

Idempotency contract: second consecutive run = policy PUT (`changed_when:
false`), stat, decrypt, lookup-self 200, renew-self — zero changed.

## 5. Task 3 — Common loader

New file `ansible/roles/common/tasks/load_openbao_provisioner_token.yml`,
mirroring `load_openbao_root_token.yml` line-for-line in structure:

- Decrypt `{{ openbao_provisioner_token_file }}` with
  `{{ openbao_vault_pass_file }}` when `openbao_provisioner_token` is
  undefined; `set_fact: openbao_provisioner_token` from the YAML.
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

## 6. Task 4 — Switch the consumers

Mechanical, per file. Replace the `include_role`/`tasks_from:
load_openbao_root_token.yml` with `load_openbao_provisioner_token.yml`, and
replace every `X-Vault-Token: "{{ openbao_root_token }}"` with
`X-Vault-Token: "{{ openbao_provisioner_token }}"`:

- `ansible/roles/keycloak/tasks/main.yml` (loader + 8 uri tasks)
- `ansible/roles/keycloak/tasks/rotator.yml` (loader + 3 uri tasks)
- `ansible/roles/headlamp/tasks/deploy.yml` (loader + 2 uri tasks)
- `ansible/roles/headlamp/tasks/oidc_client.yml` (loader + 1 uri task)
- `ansible/roles/readiness_check/tasks/check_openbao.yml` (audit check:
  loader + 1 uri task)

After this task the following grep must return **only** files inside
`roles/openbao/` and `roles/common/`:

```bash
grep -rln "openbao_root_token" ansible/roles
```

Anything else is a missed call site — fix it, do not proceed.

## 7. Task 5 — Readiness, teardown, docs

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
  policy), where it is stored, that root is bootstrap/break-glass only, the
  break-glass procedure (decrypt `init-keys.yml` or read KV
  `secret/openbao/init`), and the re-mint command (`--tags openbao`).

## 8. Validation

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
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/sys/audit
# Denied: 403
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/sys/mounts
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" $ADDR/v1/secret/data/openbao/init
curl -sk -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $TOKEN" \
  -X PUT -d '{"type":"file"}' $ADDR/v1/sys/audit/evil
```

Self-healing check:

```bash
curl -sk -H "X-Vault-Token: $TOKEN" -X POST $ADDR/v1/auth/token/revoke-self
ansible-playbook playbooks/site.yml --tags openbao    # re-mints
ansible-playbook playbooks/site.yml --tags keycloak_install   # consumers work again
```

Acceptance: readiness shows `OpenBao / Provisioner token valid: pass` and
`Audit device enabled: pass`; the §6 grep is clean; the scope-verification
matrix returns exactly 200/200/403/403/403; revoke + `--tags openbao`
self-heals; full second `site.yml` run reports zero changed for provisioner
tasks.

## 9. Out of scope

Revoking/regenerating the root token itself; moving Ansible to k8s/AppRole
auth; rotating the `.vault-pass` co-location issue (tracked in backlog);
scoping VSO's own k8s-auth roles (already least-privilege per consumer);
audit log shipping.
