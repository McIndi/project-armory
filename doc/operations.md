# Operations

Runbook for deploying, validating, and operating the stack. Background on how
the pieces fit together is in [architecture.md](architecture.md).

Unless stated otherwise, commands run **inside the VM** (`vagrant ssh`) with
the environment sourced:

```bash
cd /vagrant
# cp .env.example .env   # first time only — see configuration.md
set -a; source .env; set +a
cd "${ARMORY_ANSIBLE_ROOT}"
```

## Deploy

```bash
ansible-playbook playbooks/site.yml
```

A full run takes roughly 10–15 minutes on first deploy. Re-runs are
idempotent; generated credentials are reused, not regenerated.

Targeted re-runs (every role is tagged):

```bash
ansible-playbook playbooks/site.yml --tags k3s
ansible-playbook playbooks/site.yml --tags openbao
ansible-playbook playbooks/site.yml --tags vso_install
ansible-playbook playbooks/site.yml --tags keycloak_install
ansible-playbook playbooks/site.yml --tags trust_manager
ansible-playbook playbooks/site.yml --tags headlamp_install
ansible-playbook playbooks/site.yml --tags headlamp_rbac
ansible-playbook playbooks/site.yml --tags k3s_oidc      # re-writes OIDC CA file and restarts k3s
```

## Readiness checks

```bash
ansible-playbook playbooks/readiness_check.yml
```

Runs automatically at the end of `site.yml` and on demand. Checks per
component: deployment/pod health, TLS posture (HTTPS endpoints, plaintext
rejection, certificate trust, `skipTLSVerify` off), VaultConnection CA
material, OpenBao seal status and audit device, ingress HTTP policy
conformance, and OIDC endpoints. Failures print a per-check table; a `warn`
is informational, a `fail` indicates the deployed state diverges from the
configured policy.

## Validation before commit

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint -c .ansible-lint playbooks/site.yml roles/   # config in ansible/.ansible-lint
yamllint -c .yamllint .                                    # run from ansible/
```

Install lint tools if missing: `python3 -m pip install --user ansible-lint yamllint`.

## Access Keycloak and Headlamp

On the workstation (not the VM):

1. Hosts-file entries pointing at the VM IP for `armory.local` and
   `headlamp.armory.local` (or whatever `ARMORY_PUBLIC_DOMAIN` /
   `ARMORY_HEADLAMP_HOST` are set to).
2. Trust the Armory Root CA in the workstation trust store.

URLs:

- Keycloak realm discovery: `https://armory.local/realms/armory/.well-known/openid-configuration`
- Headlamp: `https://headlamp.armory.local` with realm users:
  `admin` (cluster-admin), `operator` (edit), `viewer` (view).
- OpenBao UI: `https://openbao.armory.local` with realm users:
  `admin` (broad UI policy), `operator` (secret value read/list),
  `viewer` (metadata/list only).

OpenBao UI login notes:

1. The OpenBao login page should show OIDC login (issuer backed by Keycloak
  realm `armory`).
2. Group-to-policy mapping is via OpenBao external identity groups and aliases
  (`armory-admins`, `armory-operators`, `armory-viewers`).
3. Users outside those groups authenticate but only receive baseline policy
  scope (`default`).

## Retrieve generated credentials

Run from the workstation (`vagrant ssh -c ...`) or drop the wrapper inside
the VM. Source of truth is always OpenBao; VSO mirrors into k8s Secrets.

| Purpose | OpenBao path | k8s Secret (ns `keycloak`) |
|---|---|---|
| Keycloak master admin (console `/admin` only) | `secret/keycloak/bootstrap-admin` | `keycloak-bootstrap-admin` |
| Realm `armory` admin — Headlamp login | `secret/keycloak/realm-admin` | `keycloak-realm-admin` |
| Realm `armory` operator — Headlamp login | `secret/keycloak/realm-users/operator` | — |
| Realm `armory` viewer — Headlamp login | `secret/keycloak/realm-users/viewer` | — |
| Keycloak DB | `secret/keycloak/db` | `keycloak-db-secret` |

```bash
# Realm admin (Headlamp login)
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-realm-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# Realm operator / viewer (Headlamp logins) via OpenBao KV — uses the scoped
# ansible-provisioner token (root is break-glass only)
vagrant ssh -c "TOK=\$(sudo ansible-vault decrypt --vault-password-file /opt/openbao/.vault-pass --output - /opt/openbao/provisioner-token.yml | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)[\"provisioner_token\"])'); BAO=\$(sudo k3s kubectl get svc -n openbao openbao -o jsonpath='{.spec.clusterIP}'); for U in operator viewer; do echo \"==> \$U\"; sudo k3s kubectl run baoq-\$RANDOM --rm -i --restart=Never --image=curlimages/curl -n openbao --quiet -- -sk -H \"X-Vault-Token: \$TOK\" https://\$BAO:8200/v1/secret/data/keycloak/realm-users/\$U | python3 -c 'import sys,json;d=json.load(sys.stdin)[\"data\"][\"data\"];print(\"username:\",d[\"username\"]);print(\"password:\",d[\"password\"])'; done"

# Master bootstrap admin
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo"

# DB credentials
vagrant ssh -c "sudo k3s kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

Fallback — read OpenBao directly (e.g. before VSO has synced); also uses the
scoped provisioner token:

```bash
vagrant ssh -c "TOK=\$(sudo ansible-vault decrypt --vault-password-file /opt/openbao/.vault-pass --output - /opt/openbao/provisioner-token.yml | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)[\"provisioner_token\"])'); BAO=\$(sudo k3s kubectl get svc -n openbao openbao -o jsonpath='{.spec.clusterIP}'); sudo k3s kubectl run baoq-\$RANDOM --rm -i --restart=Never --image=curlimages/curl -n openbao --quiet -- -sk -H \"X-Vault-Token: \$TOK\" https://\$BAO:8200/v1/secret/data/keycloak/realm-admin | python3 -c 'import sys,json;d=json.load(sys.stdin)[\"data\"][\"data\"];print(\"username:\",d[\"username\"]);print(\"password:\",d[\"password\"])'"
```

## Password rotation

The realm `admin` password is rotated by the `keycloak-realm-admin-rotate`
CronJob (ns `keycloak`, ~monthly, schedule var
`keycloak_realm_admin_rotation_schedule`). It authenticates with a dedicated
service-account client (`realm-admin-rotator`, realm-management
`manage-users` — not the master admin), resets the user, and writes the new
value to OpenBao; VSO propagates it to the Secret within ~60s. Existing
sessions keep working; the next login needs the new password.

Seeded `operator`/`viewer` passwords are **not** rotated and are only set in
Keycloak at user creation. If the OpenBao entry under
`secret/keycloak/realm-users/<user>` is deleted or regenerated, Keycloak
keeps the old password and the two drift apart. Remediation: delete the user
in the Keycloak admin console (or reset its password there to the OpenBao
value), then rerun `ansible-playbook playbooks/site.yml --tags
keycloak_install` to reconcile.

```bash
# Rotate now
vagrant ssh -c "sudo k3s kubectl create job -n keycloak rotate-now-\$RANDOM --from=cronjob/keycloak-realm-admin-rotate"
```

Disable with `keycloak_realm_admin_rotation_enabled: false`.

## OpenBao audit log

A `file` audit device is enabled by default (declared in the OpenBao server
config; see [security.md](security.md#audit-logging) for what it captures).

- Log path in the pod: `/openbao/audit/audit.log`
- Storage: dedicated audit PVC, separate from data storage
- Rotation: host systemd timer `openbao-audit-rotate.timer` (daily, keeps 7);
  rotated files sit next to the live log as `audit.log.<timestamp>`

Entries are one JSON object per line, `request`/`response` pairs matched by
`request.id`. Secret values and tokens are HMAC-SHA256 hashed. Key fields:
`auth.display_name` (who), `auth.policies` (rights), `request.operation` +
`request.path` (what), `request.remote_address` (where from).

```bash
# Follow live
sudo k3s kubectl exec -n openbao openbao-0 -- tail -f /openbao/audit/audit.log

# Pull a copy for offline analysis (jq: sudo dnf install -y jq)
sudo k3s kubectl cp openbao/openbao-0:/openbao/audit/audit.log /tmp/audit.log

# Who is talking to OpenBao, and how much
jq -r 'select(.type=="request") | .auth.display_name' /tmp/audit.log | sort | uniq -c | sort -rn

# Every access to a given secret path
jq -r 'select(.request.path=="secret/data/keycloak/db") | [.time, .auth.display_name, .request.operation] | @tsv' /tmp/audit.log

# All writes (anything mutating)
jq -r 'select(.type=="request" and (.request.operation|IN("create","update","delete"))) | [.time, .auth.display_name, .request.path] | @tsv' /tmp/audit.log

# Denied requests
jq -r 'select(.auth.policy_results.allowed==false) | [.time, .auth.display_name, .request.path] | @tsv' /tmp/audit.log

# Force a rotation / check the timer
sudo systemctl start openbao-audit-rotate.service
systemctl list-timers openbao-audit-rotate.timer
```

Warning: OpenBao blocks all requests if no enabled audit device is writable.
Keep the audit PVC healthy.

## Break-glass: OpenBao root token

The root token is reserved for bootstrap and emergencies. Two copies exist:

1. Ansible-Vault-encrypted file on the VM:
   `sudo ansible-vault view --vault-password-file /opt/openbao/.vault-pass /opt/openbao/init-keys.yml`
   (contains unseal keys and `root_token`).
2. OpenBao KV at `secret/openbao/init` (readable with the root token itself;
   useful for audited human retrieval once authenticated another way).

Unsealing happens automatically on every playbook run (`openbao` role,
`unseal.yml`); after any OpenBao pod restart, run
`ansible-playbook playbooks/site.yml --tags openbao` to unseal and reconverge.

## Resource usage

metrics-server is bundled with k3s. No UI of its own; Headlamp renders its
data on cluster/node/pod views.

```bash
sudo k3s kubectl top nodes
sudo k3s kubectl top pods -A --sort-by=memory
sudo k3s kubectl top pods -A --sort-by=cpu --containers
```

## Teardown and rebuild

Workload teardown (destructive; removes Keycloak, VSO, ingress, and OpenBao
workload state from the cluster):

```bash
ansible-playbook playbooks/teardown_k3s_workloads.yml -e teardown_confirm=true
```

Full rebuild from scratch (workstation, repo root) — the standard validation
path for changes:

```bash
vagrant destroy -f && vagrant up
# then inside the VM: source .env and run site.yml as above
```

## Troubleshooting

- **`env_guard` fails immediately**: `.env` not sourced. `set -a; source
  /vagrant/.env; set +a` and verify
  `test "${ARMORY_ENV_SOURCED:-}" = "armory2-env-loaded-v1"`.
- **OpenBao tasks fail with connection errors**: pod restarted and is sealed.
  Re-run `--tags openbao`.
- **Readiness shows TLS trust failures**: usually a CA Secret missing in a
  consumer namespace. Check the trust-manager Bundle target Secrets
  (`openbao-ca-bundle`) and re-run `--tags trust_manager`.
- **Credential tasks show `no_log` redaction when debugging**: set
  `ARMORY_LOG_NOLOG=true` in `.env` temporarily. It prints secrets to the
  console and `log/ansible.log`; rotate anything exposed and set it back.
- **Helm upgrade rejected with StatefulSet immutable-field error**: a chart
  change touched `volumeClaimTemplates` or similar. The supported path is a
  fresh rebuild (`vagrant destroy -f && vagrant up`).
