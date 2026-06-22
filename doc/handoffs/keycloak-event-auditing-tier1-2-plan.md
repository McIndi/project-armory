# Keycloak Event Auditing — Tier 1 + 2 Implementation Plan

Handoff for staged implementation. Static validation only (`--syntax-check`,
`ansible-lint`); the maintainer owns playbook runs and the two-run idempotency check.

## Goal

Make the `armory` realm audit-capable with **no custom image**:

- **Tier 1 — native event store:** persist user + admin events (with request
  detail) to Postgres, queryable via Admin Console / REST, with retention.
- **Tier 2 — audit-grade log stream:** emit successful *and* failed login/admin
  events to the Keycloak pod's stdout at INFO, so a future log shipper has a
  tamper-evident copy outside the DB.

## Current state (baseline)

- `realmimport.yaml.j2` sets no events keys → realm boots `eventsEnabled: false`,
  `adminEventsEnabled: false`. Nothing persisted or queryable.
- Default `jboss-logging` listener is registered, but success events log at DEBUG
  (invisible at INFO) and admin events aren't dispatched at all.
- No retention, no off-box shipping.

## Design decisions (read before implementing)

1. **REST task is the source of truth, not the realm import.** `KeycloakRealmImport`
   is import-only — the operator applies it once at realm creation and never
   reconciles realm-level settings. So events config goes through an idempotent
   admin-REST task (`realm_events.yml`) that runs every build. The realm-import
   keys (Stage B) are a belt-and-suspenders seed for the fresh-build window before
   the REST task runs; harmless and self-documenting, but not authoritative.
2. **Drift check compares only stable fields.** Keycloak normalizes an empty
   `enabledEventTypes` (= "all types") into the full enumerated list on read. If
   we compared that field we'd PUT on every run forever. The reconcile manages and
   compares **only**: `eventsEnabled`, `eventsExpiration`, `eventsListeners`,
   `adminEventsEnabled`, `adminEventsDetailsEnabled`. We send `enabledEventTypes: []`
   in the PUT body (= all) but exclude it from the comparison. PUT only on drift.
3. **Tier 2 rolls keycloak-0 exactly once.** Adding `additionalOptions` to the
   Keycloak CR is a spec change → the operator rolls the StatefulSet on the run
   that first introduces it. Expected one-time roll, not per-run churn — the CR is
   identical on subsequent runs, so `keycloak-0` UID stays stable after that.
4. **`realm_events.yml` is modeled on `rotator.yml`** for its self-contained
   scaffolding (CA bundle prep → read bootstrap creds → mint master admin token →
   REST → cleanup). Use `_kc_events_*` fact names and CA path
   `/tmp/{{ keycloak_openbao_ca_secret_name }}-events-ca.crt`. Do **not** reuse
   `obtain_realm_admin_token.yml` (it is hardwired to `_kc_realm_users_*` facts).

---

## Stage A — Defaults

File: `ansible/roles/keycloak/defaults/main.yml`. Add an events block (place after
the realm-users block, ~line 91):

```yaml
# ── Event auditing (Tier 1 store + Tier 2 log stream) ───────────────────────────
keycloak_events_enabled: true
# User-event retention (seconds). 90 days. Admin events do NOT honor this (see
# Stage E) — Keycloak has no built-in admin-event expiration.
keycloak_events_expiration_seconds: 7776000
keycloak_events_listeners:
  - jboss-logging
keycloak_admin_events_enabled: true
keycloak_admin_events_details_enabled: true   # stores the admin request payload
# Tier 2: surface successful events on stdout (errors already log at warn).
keycloak_events_jboss_logging_success_level: info
keycloak_events_jboss_logging_error_level: warn
```

`ansible-lint` / `yamllint` clean.

---

## Stage B — Realm-import seed (Tier 1, fresh-build window)

File: `ansible/roles/keycloak/templates/realmimport.yaml.j2`. Add to the `realm:`
block (e.g. after `sslRequired: external`, line 22):

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

Do **not** add `enabledEventTypes` (omit = all types). No other changes.

---

## Stage C — Idempotent REST enforcement (Tier 1, authoritative)

### C1. New task file `ansible/roles/keycloak/tasks/realm_events.yml`

Model the scaffolding on `rotator.yml` lines 10–64 (setup) and 217–228 (cleanup).
Concretely:

```yaml
---
# Reconcile realm-level events/audit configuration via the Keycloak admin REST
# API. Idempotent: PUTs only when the managed fields drift. Source of truth for
# event auditing (the realm import is import-only and never reconciles this).

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

Notes:
- `enabledEventTypes: []` is sent in the PUT (= all types) but deliberately
  excluded from the `when:` drift comparison (Design decision #2).
- `eventsListeners` compared with `| sort` on both sides so ordering never
  registers as drift.
- Reuses the same `prepare_internal_https_caller.yml` / `/etc/hosts` override and
  cleanup as `realm_users.yml` / `rotator.yml`.

### C2. Wire into `main.yml`

In `ansible/roles/keycloak/tasks/main.yml`, after the realm-users reconcile
(after line 573, before the Ingress block at line 575):

```yaml
    - name: Reconcile Keycloak realm event auditing config via admin REST
      ansible.builtin.include_tasks: realm_events.yml
      when: not ansible_check_mode
```

Placement is after the "Wait for Keycloak StatefulSet rollout before realm
reconciliation" gate (line 555), so the admin REST endpoint is settled.

---

## Stage D — Tier 2 log stream (Keycloak CR)

File: `ansible/roles/keycloak/templates/keycloak.yaml.j2`. Add an
`additionalOptions` block under `spec:` (e.g. after `proxy:`, line 37):

```yaml
  additionalOptions:
    - name: spi-events-listener-jboss-logging-success-level
      value: {{ keycloak_events_jboss_logging_success_level }}
    - name: spi-events-listener-jboss-logging-error-level
      value: {{ keycloak_events_jboss_logging_error_level }}
```

This first-time spec change rolls `keycloak-0` once (Design decision #3).

---

## Stage E — Admin-event retention prune (optional, recommended)

`eventsExpiration` prunes user events only (Keycloak's own background job);
**admin events have no native expiration** and grow unbounded, more so with
`adminEventsDetailsEnabled` storing full request payloads. So this stage targets
the `admin_event_entity` table only — leave `event_entity` (user events) to the
server's `eventsExpiration`.

**Reuse the existing OpenBao audit-log rotation pattern** — a host-level systemd
oneshot service + timer that runs a templated script which `kubectl exec`s into the
pod and prunes. Mirror these files exactly:

- `ansible/roles/openbao/tasks/audit_rotate.yml`            → task structure
- `ansible/roles/openbao/templates/openbao-audit-rotate.sh.j2` → script structure
- `ansible/roles/openbao/defaults/main.yml` (audit-rotate block, ~L233) → defaults

Two deliberate divergences from the OpenBao original:
1. **Time-based, not count-based retention.** OpenBao keeps "newest N rotated
   files"; admin events are DB rows, so retention is by age (`keep_days`), deleting
   rows older than the cutoff.
2. **`psql` into Postgres, not the app pod.** The prune is a SQL `DELETE`, run by
   exec-ing into the `postgres` StatefulSet. The pod already exposes
   `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` as container env, so no
   token, CA bundle, or admin-REST scaffolding is needed (the default Postgres
   image trusts the local socket; passing `PGPASSWORD` is belt-and-suspenders).

Single-tenant simplification: prune by age across **all** realms (master + armory)
rather than scoping by `realm_id` — `admin_event_entity.realm_id` stores the realm
name in newer schemas but is version-fragile; age-only avoids that and is correct
for this platform. Scope by `realm_id = '{{ keycloak_realm }}'` later only if a
second tenant realm is ever added.

### E1. Defaults

Add to `ansible/roles/keycloak/defaults/main.yml` (alongside the Stage A events
block):

```yaml
# Admin events have no server-side expiration; a host systemd timer prunes the
# admin_event_entity table by age. Mirrors the OpenBao audit-rotate timer pattern.
keycloak_admin_events_prune_enabled: true
keycloak_admin_events_prune_on_calendar: weekly     # systemd OnCalendar
keycloak_admin_events_prune_keep_days: 90           # match keycloak_events_expiration_seconds
```

### E2. Prune script `ansible/roles/keycloak/templates/keycloak-admin-events-prune.sh.j2`

Model on `openbao-audit-rotate.sh.j2`:

```bash
#!/usr/bin/env bash
# Managed by Ansible - do not edit manually
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# Delete admin events older than the retention window. admin_event_time is epoch ms.
k3s kubectl exec -n {{ keycloak_namespace }} statefulset/{{ keycloak_pg_service }} -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "DELETE FROM admin_event_entity WHERE admin_event_time < (EXTRACT(EPOCH FROM now()) - {{ keycloak_admin_events_prune_keep_days | int * 86400 }}) * 1000;"'
```

Quoting note: the `{{ ... }}` renders to a literal integer at template time (host).
The `sh -c '...'` arg is single-quoted so it reaches the pod shell verbatim; the
`$POSTGRES_*` vars then expand inside the Postgres container, not on the host.

### E3. Task file `ansible/roles/keycloak/tasks/admin_events_prune.yml`

Copy `openbao/tasks/audit_rotate.yml` and rename: script →
`{{ keycloak_work_dir }}/keycloak-admin-events-prune.sh`, units →
`keycloak-admin-events-prune.{service,timer}`, `OnCalendar={{ keycloak_admin_events_prune_on_calendar }}`,
and gate the block on `keycloak_admin_events_prune_enabled`. Service description
"Prune Keycloak admin events"; timer "Schedule Keycloak admin-events prune".

### E4. Wire into `main.yml`

After the rotator include (after line 590), still inside the main block:

```yaml
    - name: Provision Keycloak admin-events retention prune timer
      ansible.builtin.import_tasks: admin_events_prune.yml
      when:
        - not ansible_check_mode
        - keycloak_admin_events_prune_enabled | bool
```

**Independent and additive** — defer freely if you want Tier 1+2 landed first. It
touches no Keycloak CR/realm state, so it cannot affect `keycloak-0` stability.

---

## Validation (maintainer)

Static (agent/Copilot):
- `ansible-playbook --syntax-check playbooks/site.yml`
- `ansible-lint -c .ansible-lint roles/keycloak/`
- `yamllint -c .yamllint roles/keycloak/`

Runtime (two-run, maintainer):
1. **Run 1 (fresh):** confirm `keycloak-0` rolls at most once for the CR change;
   `GET /admin/realms/armory/events/config` shows all five managed fields set;
   Admin Console → Realm → Events shows login + admin events accruing; pod logs
   show INFO-level `type=LOGIN` / admin-event lines.
2. **Run 2 (no-op):** `realm_events.yml` "Update realm events config when drifted"
   reports **ok/skipped (changed=0)**; `keycloak-0` UID unchanged from run 1.
3. **Stage E (if landed):** `systemctl list-timers keycloak-admin-events-prune.timer`
   shows it scheduled; `systemctl start keycloak-admin-events-prune.service` runs
   clean; re-running the playbook is `changed=0` for the timer tasks.

## Gotchas checklist

- [ ] `enabledEventTypes` excluded from drift `when:` (normalization → false drift).
- [ ] `eventsListeners` compared with `| sort` on both operands.
- [ ] PUT expects **204**, GET expects **200**.
- [ ] `realm_events.yml` cleans up both the `/tmp/*-events-ca.crt` bundle and the
      `/etc/hosts` override (the hosts removal needs `become: true`).
- [ ] Token mint uses `retries/until` (cold-JVM / post-rollout settling).
- [ ] CR `additionalOptions` change = one expected `keycloak-0` roll on first apply.
- [ ] Admin events have no native expiration (Stage E or accept unbounded growth).
- [ ] Stage E prune targets `admin_event_entity` **only** (user events handled by
      `eventsExpiration`); retention is age-based (`keep_days`), not count-based.
- [ ] Stage E `sh -c '...'` is single-quoted so `$POSTGRES_*` expands in the pod,
      not on the host; the `keep_days*86400` Jinja renders to a literal at template
      time.
```

