# Handoff — Enable OpenBao Audit Device

> **ARCHIVED — executed. Kept for history; do not follow as current
> instructions.** Durable rationale lives in [../decisions/](../decisions/).

Status: ready for implementation (handoff to Copilot)
Scope: enable a `file` audit device in OpenBao, backed by a dedicated PVC, with
host-driven log rotation and a readiness assertion. No other roles change.
Preconditions: `site.yml` deploys and `readiness_check.yml` passes on main.
Deployment model: **fresh rebuild only.** This is a demonstration environment;
validation is performed on a clean `vagrant destroy -f && vagrant up` followed
by a full `site.yml` run. No migration path for existing deployments is needed
or provided.
Backlog ref: `backlog.md` → "Enable an OpenBao audit device".

## How to use this doc (Copilot)
Execute tasks in order. Each task lists exact files and the change. Match
existing role conventions exactly: `ansible.builtin.uri` against
`{{ openbao_api_addr }}` with `X-Vault-Token`, `no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"`,
`when: not ansible_check_mode`, idempotency via a GET-then-conditional-write
pair (see the KV-mount enable in `roles/openbao/tasks/configure.yml:29-45` as
the model). Run validation (§6) after each phase. Do not invent new
abstractions. Ask before deviating.

## Design decisions (do not relitigate)

- **Device type:** `file` at `/openbao/audit/audit.log` on a dedicated PVC via
  the chart's `server.auditStorage` block — durable and separate from server
  stdout. Not `stdout` (mixes audit with server logs, retention tied to
  container log rotation).
- **Rotation:** OpenBao's file device does not self-rotate; it reopens its file
  on SIGHUP. Rotation runs from the VM host (consistent with this role already
  managing firewalld and `/etc/hosts`) as a systemd timer that execs into the
  pod, renames the log, signals PID 1, and prunes old files.
- **Blocking semantics:** if the audit device cannot be written, OpenBao blocks
  requests by design. The PVC is dedicated so server data and audit cannot
  starve each other; size it generously.

## Task 1 — Defaults

`ansible/roles/openbao/defaults/main.yml`, add (with the same comment style as
neighbors):

```yaml
# Audit device settings. When enabled, a `file` audit device is mounted on a
# dedicated PVC. WARNING: OpenBao blocks all requests if no enabled audit
# device is writable.
openbao_audit_enabled: true
openbao_audit_device_name: file
openbao_audit_mount_path: /openbao/audit
openbao_audit_log_path: "{{ openbao_audit_mount_path }}/audit.log"
openbao_audit_storage_size: 2Gi
# Host-side rotation (systemd timer; exec + SIGHUP into the pod).
openbao_audit_rotate_enabled: true
openbao_audit_rotate_on_calendar: daily
openbao_audit_rotate_keep: 7
```

## Task 2 — Chart values: audit PVC

`ansible/roles/openbao/templates/values.yaml.j2`, inside `server:`, add:

```yaml
{% if openbao_audit_enabled | bool %}
  auditStorage:
    enabled: true
    size: {{ openbao_audit_storage_size }}
    mountPath: {{ openbao_audit_mount_path }}
{% endif %}
```

Note: `auditStorage` adds a second volumeClaimTemplate to the StatefulSet,
which Kubernetes only accepts at creation time. Per the deployment model above
this lands on a fresh rebuild, so no handling is required — do not add any
upgrade/migration logic.

## Task 3 — Declare the device (server config, NOT the API)

> Revised 2026-06-11: OpenBao v2.4+ rejects `sys/audit` enable calls with
> HTTP 400 ("cannot enable audit device via API; use declarative,
> config-based audit device management instead"). API-driven audit creation
> is considered unsafe upstream. Do not use the legacy
> `unsafe_allow_api_audit_creation` escape hatch. See
> https://openbao.org/docs/configuration/audit/.

The device is declared in the server config rendered by
`ansible/roles/openbao/templates/values.yaml.j2`, inside the
`server.standalone.config` block after the `storage "file"` stanza:

```jinja
{% if openbao_audit_enabled | bool %}

      audit "file" "{{ openbao_audit_device_name }}" {
        options {
          file_path = "{{ openbao_audit_log_path }}"
          mode = "0600"
        }
      }
{% endif %}
```

The second label is the device *path*, so it lists as
`{{ openbao_audit_device_name }}/` in `GET /v1/sys/audit` — the readiness
check (Task 5) works unchanged. Devices are reconciled at startup and on
SIGHUP; idempotency is inherent. No tasks are added to `configure.yml`.

## Task 4 — Rotation timer (host)

New file `ansible/roles/openbao/templates/openbao-audit-rotate.sh.j2`:

```bash
#!/usr/bin/env bash
# Managed by Ansible — do not edit manually
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ts=$(date +%Y%m%d%H%M%S)
k3s kubectl exec -n {{ openbao_namespace }} statefulset/{{ openbao_release_name }} -- \
  sh -c "mv {{ openbao_audit_log_path }} {{ openbao_audit_log_path }}.${ts} && kill -HUP 1"
# Prune: keep newest {{ openbao_audit_rotate_keep }} rotated files.
k3s kubectl exec -n {{ openbao_namespace }} statefulset/{{ openbao_release_name }} -- \
  sh -c "ls -1t {{ openbao_audit_log_path }}.* 2>/dev/null | tail -n +{{ openbao_audit_rotate_keep | int + 1 }} | xargs -r rm --"
```

New file `ansible/roles/openbao/tasks/audit_rotate.yml`: install the script to
`{{ openbao_work_dir }}/openbao-audit-rotate.sh` (mode `0750`, root:root),
render systemd unit `openbao-audit-rotate.service` (Type=oneshot, ExecStart=
the script) and `openbao-audit-rotate.timer`
(`OnCalendar={{ openbao_audit_rotate_on_calendar }}`, `Persistent=true`) into
`/etc/systemd/system/`, then `ansible.builtin.systemd_service` with
`daemon_reload: true`, timer `enabled: true`, `state: started`. Gate the whole
file on `openbao_audit_enabled | bool and openbao_audit_rotate_enabled | bool`.

Wire it into `ansible/roles/openbao/tasks/main.yml` after `configure.yml`.

## Task 5 — Teardown + readiness + docs

- `ansible/roles/openbao/tasks/teardown.yml`: stop/disable the timer and remove
  the two unit files and the script (`failed_when: false`, matching existing
  teardown tone).
- `ansible/roles/readiness_check/tasks/check_openbao.yml`: append an
  authenticated check. Include `common/load_openbao_root_token.yml` (same
  pattern as the keycloak role), GET `/v1/sys/audit`, and add a result row
  `component: OpenBao, check_name: 'Audit device enabled'`, `pass` when
  `openbao_audit_device_name + '/'` is a key of the response JSON, else
  `fail`. Keep `failed_when: false` on the probe itself; gate pass/fail in the
  result row like every other check. Skip (status `warn`, detail "audit
  disabled by config") when `openbao_audit_enabled` is false.
- `README.md`: add an "Audit Logging" subsection under TLS/Sensitive Output:
  device location, PVC, rotation timer name, and the blocking-semantics
  warning.

## 6. Validation

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
ansible-playbook playbooks/site.yml --tags openbao   # idempotency: audit tasks report zero changed
ansible-playbook playbooks/readiness_check.yml
```

Manual spot-checks:

```bash
# Device registered
k3s kubectl exec -n openbao statefulset/openbao -- sh -c 'ls -l /openbao/audit/'
# Entries written (perform any KV read first)
k3s kubectl exec -n openbao statefulset/openbao -- sh -c 'tail -1 /openbao/audit/audit.log'
# Rotation works end-to-end
sudo systemctl start openbao-audit-rotate.service && sudo systemctl status openbao-audit-rotate.service
# Timer scheduled
systemctl list-timers openbao-audit-rotate.timer
```

Acceptance: readiness report shows `OpenBao / Audit device enabled: pass`;
re-running `--tags openbao` reports zero changed for the audit tasks; rotation
produces `audit.log.<ts>` and a fresh `audit.log` that continues receiving
entries (SIGHUP reopen verified).

## 7. Out of scope

Root-token scoping (separate backlog item), audit log shipping/aggregation,
`stdout` secondary device, non-file audit backends.
