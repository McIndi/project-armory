# Agent Notes

Working notes for AI agents (and humans) making changes in this repo.
Orientation: [doc/architecture.md](doc/architecture.md). Commands:
[doc/operations.md](doc/operations.md). Past decisions:
[doc/decisions/](doc/decisions/) — check there before re-proposing something
(e.g. version pinning, `kubernetes.core`).

## Execution model

Everything runs inside the Vagrant VM; the repo is mounted at `/vagrant`.
Before any ansible command, source the environment:

```bash
set -a; source /vagrant/.env; set +a
cd "${ARMORY_ANSIBLE_ROOT}"
```

The `env_guard` role fails fast if this wasn't done. There is no
`ansible.cfg`; all Ansible settings come from `ANSIBLE_*` vars in `.env`.

## `vagrant ssh -c` quoting

Quoting mistakes here are one of the most common time sinks during
fact-finding. Rules that hold:

- Use **double quotes** around the remote command:
  `vagrant ssh -c "sudo k3s kubectl get pods -A"`.
- Escape `$` as `\$` for anything that must expand **on the VM**, not the
  host: `vagrant ssh -c "TOK=\$(...); echo \$TOK"`. Unescaped `$VAR`
  is expanded by the host shell before vagrant ever runs.
- Avoid nesting single quotes inside jsonpath/jq expressions inside the
  double-quoted command; prefer `-o jsonpath={.status.phase}` (no quotes)
  or move complex pipelines into a heredoc/script on the VM.
- Non-login shell: user-level PATH additions (e.g. `~/.local/bin`,
  where pip puts `ansible-lint`) are missing. Wrap with
  `bash -lc '...'` if a tool isn't found.
- Long multi-step debugging: `vagrant ssh` interactively or write a script
  to `/vagrant/` and execute it, instead of stacking escapes.
- Each `vagrant ssh -c` has ~1–2s connection overhead; batch related
  commands with `;` into one call.

## Code conventions

Match these exactly; do not introduce new idioms (see
[decisions/0006](doc/decisions/0006-defer-kubernetes-core.md) before
suggesting `kubernetes.core`):

- **OpenBao API calls**: `ansible.builtin.uri` with
  `X-Vault-Token` header; idempotency via GET-then-conditional-write
  (model: the KV-mount enable in `roles/openbao/tasks/configure.yml`).
- **Kubernetes objects**: render a Jinja2 template from the role's
  `templates/`, pipe to `k3s kubectl apply -f -` with
  `changed_when: "'created' in stdout or 'configured' in stdout"`.
- **Helm**: `helm upgrade --install` via `command`, values rendered to the
  role's work dir.
- **Sensitive tasks**: always
  `no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"`.
- **Check mode**: guard API/kubectl tasks with
  `when: not ansible_check_mode`.
- **Tags**: every role is tagged; new task files get wired into the role's
  `main.yml` with role tag + a specific tag.
- **Variable scoping**: role defaults are invisible to other roles. A value
  read by more than one role goes in
  `inventories/development/group_vars/all.yml`; when another role must read
  a foreign role's default anyway, use an explicit `| default(...)`.
- **Generated credentials**: read-from-OpenBao-before-generate, never
  regenerate on re-run.

## Validation

After any change (see [doc/operations.md](doc/operations.md) for details):

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
yamllint -c .yamllint .
```

The acceptance path for behavior changes is a fresh rebuild
(`vagrant destroy -f && vagrant up`, then full `site.yml` + a second run for
idempotency + `readiness_check.yml`). There is no migration/upgrade support
for existing deployments during development.

## Documentation rules

- Plain, factual language. No promotional tone.
- Work is tracked in `backlog.md` (gitignored, local).
- Significant decisions get a record in [doc/decisions/](doc/decisions/).
- Implementation plans for handoff follow the format of the documents in
  [doc/handoffs/](doc/handoffs/); once executed, they move there with an
  ARCHIVED banner.
- Upstream breakage from unpinned versions: fix forward to the new
  supported behavior; do not pin and do not use legacy escape hatches
  ([decisions/0005](doc/decisions/0005-track-latest-upstream.md)).
