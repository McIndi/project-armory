# Keycloak Event Auditing — Implementation Plan

## Status

**Implementation: complete (2026-06-23)**

All stages A–E implemented and syntax-checked clean. `ansible-lint` run; 6
`var-naming[no-role-prefix]` violations in `realm_events.yml` left as-is —
consistent with the pre-existing `_kc_*` convention used across the keycloak role
(`rotator.yml`, `realm_users.yml`, etc.).

**Pending: two-run playbook validation (maintainer)**

See the Verification section at the bottom of this file.

Derived from `keycloak-event-auditing-tier1-2-plan.md` (updated with live
environment findings 2026-06-23). Execute stages in order; D and E are
independent of each other but depend on A–C being landed first.

## Files touched

| Stage | File | Operation |
|---|---|---|
| A + E1 | `ansible/roles/keycloak/defaults/main.yml` | Append two defaults blocks |
| B | `ansible/roles/keycloak/templates/realmimport.yaml.j2` | Insert 8 lines after `sslRequired` |
| C1 | `ansible/roles/keycloak/tasks/realm_events.yml` | New file (~50 lines) |
| C2 | `ansible/roles/keycloak/tasks/main.yml` | Insert 3-line include after realm_users |
| D | `ansible/roles/keycloak/templates/keycloak.yaml.j2` | Insert `additionalOptions` block (~6 lines) |
| E2 | `ansible/roles/keycloak/templates/keycloak-admin-events-prune.sh.j2` | New file (~8 lines) |
| E3 | `ansible/roles/keycloak/tasks/admin_events_prune.yml` | New file (~40 lines) |
| E4 | `ansible/roles/keycloak/tasks/main.yml` | Insert 4-line import after rotator |

---

## Stage A — Defaults (`defaults/main.yml`)

Append after the realm-users block (~line 91). Two blocks in sequence:

```yaml
# ── Event auditing (Tier 1 store + Tier 2 log stream) ───────────────────────────
keycloak_events_enabled: true
keycloak_events_expiration_seconds: 7776000   # 90 days; user events only
keycloak_events_listeners:
  - jboss-logging
keycloak_admin_events_enabled: true
keycloak_admin_events_details_enabled: true
keycloak_events_jboss_logging_success_level: info
keycloak_events_jboss_logging_error_level: warn

# Admin events have no server-side expiration; a host systemd timer prunes the
# admin_event_entity table by age. Mirrors the OpenBao audit-rotate timer pattern.
keycloak_admin_events_prune_enabled: true
keycloak_admin_events_prune_on_calendar: weekly
keycloak_admin_events_prune_keep_days: 90
```

---

## Stage B — Realm-import seed (`templates/realmimport.yaml.j2`)

Insert after `sslRequired: external` (line 22), before `groups:` (line 23).
Belt-and-suspenders only — the REST task (Stage C) is authoritative:

```yaml
    eventsEnabled: {{ keycloak_events_enabled | bool | string | lower }}
    eventsExpiration: {{ keycloak_events_expiration_seconds | int }}
    eventsListeners:
{% for listener in keycloak_events_listeners %}
      - {{ listener }}
{% endfor %}
    adminEventsEnabled: {{ keycloak_admin_events_enabled | bool | string | lower }}
    adminEventsDetailsEnabled: {{ keycloak_admin_events_details_enabled | bool | string | lower }}
```

Do **not** add `enabledEventTypes` (omit = all types).

---

## Stage C1 — New task file (`tasks/realm_events.yml`)

Full content (modeled on `rotator.yml` scaffolding pattern):

```yaml
---
- name: Set Keycloak internal base URL fact for events config
  ansible.builtin.set_fact:
    _kc_events_base_url: "{{ keycloak_internal_api_url }}"

- name: Prepare internal HTTPS trust bundle for events config
  ansible.builtin.import_role:
    name: common
    tasks_from: prepare_internal_https_caller.yml
  vars:
    common_internal_https_kubeconfig_path: "{{ keycloak_kubeconfig_path }}"
    common_internal_https_service_name: "{{ keycloak_service_name }}"
    common_internal_https_service_namespace: "{{ keycloak_namespace }}"
    common_internal_https_fqdn: "{{ keycloak_internal_service_fqdn }}"
    common_internal_https_openbao_cluster_addr: "{{ keycloak_openbao_cluster_addr }}"
    common_internal_https_openbao_ca_secret_name: "{{ keycloak_openbao_ca_secret_name }}"
    common_internal_https_ca_source_namespace: "{{ keycloak_namespace }}"
    common_internal_https_bundle_path: /tmp/{{ keycloak_openbao_ca_secret_name }}-events-ca.crt
    common_internal_https_openbao_pki_mount: "{{ openbao_pki_internal_mount | default('pki-int') }}"

- name: Read bootstrap-admin credentials for events config
  ansible.builtin.command:
    cmd: >-
      k3s kubectl get secret {{ keycloak_bootstrap_admin_secret_name }}
      -n {{ keycloak_namespace }} -o jsonpath={.data.{{ item }}}
  environment:
    KUBECONFIG: "{{ keycloak_kubeconfig_path }}"
  loop: [username, password]
  register: _kc_events_admin_creds_b64
  changed_when: false
  no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"

- name: Obtain Keycloak master admin token for events config
  ansible.builtin.uri:
    url: "{{ _kc_events_base_url }}/realms/master/protocol/openid-connect/token"
    method: POST
    body_format: form-urlencoded
    body:
      client_id: admin-cli
      username: "{{ _kc_events_admin_creds_b64.results[0].stdout | b64decode }}"
      password: "{{ _kc_events_admin_creds_b64.results[1].stdout | b64decode }}"
      grant_type: password
    ca_path: /tmp/{{ keycloak_openbao_ca_secret_name }}-events-ca.crt
    validate_certs: true
    status_code: 200
  register: _kc_events_token
  retries: 30
  delay: 10
  until: _kc_events_token.status == 200
  changed_when: false
  no_log: "{{ not (armory_log_nolog | default(false) | bool) }}"

- name: Read current realm events config
  ansible.builtin.uri:
    url: "{{ _kc_events_base_url }}/admin/realms/{{ keycloak_realm }}/events/config"
    method: GET
    headers:
      Authorization: "Bearer {{ _kc_events_token.json.access_token }}"
    ca_path: /tmp/{{ keycloak_openbao_ca_secret_name }}-events-ca.crt
    validate_certs: true
    status_code: 200
  register: _kc_events_current
  retries: 30
  delay: 10
  until: _kc_events_current.status == 200
  changed_when: false

- name: Build desired events config (managed fields only)
  ansible.builtin.set_fact:
    _kc_events_desired:
      eventsEnabled: "{{ keycloak_events_enabled | bool }}"
      eventsExpiration: "{{ keycloak_events_expiration_seconds | int }}"
      eventsListeners: "{{ keycloak_events_listeners }}"
      adminEventsEnabled: "{{ keycloak_admin_events_enabled | bool }}"
      adminEventsDetailsEnabled: "{{ keycloak_admin_events_details_enabled | bool }}"

- name: Update realm events config when drifted
  ansible.builtin.uri:
    url: "{{ _kc_events_base_url }}/admin/realms/{{ keycloak_realm }}/events/config"
    method: PUT
    headers:
      Authorization: "Bearer {{ _kc_events_token.json.access_token }}"
      Content-Type: application/json
    body_format: json
    body: "{{ _kc_events_desired | combine({'enabledEventTypes': []}) }}"
    ca_path: /tmp/{{ keycloak_openbao_ca_secret_name }}-events-ca.crt
    validate_certs: true
    status_code: [204]
  register: _kc_events_update
  changed_when: true
  when: >-
    (_kc_events_current.json.eventsEnabled | default(false)) != (keycloak_events_enabled | bool)
    or (_kc_events_current.json.eventsExpiration | default(0) | int) != (keycloak_events_expiration_seconds | int)
    or (_kc_events_current.json.eventsListeners | default([]) | sort) != (keycloak_events_listeners | sort)
    or (_kc_events_current.json.adminEventsEnabled | default(false)) != (keycloak_admin_events_enabled | bool)
    or (_kc_events_current.json.adminEventsDetailsEnabled | default(false)) != (keycloak_admin_events_details_enabled | bool)

- name: Remove temporary Keycloak CA file for events config
  ansible.builtin.file:
    path: /tmp/{{ keycloak_openbao_ca_secret_name }}-events-ca.crt
    state: absent
  changed_when: false

- name: Remove temporary Keycloak internal FQDN hosts override for events config
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^.*\s+{{ keycloak_service_name }}\.{{ keycloak_namespace }}\.svc\.cluster\.local(\s|$)'
    state: absent
  become: true
```

---

## Stage C2 — Wire into `main.yml`

After the realm-users include (line 573), before the Ingress block (line 575):

```yaml
    - name: Reconcile Keycloak realm event auditing config via admin REST
      ansible.builtin.include_tasks: realm_events.yml
      when: not ansible_check_mode
```

---

## Stage D — Keycloak CR (`templates/keycloak.yaml.j2`)

Add `additionalOptions` block under `spec:`, after the `proxy:` block (line 37).
Option names verified against live KC 26.5.2 (`kc.sh --dry-run` exit 0):

```yaml
  additionalOptions:
    - name: spi-events-listener-jboss-logging-success-level
      value: {{ keycloak_events_jboss_logging_success_level }}
    - name: spi-events-listener-jboss-logging-error-level
      value: {{ keycloak_events_jboss_logging_error_level }}
```

Rolls `keycloak-0` once on first apply; stable on all subsequent runs.

---

## Stage E2 — Prune script (`templates/keycloak-admin-events-prune.sh.j2`)

New file. Modeled on `roles/openbao/templates/openbao-audit-rotate.sh.j2`.
Exec target: `statefulset/postgres` (confirmed: StatefulSet name matches
`keycloak_pg_service` default). `POSTGRES_*` env vars confirmed present.
Epoch formula `(EXTRACT(EPOCH FROM now()) - <literal>) * 1000` returns
`numeric` — no overflow (verified live). Age-only; no `WHERE realm_id`
clause (`realm_id` stores UUIDs, not names — confirmed live):

```bash
#!/usr/bin/env bash
# Managed by Ansible - do not edit manually
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl exec -n {{ keycloak_namespace }} statefulset/{{ keycloak_pg_service }} -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "DELETE FROM admin_event_entity WHERE admin_event_time < (EXTRACT(EPOCH FROM now()) - {{ keycloak_admin_events_prune_keep_days | int * 86400 }}) * 1000;"'
```

---

## Stage E3 — Prune task file (`tasks/admin_events_prune.yml`)

New file. Mirrors `roles/openbao/tasks/audit_rotate.yml` structure exactly:
template script → install .service unit → install .timer unit → enable and start.

```yaml
---
- name: Configure Keycloak admin-events prune timer
  when: keycloak_admin_events_prune_enabled | bool
  block:
    - name: Install Keycloak admin-events prune script
      ansible.builtin.template:
        src: keycloak-admin-events-prune.sh.j2
        dest: "{{ keycloak_work_dir }}/keycloak-admin-events-prune.sh"
        mode: "0750"
        owner: root
        group: root

    - name: Install Keycloak admin-events prune service unit
      ansible.builtin.copy:
        dest: /etc/systemd/system/keycloak-admin-events-prune.service
        mode: "0644"
        owner: root
        group: root
        content: |
          [Unit]
          Description=Prune Keycloak admin events
          Wants=network-online.target
          After=network-online.target

          [Service]
          Type=oneshot
          ExecStart={{ keycloak_work_dir }}/keycloak-admin-events-prune.sh

          [Install]
          WantedBy=multi-user.target

    - name: Install Keycloak admin-events prune timer unit
      ansible.builtin.copy:
        dest: /etc/systemd/system/keycloak-admin-events-prune.timer
        mode: "0644"
        owner: root
        group: root
        content: |
          [Unit]
          Description=Schedule Keycloak admin-events prune

          [Timer]
          OnCalendar={{ keycloak_admin_events_prune_on_calendar }}
          Persistent=true

          [Install]
          WantedBy=timers.target

    - name: Enable and start Keycloak admin-events prune timer
      ansible.builtin.systemd_service:
        name: keycloak-admin-events-prune.timer
        daemon_reload: true
        enabled: true
        state: started
```

---

## Stage E4 — Wire into `main.yml`

After the rotator include (line 590), still inside the main block:

```yaml
    - name: Provision Keycloak admin-events retention prune timer
      ansible.builtin.import_tasks: admin_events_prune.yml
      when:
        - not ansible_check_mode
        - keycloak_admin_events_prune_enabled | bool
```

---

## Verification

```bash
# Static checks (run after all stages complete)
ansible-playbook --syntax-check ansible/playbooks/site.yml
ansible-lint -c ansible/.ansible-lint ansible/roles/keycloak/
```

Runtime two-run check (maintainer):
1. **Run 1:** `keycloak-0` rolls at most once; `GET /admin/realms/armory/events/config`
   shows all 5 managed fields set; pod logs show INFO login events;
   `systemctl list-timers keycloak-admin-events-prune.timer` shows scheduled.
2. **Run 2:** drift task `changed=0`; `keycloak-0` UID unchanged; timer tasks `changed=0`.
