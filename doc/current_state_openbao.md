# OpenBao State — Armory

> OpenBao is an open-source fork of HashiCorp Vault (Linux Foundation). It is the central secrets manager for the Armory stack.

---

## Deployment

| Setting | Value |
|---|---|
| Namespace | `openbao` |
| Helm release | `openbao` (chart: `openbao/openbao`) |
| Service type | `ClusterIP` |
| VM-local admin access | `https://openbao.openbao.svc.cluster.local:8200` (resolved locally to the Service ClusterIP via `/etc/hosts`) |
| In-cluster address | `https://openbao.openbao.svc.cluster.local:8200` |
| Storage backend | File (`/openbao/data` on PVC) |
| Seal type | Shamir (5 shares, threshold 3) |
| UI | Disabled |
| Agent injector | Disabled (VSO is used instead) |

---

## Bootstrap & Unseal

### First Run
1. Ansible calls `POST /v1/sys/init` with `secret_shares=5`, `secret_threshold=3`
2. Unseal keys + root token written to plaintext temp file
3. Temp file encrypted with `ansible-vault` using a random password stored at `/opt/openbao/.vault-pass` (mode `0400`, root-only)
4. Encrypted output saved to `/opt/openbao/init-keys.yml` (safe to commit to git)
5. OpenBao unsealed immediately using 3 of 5 keys
6. Init keys mirrored into KV at `secret/openbao/init` for audited human access

### Every Subsequent Run
1. Ansible checks seal status via `GET /v1/sys/seal-status`
2. If sealed: decrypts `/opt/openbao/init-keys.yml` using `/opt/openbao/.vault-pass`, submits 3 shards
3. If already unsealed: decrypts file only to load `root_token` for the configure/credentials tasks

### Human Key Inspection
```bash
# All keys
sudo python3 /vagrant/ansible/scripts/decrypt_vaulted_items.py \
  --vault-password-file /opt/openbao/.vault-pass \
  /opt/openbao/init-keys.yml

# Root token only
sudo python3 /vagrant/ansible/scripts/decrypt_vaulted_items.py \
  --vault-password-file /opt/openbao/.vault-pass \
  --key root_token \
  /opt/openbao/init-keys.yml
```

---

## Secrets Engines

### KV v2 — `secret/`

| Path | Contents | Access Policy |
|---|---|---|
| `secret/openbao/init` | `unseal_keys[]`, `root_token` | Root token only; explicitly denied to `vso` policy |
| `secret/beeai/credentials` | `admin_password`, `pg_admin_password`, `pg_user_password`, `seaweedfs_secret` | `vso` policy (read-only) |
| `secret/beeai/encryption-key` | `value` (base64 Fernet key) | `vso` policy (read-only) |

All paths under `secret/beeai/*` are writable by the root token at deploy time (Ansible `credentials.yml`). Values are generated once and never regenerated unless manually deleted.

### PKI — `pki/`

| Setting | Value |
|---|---|
| CA common name | `Armory Root CA` |
| CA TTL | 10 years (`87600h`) |
| Key type | RSA 4096 |
| Certificate role | `armory-dot-local` |
| Allowed domains | `armory.local` |
| Allow subdomains | yes |
| Allow bare domains | yes |
| Allow IP SANs | yes |
| Max cert TTL | 1 year (`8760h`) |
| Cert key type | RSA 2048 |
| Issuing URL | `https://openbao.openbao.svc.cluster.local:8200/v1/pki/ca` |
| CRL URL | `https://openbao.openbao.svc.cluster.local:8200/v1/pki/crl` |

---

## Auth Methods

### Kubernetes auth — `auth/kubernetes/`

| Setting | Value |
|---|---|
| Kubernetes host | `https://kubernetes.default.svc.cluster.local:443` |
| CA cert | k3s cluster CA (from `kube-root-ca.crt` ConfigMap) |
| Token reviewer JWT | Long-lived token for `openbao` ServiceAccount |
| ISS validation | Disabled (k3s does not set standard issuer) |

#### Auth Roles

| Role Name | Bound SA | Bound Namespace | Policy |
|---|---|---|---|
| `beeai-vso` | `beeai-vso` | `agentstack` | `vso` |
| `cert-manager` | `cert-manager` | `cert-manager` | `cert-manager` |

---

## Policies

### `vso`
```hcl
path "secret/data/beeai/*" {
  capabilities = ["read"]
}
path "secret/metadata/beeai/*" {
  capabilities = ["list", "read"]
}
path "secret/data/openbao/*" {
  capabilities = ["deny"]
}
```

### `cert-manager`
```hcl
path "pki/sign/armory-dot-local" {
  capabilities = ["create", "update"]
}
path "pki/issue/armory-dot-local" {
  capabilities = ["create", "update"]
}
```

---

## Current Integration Points

| Consumer | Auth Method | Policy | What It Gets |
|---|---|---|---|
| **VSO** (`beeai-vso` SA, `agentstack` ns) | Kubernetes auth / role `beeai-vso` | `vso` | Reads `secret/beeai/credentials` and `secret/beeai/encryption-key`; syncs them into k8s Secrets |
| **cert-manager** (`cert-manager` SA, `cert-manager` ns) | Kubernetes auth / role `cert-manager` | `cert-manager` | Signs certificates via `pki/sign/armory-dot-local`; used for `armory.local` TLS |
| **Ansible** (VM host) | Root token (from decrypted init-keys file) | Root | Configures engines, writes BeeAI credentials on first run, unseals on every run through the internal TLS service address |

---

## Potential Future Integration Points

### Dynamic Database Credentials
OpenBao's **Database secrets engine** can issue short-lived PostgreSQL credentials. Currently not implemented because BeeAI chart does not hot-reload credentials without a pod restart, and new dynamic credentials change the username on every lease. Documented as "level 2" upgrade.

**What it would take:**
- Enable `database/` secrets engine
- Configure a PostgreSQL connection at `database/config/agentstack-pg`
- Create a role that generates `CREATE ROLE ... LOGIN` statements
- VSO `VaultDynamicSecret` resource instead of `VaultStaticSecret`
- BeeAI chart must accept short-lived credentials or a sidecar must handle rotation

### Additional BeeAI Service Secrets
Any new service added to the agentstack chart that requires credentials can follow the same pattern:
1. Add secret to OpenBao KV at `secret/beeai/<service>`
2. The `vso` policy already grants read on all `secret/data/beeai/*` paths
3. Add a `VaultStaticSecret` resource in the beeai role

### Additional TLS Consumers
Any in-cluster service that needs a TLS certificate can use the existing `openbao-pki` ClusterIssuer. Just add a `Certificate` resource targeting the issuer — no OpenBao policy changes required because the `cert-manager` policy already covers the sign path.

### AppRole Auth (External Consumers)
If a service outside k3s (e.g., a script on the host, a CI pipeline) needs to read from OpenBao, the `approle/` auth method can be enabled and a scoped role/policy pair created. Currently not configured.

### Transit Secrets Engine (Encryption-as-a-Service)
OpenBao's **Transit** engine can provide encrypt/decrypt operations without storing the plaintext. Useful if BeeAI components need application-level encryption beyond the existing `encryptionKey` Fernet approach.

### Audit Logging
No audit device is currently configured. Adding a file audit device (`audit/file`) would log all authenticated access to `/openbao/audit/audit.log`. Recommended before treating this as a production-grade deployment.

---

## Files on the VM

| Path | Purpose | Permissions |
|---|---|---|
| `/opt/openbao/.vault-pass` | Ansible Vault password for the init-keys file | `0400` root |
| `/opt/openbao/init-keys.yml` | Ansible-Vault-encrypted unseal keys + root token | `0400` root |
| `/opt/openbao/values.yaml` | Helm values rendered by Ansible | `0644` |
| `/openbao/data/` | OpenBao storage backend (inside pod PVC) | PVC |
