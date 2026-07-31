# Operations

Runbook for deploying, validating, and operating the stack. Background on how
the pieces fit together is in [architecture.md](architecture.md).

Unless stated otherwise, commands run on a Fedora 44 workstation with the
repository cloned at `~/project-armory` or `/opt/project-armory` and the
environment sourced:

```bash
cd ~/project-armory
# or: cd /opt/project-armory
# cp .env.openshift.example .env   # first time only — see configuration.md
set -a; source .env; set +a
cd ansible
```

There is no `ansible.cfg`; nothing sets a default inventory, so every
`ansible-playbook` invocation below passes `-i inventories/openshift`
explicitly.

## Deploy

Two-tier run model — bootstrap once as cluster-admin, then every regular
deploy runs as the scoped `tex26-automation` account:

```bash
# One-time privileged setup: creates projects, the automation ServiceAccount,
# and the handful of grants that account cannot make for itself. Re-run only
# when the permission matrix in roles/automation_rbac changes.
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml

# Main deployment, as the scoped automation account.
ansible-playbook -i inventories/openshift playbooks/site.yml
```

A full `site.yml` run takes roughly 10–15 minutes on first deploy. Re-runs are
idempotent; generated credentials are reused, not regenerated. `site.yml`
opens with an RBAC preflight that checks the automation account holds every
permission the run needs, and fails up front (naming the exact verb/resource/
namespace) rather than partway through — see
[decisions](decisions/0007-scoped-provisioner-token.md) for why this account
is scoped instead of cluster-admin.

Targeted re-runs (every role is tagged):

```bash
ansible-playbook -i inventories/openshift playbooks/site.yml --tags openbao
ansible-playbook -i inventories/openshift playbooks/openbao_unseal.yml       # unseal-only recovery
ansible-playbook -i inventories/openshift playbooks/site.yml --tags cert_manager
ansible-playbook -i inventories/openshift playbooks/site.yml --tags keycloak_install
ansible-playbook -i inventories/openshift playbooks/site.yml --tags openbao_oidc
ansible-playbook -i inventories/openshift playbooks/site.yml --tags envoy_proxy
ansible-playbook -i inventories/openshift playbooks/site.yml --tags registry
ansible-playbook -i inventories/openshift playbooks/site.yml --tags readiness_check
```

## Readiness checks

```bash
ansible-playbook -i inventories/openshift playbooks/readiness_check.yml
```

Runs automatically at the end of `site.yml` and on demand. Checks per
component: deployment/pod health, TLS posture (HTTPS endpoints, plaintext
rejection, certificate trust, `skipTLSVerify` off), OpenBao seal status and
audit device, ingress reachability, OIDC endpoints, registry authentication
and storage, and OpenBao-backed ClusterIssuer readiness. Failures print a
per-check table; a `warn` is informational, a `fail` indicates the deployed
state diverges from the configured policy.

## Capture a run snapshot

Use the helper to capture a broad, compare-friendly state snapshot before or
after any deploy/readiness run (including failed runs):

```bash
bash ansible/scripts/capture_run_snapshot.sh
```

Output files are written under `~/project-armory/log/run-snapshots/`
with a unique timestamped filename (`run-snapshot-<UTC timestamp>.log`). If a
file with the same timestamp already exists, the script appends an index
suffix.

## Validation before commit

```bash
ansible-playbook -i inventories/openshift playbooks/site.yml --syntax-check
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --syntax-check
ansible-playbook -i inventories/openshift playbooks/site.yml --check
ansible-playbook -i inventories/openshift playbooks/bootstrap.yml --check
ansible-lint -c .ansible-lint playbooks/site.yml playbooks/bootstrap.yml roles
yamllint -c .yamllint .
```

Run the lint/yamllint commands from `ansible/`. Install lint tools if missing:
`python3 -m pip install --user ansible-lint yamllint`.

## Access Keycloak and OpenBao UI

No hosts-file entries and no CA trust setup needed on the workstation: the
OpenShift router serves both behind the cluster's Let's Encrypt wildcard
certificate for the apps domain, which is already publicly trusted.

URLs (replace the domain with your cluster's actual apps domain,
`ARMORY_PUBLIC_DOMAIN` — e.g. `apps.example.com`):

- Keycloak realm discovery:
  `https://keycloak.<apps-domain>/realms/armory/.well-known/openid-configuration`
- OpenBao UI: `https://openbao.<apps-domain>` with realm users:
  `admin` (broad UI policy), `operator` (secret value read/list),
  `viewer` (metadata/list only).

OpenBao UI login notes:

1. The OpenBao login page should show OIDC login (issuer backed by Keycloak
  realm `armory`).
2. Group-to-policy mapping is via OpenBao external identity groups and
  aliases: Keycloak groups `armory-admins`/`-operators`/`-viewers` map to
  OpenBao policies `armory-ui-admin`/`-operator`/`-viewer`.
3. Users outside those groups authenticate but only receive baseline policy
  scope (`default`).

## Retrieve generated credentials

Run from the workstation after sourcing `.env`. Source of truth is always
OpenBao; Ansible writes the required
Kubernetes Secrets directly after updating KV (no VSO sync controller).

| Purpose | OpenBao path | k8s Secret (ns `tex26-oidc`) |
|---|---|---|
| Keycloak master admin (console `/admin` only) | `secret/keycloak/bootstrap-admin` | `keycloak-bootstrap-admin` |
| Realm `armory` admin — OpenBao UI login | `secret/keycloak/realm-admin` | `keycloak-realm-admin` |
| Realm `armory` operator — OpenBao UI login | `secret/keycloak/realm-users/operator` | — |
| Realm `armory` viewer — OpenBao UI login | `secret/keycloak/realm-users/viewer` | — |
| Keycloak DB | `secret/keycloak/db` | `keycloak-db-secret` |

```bash
# Realm admin (OpenBao UI login)
oc get secret -n tex26-oidc keycloak-realm-admin -o jsonpath='{.data.password}' | base64 -d; echo

# Realm operator / viewer (OpenBao UI logins) via OpenBao KV — uses the scoped
# ansible-provisioner token (root is break-glass only). OpenBao state lives
# under ~/.armory/openbao on the controller (openbao_work_dir), owned by
# whichever user ran the playbook.
TOK=\$(sudo ansible-vault decrypt --vault-password-file ~/.armory/openbao/.vault-pass --output - ~/.armory/openbao/provisioner-token.yml | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)[\"provisioner_token\"])'); BAO=\$(oc get svc -n tex26-vault openbao -o jsonpath='{.spec.clusterIP}'); for U in operator viewer; do echo \"==> \$U\"; oc run baoq-\$RANDOM --rm -i --restart=Never --image=curlimages/curl -n tex26-vault --quiet -- -sk -H \"X-Vault-Token: \$TOK\" https://\$BAO:8200/v1/secret/data/keycloak/realm-users/\$U | python3 -c 'import sys,json;d=json.load(sys.stdin)[\"data\"][\"data\"];print(\"username:\",d[\"username\"]);print(\"password:\",d[\"password\"])'; done

# Master bootstrap admin
oc get secret -n tex26-oidc keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo

# DB credentials
oc get secret -n tex26-oidc keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## Password rotation

Automatic in-cluster rotation was removed along with the Vault Secrets
Operator (see [decisions/0010](decisions/0010-remove-vso-playbook-materialized-secrets.md)).
Current posture is manual rotation by rerunning Keycloak tasks: Ansible
updates OpenBao KV first, then applies Kubernetes Secrets from those values.

Seeded `operator`/`viewer` passwords are **not** rotated and are only set in
Keycloak at user creation. If the OpenBao entry under
`secret/keycloak/realm-users/<user>` is deleted or regenerated, Keycloak
keeps the old password and the two drift apart. Remediation: delete the user
in the Keycloak admin console (or reset its password there to the OpenBao
value), then rerun `ansible-playbook -i inventories/openshift
playbooks/site.yml --tags keycloak_install` to reconcile.

```bash
# Manual realm-admin rotation + Secret reconciliation
ansible-playbook -i inventories/openshift playbooks/site.yml --tags keycloak_install
```

## OpenBao audit log

A `file` audit device is enabled by default (declared in the OpenBao server
config; see [security.md](security.md#audit-logging) for what it captures).

- Log path in the pod: `/openbao/audit/audit.log`
- Storage: dedicated audit PVC, separate from data storage
- Rotation: in-cluster CronJob `openbao-audit-rotate` (daily, keeps 7);
  rotated files sit next to the live log as `audit.log.<timestamp>`

Entries are one JSON object per line, `request`/`response` pairs matched by
`request.id`. Secret values and tokens are HMAC-SHA256 hashed. Key fields:
`auth.display_name` (who), `auth.policies` (rights), `request.operation` +
`request.path` (what), `request.remote_address` (where from).

```bash
# Follow live
oc exec -n tex26-vault openbao-0 -- tail -f /openbao/audit/audit.log

# Pull a copy for offline analysis (jq: sudo dnf install -y jq)
oc cp tex26-vault/openbao-0:/openbao/audit/audit.log /tmp/audit.log

# Who is talking to OpenBao, and how much
jq -r 'select(.type=="request") | .auth.display_name' /tmp/audit.log | sort | uniq -c | sort -rn

# Every access to a given secret path
jq -r 'select(.request.path=="secret/data/keycloak/db") | [.time, .auth.display_name, .request.operation] | @tsv' /tmp/audit.log

# All writes (anything mutating)
jq -r 'select(.type=="request" and (.request.operation|IN("create","update","delete"))) | [.time, .auth.display_name, .request.path] | @tsv' /tmp/audit.log

# Denied requests
jq -r 'select(.auth.policy_results.allowed==false) | [.time, .auth.display_name, .request.path] | @tsv' /tmp/audit.log

# Force an immediate rotation run
oc create job -n tex26-vault audit-rotate-now-$RANDOM --from=cronjob/openbao-audit-rotate
```

Warning: OpenBao blocks all requests if no enabled audit device is writable.
Keep the audit PVC healthy.

Current limitation: Ansible's API calls appear under the `ansible-provisioner`
token's own identity in this log (day-to-day automation never uses the root
token — see [decisions/0007](decisions/0007-scoped-provisioner-token.md)),
but individual task-level attribution isn't possible beyond that.

## Break-glass: OpenBao root token

The root token is reserved for bootstrap and emergencies. Two copies exist:

1. Ansible-Vault-encrypted file on the controller, under
   `~/.armory/openbao` (the `openbao_work_dir` default; the OpenShift
   inventory moves this off `/opt/openbao` since the controller runs as an
   unprivileged user outside the cluster):
   `sudo ansible-vault view --vault-password-file ~/.armory/openbao/.vault-pass ~/.armory/openbao/init-keys.yml`
   (contains unseal keys and `root_token`).
2. OpenBao KV at `secret/openbao/init` (readable with the root token itself;
   useful for audited human retrieval once authenticated another way).

Unsealing happens automatically on every playbook run (`openbao` role,
`unseal.yml`); after any OpenBao pod restart, run `ansible-playbook -i
inventories/openshift playbooks/openbao_unseal.yml` to unseal only. Use
`ansible-playbook -i inventories/openshift playbooks/site.yml --tags openbao`
when you also want OpenBao install/configuration reconciliation.

## Resource usage

Use the cluster metrics API via `oc adm top` for quick node/pod pressure
checks.

```bash
oc adm top nodes
oc adm top pods -A --sort-by=memory
oc adm top pods -A --sort-by=cpu --containers
```

## Teardown and rebuild

Workload teardown (destructive; removes armory-owned namespaces and armory
cluster-scoped RBAC/issuers/secrets without mutating shared cert-manager):

```bash
ansible-playbook -i inventories/openshift playbooks/teardown_openshift.yml -e teardown_confirm=true
```

Full rebuild from scratch (clean checkout and fresh OpenShift target) — the
standard validation path for changes:

```bash
# then rerun bootstrap.yml and site.yml as above
```

## Troubleshooting

- **`env_guard` fails immediately**: `.env` not sourced. `set -a; source
  ~/project-armory/.env; set +a` or `set -a; source /opt/project-armory/.env;
  set +a` and verify
  `test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"`.
- **OpenBao tasks fail with connection errors**: pod restarted and is sealed.
  Run `ansible-playbook -i inventories/openshift playbooks/openbao_unseal.yml`.
- **Readiness shows TLS trust failures**: usually a CA Secret missing in a
  consumer namespace. Check copied `openbao-ca` Secrets in the affected
  namespaces and re-run the responsible role tag (`cert_manager`,
  `openbao_oidc`, or `envoy_proxy`).
- **Credential tasks show `no_log` redaction when debugging**: set
  `ARMORY_LOG_NOLOG=true` in `.env` temporarily. It prints secrets to the
  console and `log/ansible.log`; rotate anything exposed and set it back.
- **Helm upgrade rejected with StatefulSet immutable-field error**: a chart
  change touched `volumeClaimTemplates` or similar. The supported path is a
  fresh checkout and redeploy against a clean OpenShift target.
- **`site.yml`'s RBAC preflight fails**: it names the exact missing
  verb/resource/namespace. Re-run `playbooks/bootstrap.yml` as cluster-admin
  to (re)apply grants, or add the missing rule to
  `roles/automation_rbac/defaults/main.yml` if it's a genuinely new
  permission the matrix hasn't accounted for yet.
