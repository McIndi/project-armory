# OpenShift migration — session handoff

State as of the end of the design/build phase. **Nothing has been deployed.**

---

## 1. Hard rules

- **Never deploy, apply, or mutate the OpenShift cluster.** Cliff runs every
  deployment himself. Do not run `oc apply`, `oc create`, `helm install`, or
  `ansible-playbook` against the cluster — not even to "verify" something.
- Read-only investigation is fine, but **Cliff runs the commands and pastes the
  output**. Propose commands; don't execute them against the cluster.
- Validate locally instead: YAML parse, Jinja render, `--syntax-check`,
  `--list-tasks`, `ansible-lint`. Say plainly which claims are
  reasoned-but-unverified.

## 2. Where things are

| | |
|---|---|
| Repos | `C:\Users\cliff\focus\ocp-garrison\project-armory` and `…\project-garrison` |
| Branch | `ocp-deployment` in **both** (18 commits in armory) |
| Controller | the `ocp-garrison` Vagrant VM; repos mount at `/vagrant/...` |
| Armory | migration complete, unverified |
| Garrison | **not started** |

`project-armory` = security/identity foundation (OpenBao, Keycloak, cert-manager,
VSO, edge, registry). `project-garrison` = the agent platform built on top.

## 3. The cluster

OpenShift **4.20.25** (k8s 1.33) on **vSphere**, running IBM Cloud Pak for
Integration. Apps domain `apps.example.com`.

**It is dedicated to iSOA / Cliff — not multi-tenant.** Confirmed by the cluster
owner (Alan Shinn, TD SYNNEX); only three TD SYNNEX admins can access it. Earlier
work assumed a shared cluster and was deliberately conservative; that caution was
overstated, but most resulting designs still hold on *technical* grounds. Don't
re-litigate them without a reason.

Owner approved: our own proxy + Routes, our own registry, our own namespaces
(naming entirely our choice), additions to the shared cert-manager. Only standing
constraint: **keep the `*.apps` wildcard certificate working.** No storage quotas,
but keep usage in view.

What exists on the cluster:

| Thing | State | Consequence |
|---|---|---|
| cert-manager | installed, healthy, auto-upgrades, watches all namespaces | **Reuse it. Never install a second.** Vault-issuer controller is running; no NetworkPolicies block it |
| `*.apps` wildcard cert | cert-manager + Let's Encrypt + Cloudflare, auto-renews | Underpins registry trust — nodes trust our Routes for free |
| trust-manager | CRD present, **no controller running** | Not usable; armory uses its imperative CA-copy fallback |
| Vault Secrets Operator | **absent** | Armory installs it (in bootstrap) |
| `rhbk-operator` | installed but **SingleNamespace → `ibm-common-services`** | Cannot reconcile our CRs → Keycloak is deployed **operator-less** |
| `cs-keycloak` | CP4I's own Keycloak | Do not reuse or provision into it |
| Cluster login | **LDAP** identity provider | Not ours to change; Keycloak serves apps only |
| Default storage | `ocs-storagecluster-ceph-rbd` | All PVCs use it (`cephfs` available for RWX) |
| Internal image registry | `Removed` | We run our own (owner offered to enable theirs; we declined) |

## 4. Design approach

**Steer by inventory, never fork roles.** Nearly all OpenShift behaviour lives in
`ansible/inventories/openshift/group_vars/all.yml`. Role task files stay
identical to `main` so the branch keeps merging cleanly. Prefer adding a
`when:` guard or a variable over deleting or rewriting a task.

Selector variables:

| Variable | k3s | OpenShift |
|---|---|---|
| `target_platform` | `k3s` | `openshift` |
| `edge_kind` | `httproute` | `route_envoy` |
| `armory_scheduler_kind` | `host_timer` | `cronjob` |
| `internal_https_caller_mode` | `cluster_ip` | `port_forward` |
| `armory_privileged_tasks` | `true` | `false` |
| `keycloak_operator_install_method` | `manifests` | `none` |
| `kubectl_bin` | `k3s kubectl` | `oc` |

Roles gated **off** on OpenShift: `k3s`, `kernel_tuning`, `system_update`,
`host_dependencies`, `headlamp`, `envoy_gateway`, `delve`.

Namespaces: `tex26-oidc` (Keycloak), `tex26-vault` (OpenBao), `tex26-gateway`
(Envoy), `tex26-oci-registry`, `tex26-automation` (the SA), and
`tex26-agent-plat` reserved for garrison.
ClusterIssuers: `tex26-openbao-pki-internal` / `-external`.

## 5. Decisions worth knowing (and why)

- **The controller is off-cluster.** Armory assumed it ran *on* the k3s node and
  reached services by ClusterIP via `/etc/hosts`. On OpenShift that fails
  entirely. `common/tasks/prepare_internal_https_caller_dns.yml` now tunnels with
  `oc port-forward` and aliases the internal FQDN to loopback, so the URL, SNI
  and certificate SAN are all unchanged. Tunnels are fire-and-forget and reaped
  in `post_tasks`.

- **Edge = Route → in-namespace Envoy → workload.** The OpenShift router is
  HAProxy and cannot mint or strip W3C trace context, which armory's audit story
  depends on. Envoy runs as a plain Deployment (no Gateway API CRDs — OpenShift's
  Ingress Operator owns those). **The trace boundary uses
  `early_header_mutation_extensions`, NOT route-level header mutation** — the
  latter runs at the end of the filter chain, after Envoy has already joined the
  client's forged trace. It would look correct and be silently broken. The
  readiness trace-boundary check is what proves this.

- **Keycloak is operator-less.** Its Service keeps the operator's exact name
  (`keycloak-service`) so consumers' FQDNs, cert SANs and OpenBao policies are
  untouched. The realm body is lifted from the existing `realmimport` template
  and imported via `--import-realm`, staged as a **Secret** (it embeds the realm
  admin password in cleartext).

- **Postgres uses an OpenShift-native image** (`quay.io/sclorg/postgresql-16-c9s`)
  because the official image starts as root. Separate template
  (`postgres-openshift.yaml.j2`); different env var names, data dir, and config
  mechanism. The TLS init container is gone — the key mounts at `0640` instead.

- **OpenBao:** `nonroot-v2` SCC (least-privileged that fits; not `anyuid`),
  `disable_mlock` (avoids IPC_LOCK entirely), break-glass mirrored to a namespace
  Secret, and an **unseal watcher** Deployment that resubmits shards after every
  pod reschedule. Watcher holds no RBAC and mounts only the shards.

- **Registry** in `tex26-oci-registry`, edge Route, htpasswd auth, 20Gi.
  Node pulls trust it via the Let's Encrypt wildcard — no cluster-wide change.
  Deliberately **not** behind Envoy (image pulls are kubelet traffic).

- **Scheduled chores are CronJobs** (audit rotation, admin-events prune), each
  with an SA granted only `pods` + `pods/exec` in its own namespace.

- **The playbook runs as a scoped ServiceAccount**, not cluster-admin. See §6.

## 6. Two-tier run model

```bash
ansible-playbook playbooks/bootstrap.yml      # ONCE, as cluster-admin
source scripts/use-automation-sa.sh           # mints a 4h token
ansible-playbook playbooks/site.yml           # as tex26-automation
```

`bootstrap.yml` does only what a project-scoped account provably cannot do for
itself (Kubernetes forbids granting a permission the granter lacks): create the
projects, create the account and its grants, install VSO, and make three grants —
OpenBao's token-review binding, OpenBao's SCC binding, cert-manager's self-token
Role. It asserts it really is an admin session first.

`site.yml` does everything else as `tex26-automation`. Before any work starts,
a preflight samples one namespace/resource/verb combination from each rule in
the namespaced, cluster-scoped, and foreign-namespace permission lists. It fails
with the exact sampled permission when a check is denied. The checks expand the
same rule lists used to generate the Roles, so a declared rule and its check
cannot drift apart, and each Role grants a rule's resources and verbs
atomically. This sampling does not detect an out-of-band edit to one resource or
verb in the live Role, or variation within a `resourceNames`-scoped rule.
**Expect the first bootstrap to reveal one or two rules I missed** — the
preflight will name them; adding a rule to
`roles/automation_rbac/defaults/main.yml` is a one-line fix.

## 7. Unverified assumptions

Nothing has met the cluster. Ranked by likelihood of biting:

1. **Reencrypt Routes verifying backends.** The cert SAN is the internal FQDN
   while the router dials the pod IP. Affects every Route. Top suspect.
2. **Keycloak health probes on HTTPS:9000.** If the management port serves HTTP,
   the pod never goes Ready — CrashLoop with no obvious cause.
3. **sclorg Postgres** starting under `restricted-v2` and accepting the `0640`
   root-owned TLS key.
4. **`nonroot-v2`** sufficing for the OpenBao chart pod.
5. **Keycloak 26** accepting this `KC_*` env set in production mode;
   `--import-realm` picking up the Secret-mounted JSON.
6. **`%REQ(traceparent)%`** expanding inside an early header mutation. Fails
   *safe* if not (the strip still works); the readiness check reports it.
7. **`bitnami/kubectl` and `python:3.12-slim`** under `restricted-v2` with an
   assigned UID; CronJob `pods/exec` RBAC sufficing.
8. **Port-forward tunnel lifecycle** across a full run; `ansible_env.HOME`
   resolving in play 2 (traced, not run).
9. **`oc create token --duration=4h`** not exceeding the cluster's cap.
10. **OpenBao reaching the public Keycloak issuer from inside the pod.**
   `auth/oidc/config` triggers server-side discovery against
   `https://keycloak.<apps-domain>/realms/armory/.well-known/openid-configuration`
   from the OpenBao pod. That requires pod egress to the router's external VIP
   and hairpin back into the cluster; never verified. If that path fails,
   OIDC config fails at deploy time. The fallback is a hostAlias or equivalent
   mapping to the in-namespace Envoy Service ClusterIP, not the deleted
   Envoy-Gateway Service lookup chain.

## 8. Still open

- **Garrison** — entire OCP conversion. Not started. `tex26-agent-plat` reserved.
- **Delve** — deferred. Its audit shippers read node/host paths that don't exist
  on OpenShift; needs redesign against cluster logging. Gated off
  (`delve_enabled: false`).
- **Cluster logging stack** — never asked of the owner; needed before Delve.
- **Break-glass recovery runbook** — the mechanism works in code, but no operator
  doc exists for it.
- **Optional:** IP allowlists on the OpenBao and registry Routes
  (`*_route_annotations` hooks exist, unused).

## 9. Known lint state

Run the plain command directly — no wrapper script needed:
`ansible-lint -c .ansible-lint playbooks/site.yml playbooks/bootstrap.yml roles`.
A wrapper script and a local `ansible/ansible.cfg` existed briefly to work
around a suspected stall; both were unnecessary (the plain command runs the
full tree fine) and have been removed.

The real baseline captured 2026-07-28: 164 failures / 1 warning across 84 of
93 files, `production` profile required but `min` passed. All but one finding
has since been fixed: 142 `var-naming[no-role-prefix]`, all 13 `yaml`
(line-length + missing EOF newline), 5 `no-changed-when`, 2 `key-order[task]`,
1 `name[casing]`, `meta-no-tags`, and the `jinja[invalid]` bug are all done.
Re-run confirmed clean: `Passed: 0 failure(s), 0 warning(s) in 84 files
processed of 93 encountered. Profile 'production' was required, and it
passed.` No `--exclude` was used and `.ansible-lint`'s own excludes don't
touch first-party paths, so the 84-of-93 gap is very likely vendored content
ansible-lint walks past, not dropped first-party files — worth one quick
`-v` check that `check_keycloak.yml` itself was processed, not a re-run.
