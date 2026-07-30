# Plan: remaining deployment-blocker findings

Execution plan for the 5 findings from the OCP migration findings review that
were confirmed but not fixed inline. Each section is self-contained: goal,
exact files/tasks to change, and how to verify. Decisions already made (do not
re-litigate):

- **Finding 4**: assume OpenBao's container image ships a current public-root
  CA bundle. Don't fetch/verify the router's actual chain.
- **Finding 11**: fix the Host header. Replace the `127.0.0.1:443` fallback
  with a real, working mechanism — not just a different hardcoded address.
- **Finding 13b**: install Helm via the OS package manager (`dnf`), not a
  downloaded script.
- **Finding 14**: no code change. Preflight's sampling behavior and its `--as`
  fix (already applied) stay as-is; only the docstring/prose overclaim gets
  corrected.
- **Finding 15**: build the missing registry + ClusterIssuer readiness stage.
  This is new coverage, not a fix to existing code.

---

## 1. Finding 4 — OIDC discovery CA mismatch

**File:** `ansible/roles/openbao_oidc/tasks/oidc_config.yml`

**Problem:** `oidc_discovery_ca_pem` is populated with OpenBao's own `pki-ext`
CA (line ~346), but the discovery URL (`openbao_oidc_discovery_url`) is always
the public Keycloak Route, served by the router's Let's Encrypt wildcard — a
completely different, publicly-trusted chain. Decision: don't send a custom CA
at all; let OpenBao's HTTP client fall back to its container's system trust
store, which is assumed current.

**Change:**

1. Delete these two tasks entirely:
   - `Read OpenBao external issuer CA PEM for OIDC discovery trust` (~line 333)
   - `Set OpenBao OIDC discovery CA PEM fact` (~line 344)
2. In `Configure OpenBao OIDC auth backend` (~line 349), remove the
   `oidc_discovery_ca_pem` key from the request body entirely (don't send it
   empty — omit the field so OpenBao doesn't try to parse a blank PEM).
3. `openbao_oidc_ca_pem_url` in `roles/openbao_oidc/defaults/main.yml:58` is
   now unused — delete it. Grep first (`grep -rn openbao_oidc_ca_pem_url
   ansible/`) to confirm no other consumer before deleting.

**Verify:** `ansible-playbook -i inventories/openshift playbooks/site.yml
--syntax-check` and `--check` (templating only — this won't catch a real TLS
failure, which only a real run against the cluster can). On a real run,
confirm `POST auth/oidc/config` returns 200/204 and that OpenBao's OIDC login
role subsequently succeeds against the public Keycloak issuer.

---

## 2. Finding 11 — ingress fallback: wrong Host header, dead 127.0.0.1 fallback

**Files:** `ansible/roles/readiness_check/defaults/main.yml`,
`ansible/roles/readiness_check/tasks/check_keycloak.yml`

### 2a. A second bug found while scoping this: the PRIMARY check is also wrong

`readiness_check_keycloak_url` (defaults/main.yml) is built from
`readiness_check_public_base_url`, which defaults to
`"https://{{ readiness_check_public_domain }}"` — the **bare** apps domain
(`readiness_check_public_domain` is inventory-overridden to
`armory_apps_domain`, e.g. `apps.example.com`). The real
Keycloak Route hostname is `keycloak.<apps-domain>` (`armory_keycloak_host` in
`inventories/openshift/group_vars/all.yml:84`, and
`keycloak_public_base_url` at line 161 correctly uses it). Nothing ties
`readiness_check_public_base_url` to that. **This means the primary
(non-fallback) Keycloak well-known check hits the wrong hostname today, not
just the fallback.** Fix both together — they share one root cause.

### 2b. The fix

Replace the ad-hoc `Host:` header override and the `127.0.0.1:443` fallback
address with the same DNS-alias-to-loopback pattern already used everywhere
else in this codebase (`readiness_check_trace_probe_host` in
`check_trace_boundary_envoy.yml` is the reference implementation — mirror it
exactly). On OpenShift there is no local-node ingress to fall back to; the
only real corroborating path is through the actual in-cluster edge (Envoy),
reached via the port-forward tunnel this role already knows how to open.

**Step 1 — fix the hostname vars** (`roles/readiness_check/defaults/main.yml`):

```yaml
# Was: readiness_check_keycloak_host_header: "{{ readiness_check_public_domain }}"
readiness_check_keycloak_public_host: >-
  {{ armory_keycloak_host | default('keycloak.' + readiness_check_public_domain) }}
```

Update `readiness_check_keycloak_url` to use it instead of
`readiness_check_public_base_url`:

```yaml
readiness_check_keycloak_url: >-
  https://{{ readiness_check_keycloak_public_host }}/realms/{{ readiness_check_keycloak_realm }}/.well-known/openid-configuration
```

Delete `readiness_check_public_base_url` if nothing else consumes it (grep
`readiness_check_public_base_url` across `ansible/` first).

Delete `readiness_check_keycloak_host_header` (no longer used, see step 2)
and `readiness_check_ingress_probe_url`, `readiness_check_ingress_https_port`,
`readiness_check_edge_probe_ip`'s use in that URL (the edge probe vars
themselves stay — they're still used by `check_trace_boundary_envoy.yml`).

**Step 2 — rewrite the fallback task** in `check_keycloak.yml` (replaces the
current "Check Keycloak well-known endpoint via ingress fallback when DNS
fails" task and the `Host:` header hack):

```yaml
- name: Open a tunnel to the edge Envoy for the Keycloak ingress fallback
  ansible.builtin.command:
    cmd: >-
      {{ kubectl_bin }} port-forward
      --address 127.0.0.1
      --namespace {{ readiness_check_edge_namespace }}
      svc/{{ readiness_check_edge_service_name }}
      {{ readiness_check_edge_probe_port }}:{{ readiness_check_edge_port }}
  environment:
    KUBECONFIG: "{{ _readiness_check_kubeconfig_path }}"
  async: "{{ common_port_forward_ttl_seconds | default(7200) }}"
  poll: 0
  changed_when: true
  when:
    - "'name resolution' in ((_readiness_check_keycloak_https.msg | default('')) | lower)"
    - readiness_check_edge_probe_via_port_forward | bool

- name: Wait for the edge tunnel to accept connections
  ansible.builtin.wait_for:
    host: 127.0.0.1
    port: "{{ readiness_check_edge_probe_port | int }}"
    timeout: "{{ common_port_forward_ready_timeout_seconds | default(30) }}"
  when:
    - "'name resolution' in ((_readiness_check_keycloak_https.msg | default('')) | lower)"
    - readiness_check_edge_probe_via_port_forward | bool

- name: Alias the Keycloak public hostname to the edge tunnel
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^\S+\s+{{ readiness_check_keycloak_public_host | regex_escape }}\s*$'
    line: "{{ readiness_check_edge_probe_ip }} {{ readiness_check_keycloak_public_host }}"
    owner: root
    group: root
    mode: "0644"
  become: true
  when: "'name resolution' in ((_readiness_check_keycloak_https.msg | default('')) | lower)"

- name: Check Keycloak well-known endpoint via edge tunnel fallback when DNS fails
  ansible.builtin.uri:
    url: "https://{{ readiness_check_keycloak_public_host }}:{{ readiness_check_edge_probe_port }}/realms/{{ readiness_check_keycloak_realm }}/.well-known/openid-configuration"
    method: GET
    validate_certs: false
    follow_redirects: none
    timeout: "{{ readiness_check_keycloak_readiness_timeout }}"
    status_code: [200, 301, 302, 307]
  register: _readiness_check_keycloak_https_fallback
  changed_when: false
  failed_when: false
  when: "'name resolution' in ((_readiness_check_keycloak_https.msg | default('')) | lower)"
```

No explicit `Host:` header is needed — the `/etc/hosts` alias makes the real
public hostname itself resolve to loopback, so the request's Host/SNI is
correct without an override (same reasoning as
`check_trace_boundary_envoy.yml`'s probe). `validate_certs: false` stays: this
fallback path is specifically for a degraded/DNS-failure scenario and its
purpose is connectivity, not chain validation (the primary check above
already validates TLS properly). Leave the results-aggregation task (`Add
Keycloak HTTPS check to results`) untouched — it already reads
`_readiness_check_keycloak_https_fallback` generically.

**Verify:** `--syntax-check` passes. To actually exercise the fallback branch
in Vagrant, temporarily break DNS resolution for the Keycloak hostname (e.g.
point it at a bogus IP in `/etc/hosts` before the run) and confirm the
fallback path reaches Envoy and reports `pass`/`warn` correctly, then remove
the manual override.

---

## 3. Finding 13b — Helm role should install Helm via package manager

**File:** `ansible/roles/helm/tasks/main.yml`

**Change:** add an install step before the existing "Check Helm version"
task, gated so it only runs when Helm is actually missing (idempotent,
doesn't force a reinstall/upgrade on every run):

```yaml
- name: Check whether Helm is already installed
  ansible.builtin.command: helm version --short
  register: helm_preflight_check
  changed_when: false
  failed_when: false
  when: not ansible_check_mode

- name: Install Helm via dnf
  ansible.builtin.dnf:
    name: helm
    state: present
  become: true
  when:
    - not ansible_check_mode
    - (helm_preflight_check.rc | default(1)) != 0
```

Then the existing "Check Helm version" task (which currently has no
`failed_when: false` and hard-fails the play if Helm is absent) can keep its
default fail-on-error behavior — by the time it runs, Helm is either already
present or was just installed above.

**Before implementing:** confirm the target Fedora release actually carries a
`helm` package in its default enabled repos (`dnf list helm` on the VM,
or `dnf provides helm` if the name differs). If the package doesn't exist in
the default repos, this plan's "package manager" approach needs the specific
repo enablement added here too (e.g. Fedora's `updates`/`updates-testing`, or
a documented COPR) — don't guess the repo name without checking the live VM.

**Verify:** on a VM with Helm deliberately uninstalled
(`dnf remove -y helm` first, if safe to do in the dev VM), run
`ansible-playbook playbooks/site.yml --tags helm` and confirm Helm ends up
installed and the role's existing version-check/diff-plugin tasks pass
afterward.

---

## 4. Finding 14 — docs only, no code change

**Files:** `ansible/roles/automation_rbac/README.md` (if it describes the
preflight), `doc/handoffs/ocp-migration-handoff.md` §6, and the top-of-file
comment in `ansible/roles/automation_rbac/tasks/preflight.yml`.

**Change:** correct the "checks all 57 permissions" framing
(`doc/handoffs/ocp-migration-handoff.md` §6) and any equivalent claim
elsewhere to accurately describe what's actually verified: one
(namespace, resource, verb) combination is sampled **per rule object** in
`automation_rbac_namespace_rules` / `automation_rbac_cluster_rules` /
`automation_rbac_foreign_checks`, not per individual verb×resource
combination. Note why this is still meaningful: each rule's resources and
verbs are granted atomically by the same RBAC Role object once bound, and the
check is generated from the exact same source list used to generate the
grant (`roles/automation_rbac/tasks/main.yml:50`,
`rules: "{{ automation_rbac_namespace_rules }}"`), so a rule and its check
cannot drift apart — but this does not protect against out-of-band drift
(someone hand-editing the live Role in the cluster) or a
resourceNames-scoped grant that varies within a single rule.

No task-file changes. The `--as` impersonation fix already applied in
`preflight.yml` stands as-is.

---

## 5. Finding 15 — registry and ClusterIssuer readiness stage

**New files:**
`ansible/roles/readiness_check/tasks/check_registry.yml`,
`ansible/roles/readiness_check/tasks/check_cert_manager.yml`

**Wiring:** add both as new `include_tasks` entries in
`ansible/roles/readiness_check/tasks/main.yml`, each behind its own enable
toggle, following the exact pattern of the existing checks:

```yaml
- name: Check registry readiness
  ansible.builtin.include_tasks: check_registry.yml
  when:
    - readiness_check_registry_enabled | default(false) | bool
    - registry_enabled | default(false) | bool

- name: Check cert-manager ClusterIssuer readiness
  ansible.builtin.include_tasks: check_cert_manager.yml
  when: readiness_check_cert_manager_enabled | default(true) | bool
```

New defaults in `roles/readiness_check/defaults/main.yml`:

```yaml
readiness_check_registry_enabled: true
readiness_check_registry_namespace: "{{ registry_namespace | default('armory-registry') }}"
readiness_check_registry_deployment_name: "{{ registry_name | default('registry') }}"
readiness_check_registry_host: "{{ registry_host | default('registry.' + readiness_check_public_domain) }}"
readiness_check_registry_htpasswd_secret_name: "{{ registry_htpasswd_secret_name | default('registry-htpasswd') }}"
readiness_check_registry_pvc_name: "{{ readiness_check_registry_deployment_name }}-data"

readiness_check_cert_manager_enabled: true
readiness_check_cluster_issuer_names:
  - "{{ cert_manager_openbao_internal_clusterissuer_name | default('openbao-pki-internal') }}"
  - "{{ cert_manager_openbao_external_clusterissuer_name | default('openbao-pki-external') }}"
```

**`check_registry.yml` — checks to implement** (same
`_readiness_check_results` aggregation pattern as every other check file:
append `{component, check_name, status, detail, error}` dicts):

1. **Deployment/pod health** — `kubernetes.core.k8s_info` on the Deployment
   in `readiness_check_registry_namespace`; pass if
   `status.readyReplicas == status.replicas` and `> 0`.
2. **PVC bound** — `k8s_info` on PVC `{{ readiness_check_registry_pvc_name
   }}` (confirmed as a standalone PVC named `{{ registry_name }}-data` in
   `roles/registry/templates/deployment.yaml.j2:12-14`, not a
   `volumeClaimTemplates` entry); pass if `status.phase == 'Bound'`.
3. **Unauthenticated request rejected** — `GET https://{{
   readiness_check_registry_host }}/v2/` with no auth, `validate_certs: true`
   (router wildcard is publicly trusted per the same reasoning as finding 12),
   expect `401`. This proves auth is actually enforced, not just configured.
4. **Authenticated request succeeds** — read the registry credentials from
   OpenBao (reuse `common/tasks/load_openbao_provisioner_token.yml` plus a
   `GET {{ registry_openbao_kv_mount }}/data/{{ registry_openbao_path }}`
   read, mirroring how `roles/registry/tasks/main.yml` itself reads them),
   then `GET .../v2/` with HTTP Basic auth using that username/password,
   expect `200`.

**`check_cert_manager.yml` — checks to implement:**

1. Loop `readiness_check_cluster_issuer_names`; `k8s_info` on each
   `ClusterIssuer`; pass if its `status.conditions` contains an entry with
   `type: Ready` and `status: "True"`. Report the issuer name and current
   condition message in `detail` on failure so a broken issuer is diagnosable
   without a separate `oc describe`.

**Do not duplicate** the existing Envoy/trace-boundary coverage — Envoy's
public Route reachability is implicitly covered by the Keycloak/OpenBao
public-endpoint checks (finding 11's fix) going through the same edge; this
stage only needs to add what's genuinely uncovered (registry, ClusterIssuers).
OTel export verification is out of scope here (no real trace store exists
yet per `doc/architecture.md`'s OTel note — nothing to assert against).

**Verify:** `--syntax-check`, then on a real deployed cluster confirm all new
checks report `pass`, and deliberately break one (e.g. scale the registry
Deployment to 0, or delete a ClusterIssuer) to confirm the corresponding
check correctly reports `fail` and the readiness role's overall
`fail_on_issues` behavior still triggers.
