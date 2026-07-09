# Handoff — Pod Resource Limits + Host Kernel Tuning

Status: ready for implementation (handoff to Copilot)
Scope: (1) a new `kernel_tuning` role that sets host-level sysctl/scheduler/THP
values on this VM, and (2) `resources:` requests/limits on every workload in
project-armory that currently runs `BestEffort` (no requests or limits set at
all).
Source: `~/Downloads/vm_load_investigation_report.md`. **Important
correction:** that report was written against a coworker's Mac-hosted VM, not
this Windows-hosted one. Its root-cause analysis of the Delve `tail-files.py`
busy-loop and its list of resource-less workloads were derived by reading
*this repo's* templates directly (independently confirmed, not assumed from
the report) and hold regardless of host. Its claim that kernel tuning was
"already applied and verified" does **not** apply here — nothing has been
applied to this VM. Task 1 must actually set these values, not just codify an
existing state.
Preconditions: `site.yml` deploys and `readiness_check.yml` passes on main.
Deployment model: **fresh rebuild only**, per this repo's standard practice —
validate on a clean `vagrant destroy -f && vagrant up` + full `site.yml`. No
migration path needed.
Backlog ref: none yet — add one line to `backlog.md` under "Pending" when this
lands, mirroring the audit-device entry's style.

## How to use this doc (Copilot)

Execute tasks in order; each names exact files and the change. Match existing
role conventions exactly (see AGENTS.md "Code conventions"): `kubernetes.core.k8s`
with explicit `kubeconfig`, Helm value dicts merged with `combine(...,
recursive=True)` where a role already builds one, `when: not ansible_check_mode`
on apply tasks, every role tagged. Do not invent new abstractions — one small
role for kernel tuning, small additive diffs everywhere else. Run validation
(§ Validation) after each task. Ask before deviating.

## Design decisions (do not relitigate)

- **Kernel tuning is a new role (`kernel_tuning`), not folded into
  `system_update`.** `system_update` is scoped to `dnf update` only (see its
  `defaults/main.yml`); tuning is a distinct concern with its own defaults and
  tags. It runs in `site.yml` immediately after `system_update` and before
  `helm`/`k3s`, since these are host-level settings k3s and its pods should
  inherit from boot.
- **I/O scheduler and THP are not sysctl** — they need a udev rule and a
  systemd oneshot unit respectively, not `ansible.posix.sysctl`. Keep them in
  the same role but as separate task files for clarity.
- **Resource values are starting points, not tuned to this host's headroom.**
  Use the report's §4.3 numbers for the Delve shippers (already spot-verified
  live behavior), and modest Burstable-tier values (small requests, generous
  but bounded limits) for everything else, matching the pattern already used
  for the Delve/Keycloak Postgres StatefulSets (`resources.requests` ~
  100m/256Mi, `resources.limits` ~ 1/512Mi) scaled down for lighter
  components. Revisit under real load after rebuild; do not treat these as
  final.
- **Do not touch `local-path-provisioner` in this pass.** It's a k3s built-in
  addon (not owned by any role) reachable only via a `HelmChartConfig` in
  `kube-system` — different mechanism, different blast radius (wrong
  `valuesContent` can break the addon k3s reconciles from
  `/var/lib/rancher/k3s/server/manifests`). Tracked as a follow-up backlog
  item (§ Out of scope), not part of this handoff.
- **agentstack-ui / agentstack-registry are out of scope for this doc.** They
  live in the separate `project-garrison` repo. See the companion ticket
  `project-garrison/tickets/open/003-agentstack-resource-limits.md`.

## Task 1 — `kernel_tuning` role (new)

Scaffold `ansible/roles/kernel_tuning/{defaults,tasks,meta}/main.yml` matching
the shape of `system_update` (no `handlers/` needed).

`defaults/main.yml`:

```yaml
---
kernel_tuning_swappiness: 10
kernel_tuning_dirty_bytes: 134217728        # 128 MiB
kernel_tuning_dirty_background_bytes: 67108864  # 64 MiB
kernel_tuning_inotify_max_user_watches: 524288
kernel_tuning_inotify_max_user_instances: 512
kernel_tuning_io_scheduler: mq-deadline
kernel_tuning_io_scheduler_device: sda
kernel_tuning_thp_enabled: never

armory_log_nolog: "{{ lookup('ansible.builtin.env', 'ARMORY_LOG_NOLOG') | default('false', true) | bool }}"
```

`tasks/main.yml`: three includes, each its own tagged file so a single tunable
category can be re-run in isolation.

```yaml
---
- name: Apply sysctl tuning
  ansible.builtin.import_tasks: sysctl.yml
  tags: [kernel_tuning, sysctl]

- name: Apply I/O scheduler tuning
  ansible.builtin.import_tasks: io_scheduler.yml
  tags: [kernel_tuning, io_scheduler]

- name: Apply transparent hugepage tuning
  ansible.builtin.import_tasks: thp.yml
  tags: [kernel_tuning, thp]
```

`tasks/sysctl.yml` — one `ansible.posix.sysctl` task per key (loop over a list
of `{name, value}` dicts built from the defaults above), `state: present`,
`reload: true`, `sysctl_file: /etc/sysctl.d/99-armory-tuning.conf` so it's a
scoped drop-in, not an edit to `/etc/sysctl.conf`. Requires
`ansible.posix` — check `ansible/requirements.yml`/`ansible/.ansible/collections`
first; add it to `requirements.yml` if absent.

`tasks/io_scheduler.yml` — template a udev rule (new file
`templates/60-armory-io-scheduler.rules.j2`):

```
ACTION=="add|change", KERNEL=="{{ kernel_tuning_io_scheduler_device }}", ATTR{queue/scheduler}="{{ kernel_tuning_io_scheduler }}"
```

Copy to `/etc/udev/rules.d/60-armory-io-scheduler.rules`, then
`ansible.builtin.command: udevadm trigger --name-match=/dev/{{
kernel_tuning_io_scheduler_device }}` (`changed_when: false`, since triggering
is not itself idempotency-trackable — the file copy is what registers
`changed`).

`tasks/thp.yml` — template a systemd oneshot unit (new file
`templates/armory-thp-tuning.service.j2`) that writes
`{{ kernel_tuning_thp_enabled }}` to
`/sys/kernel/mm/transparent_hugepage/enabled`, `WantedBy=multi-user.target`.
Install with `ansible.builtin.template` + `ansible.builtin.systemd_service`
(`daemon_reload: true`, `enabled: true`, `state: started` — starting it applies
the value immediately on this run, not just after next boot).

`meta/main.yml`: empty dependencies, matching `system_update`'s.

Wire into `playbooks/site.yml`, inserted right after `system_update` and
before `helm`:

```yaml
    - role: kernel_tuning
      tags:
        - kernel_tuning
```

## Task 2 — OpenBao (`openbao-0`)

`ansible/roles/openbao/defaults/main.yml`, add:

```yaml
openbao_resources_requests_cpu: 200m
openbao_resources_requests_memory: 256Mi
openbao_resources_limits_cpu: "1"
openbao_resources_limits_memory: 512Mi
```

`ansible/roles/openbao/templates/values.yaml.j2`, inside the top-level
`server:` block (alongside `service:`/`dataStorage:`), add:

```yaml
  resources:
    requests:
      cpu: {{ openbao_resources_requests_cpu }}
      memory: {{ openbao_resources_requests_memory }}
    limits:
      cpu: {{ openbao_resources_limits_cpu }}
      memory: {{ openbao_resources_limits_memory }}
```

## Task 3 — cert-manager (controller / webhook / cainjector)

`ansible/roles/cert_manager/defaults/main.yml`, extend
`certmanager_tofu_chart_values`:

```yaml
certmanager_tofu_chart_values:
  crds:
    enabled: true
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi
  webhook:
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
  cainjector:
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
```

(Upstream jetstack/cert-manager chart keys are top-level `resources` for the
controller, `webhook.resources`, `cainjector.resources` — confirm against the
pinned `certmanager_chart_version` if one has since been set; today it's
empty/latest.)

## Task 4 — Delve shippers (codify the interim mitigation)

Currently `delve_shipper_k8s_audit.yaml.j2` and
`delve_shipper_openbao_audit.yaml.j2` have no `resources:` key at all — this
is what let the busy-loop consume unbounded CPU. Adds what the report's §4.3
already validated live, so it survives a rebuild rather than needing to be
re-patched by hand.

`ansible/roles/delve/defaults/main.yml`, add:

```yaml
delve_shipper_resources_requests_cpu: 20m
delve_shipper_resources_requests_memory: 64Mi
delve_shipper_resources_limits_cpu: 150m
delve_shipper_resources_limits_memory: 256Mi
```

In `delve_shipper_k8s_audit.yaml.j2`, `delve_shipper_openbao_audit.yaml.j2`,
and `delve_shipper_keycloak_events.yaml.j2` (same gap, not flagged in the
report but same missing block), add under `containers[0]:` (sibling of
`volumeMounts:`):

```yaml
          resources:
            requests:
              cpu: {{ delve_shipper_resources_requests_cpu }}
              memory: {{ delve_shipper_resources_requests_memory }}
            limits:
              cpu: {{ delve_shipper_resources_limits_cpu }}
              memory: {{ delve_shipper_resources_limits_memory }}
```

Note: this does not replace the actual `tail-files.py` fix. If the ConfigMap
`subPath` mitigation (report §4.2) or a corrected pinned image has already
been folded into this role's `shippers.yml`/templates, leave that as-is — this
task only adds the missing `resources:` block.

## Task 5 — Headlamp

`ansible/roles/headlamp/defaults/main.yml`, add:

```yaml
headlamp_resources_requests_cpu: 50m
headlamp_resources_requests_memory: 64Mi
headlamp_resources_limits_cpu: 250m
headlamp_resources_limits_memory: 256Mi
```

`ansible/roles/headlamp/tasks/deploy.yml`, in the Python-dict `set_fact` that
builds `_headlamp_chart_values` (the block containing `'probes'`, `'service'`,
`'volumes'`), add a sibling top-level key:

```python
          'resources': {
            'requests': {
              'cpu': headlamp_resources_requests_cpu,
              'memory': headlamp_resources_requests_memory
            },
            'limits': {
              'cpu': headlamp_resources_limits_cpu,
              'memory': headlamp_resources_limits_memory
            }
          },
```

Verify the headlamp chart's top-level `resources` key maps to its single
Deployment container before trusting this (`helm show values` against
`headlamp_chart_name`/`headlamp_chart_repo` if unsure).

## Task 6 — otel-collector

`ansible/roles/envoy_gateway/defaults/main.yml`, add:

```yaml
otel_collector_resources_requests_cpu: 50m
otel_collector_resources_requests_memory: 64Mi
otel_collector_resources_limits_cpu: 200m
otel_collector_resources_limits_memory: 256Mi
```

`ansible/roles/envoy_gateway/templates/otel_collector.yaml.j2`: find the
container spec (currently no `resources:` key) and add the same shape as Task
4, reading from the `otel_collector_resources_*` vars.

## Validation

Lint after each task (inside the VM, from `${ARMORY_ANSIBLE_ROOT}` with `.env`
sourced):

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/
yamllint -c .yamllint .
```

Final validation is a from-scratch rebuild (host, repo root):

```bash
vagrant destroy -f && vagrant up
```

Then inside the VM:

```bash
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml --tags kernel_tuning   # idempotency: zero changed on rerun
ansible-playbook playbooks/readiness_check.yml
```

Manual spot-checks:

```bash
# Kernel tuning actually landed on THIS host (do not assume it did)
sysctl vm.swappiness vm.dirty_bytes vm.dirty_background_bytes \
  fs.inotify.max_user_watches fs.inotify.max_user_instances
cat /sys/block/sda/queue/scheduler
cat /sys/kernel/mm/transparent_hugepage/enabled

# QoS class flipped from BestEffort to Burstable for every touched workload
k3s kubectl get pod -n openbao openbao-0 -o jsonpath='{.status.qosClass}'
k3s kubectl get pod -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}'
k3s kubectl get pod -n delve -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}'
k3s kubectl get pod -n headlamp -o jsonpath='{.items[0].status.qosClass}'
k3s kubectl top nodes
```

Acceptance: `readiness_check.yml` passes clean; re-running `--tags
kernel_tuning` reports zero changed; every touched pod reports
`qosClass: Burstable`; `sysctl`/scheduler/THP reads match the configured
defaults on the actual VM (not assumed from any prior report).

## Out of scope

- `local-path-provisioner` resource limits (needs a `HelmChartConfig`,
  different mechanism — separate backlog item).
- `agentstack-ui` / `agentstack-registry` resource limits — see
  `project-garrison/tickets/open/003-agentstack-resource-limits.md`.
- The permanent `tail-files.py` upstream fix (report §4.1) and image pinning
  (report §4.4) — unrelated to resource limits/kernel tuning, tracked
  separately.
- Tuning the actual numeric values to this host's real headroom under agent
  workload — the values here are conservative starting points.
