# Vault Capabilities — Current Deployment

This document describes what the current single-node OpenBao deployment provides,
what is available to enable, and what it intentionally lacks.

---

## Active

| Capability | Detail |
|---|---|
| **Storage** | Raft integrated storage (single node). Data persisted to `deploy_dir/data` on the host. No external backend required. |
| **TLS** | ECDSA P-384 cert on the API listener. All traffic encrypted in transit. TLS 1.2 minimum. |
| **Token auth** | Always-on. Root token is the only credential until additional auth methods are mounted. |
| **Web UI** | `https://127.0.0.1:8200/ui` — accessible on localhost only. Log in with the root token. |
| **PKI** | Three-tier CA hierarchy deployed by `vault-config/`. See PKI Engine section below. |
| **AppRole** | Machine-to-machine auth mounted at `approle/`. Deployed by `vault-config/`. |

---

## Available to Enable (not yet mounted)

### Auth Methods
- **Userpass** — username/password for human operators
- **LDAP / GitHub / OIDC / JWT** — federated identity
- **Kubernetes** — pod-level auth for in-cluster workloads
- **TLS cert** — mutual TLS client auth

### Secret Engines
- **KV v2** — versioned key/value secrets
- **Transit** — encryption-as-a-service: encrypt/decrypt, sign/verify, HMAC without exposing keys
- **SSH** — signed SSH certificates or one-time passwords
- **Database** — dynamic, short-lived credentials for Postgres, MySQL, etc.
- **AWS / GCP / Azure** — dynamic cloud IAM credentials

---

## Not Present in This Deployment

| Gap | Notes |
|---|---|
| **Auto-unseal** | Requires a KMS (AWS KMS, GCP CKMS, Azure Key Vault) or a Transit engine on a separate Vault. Currently requires manual `bao operator unseal` after every restart. |
| **Shamir threshold > 1** | Initialized with `-key-shares=1 -key-threshold=1`. Single unseal key is a single point of failure — increase shares/threshold before any production use. |
| **Audit logging** | No audit device is mounted. Enable with `bao audit enable file file_path=/vault/logs/audit.log` once unsealed. |
| **ACL policies** | Only the root token exists. Define least-privilege policies before issuing any non-root tokens. |
| **High availability** | Single node. If the container dies, Vault is unavailable until restarted and manually unsealed. HA requires a multi-node Raft cluster. |

---

## PKI Engine

Project Armory uses a three-mount PKI hierarchy deployed by the `vault-config/`
OpenTofu module. Run `tofu apply` in `vault-config/` once after the Vault key
ceremony to bootstrap it.

### Hierarchy

```
pki/          Root CA  (Armory Root CA, 10-year validity)
              └─ signs intermediates only — no role defined, leaf issuance blocked
pki_int/      Internal Intermediate CA  (*.armory.internal, 5-year)
              └─ role: armory-server  (leaf certs, EC P-384, max 90 days)
pki_ext/      External Intermediate CA  (configurable domain, 5-year)
              └─ role: armory-external  (leaf certs, EC P-384, max 90 days)
```

The root CA has no role configured, which prevents leaf certificate issuance
via the `pki/issue/<role>` endpoint. Intermediate signing uses `pki/root/sign-intermediate`,
which is restricted by ACL policy when policies are defined.

### Issuing certificates

```bash
# Internal service cert
podman exec -e VAULT_TOKEN=$VAULT_TOKEN armory-vault \
  bao write pki_int/issue/armory-server \
  common_name=myservice.armory.internal

# External service cert
podman exec -e VAULT_TOKEN=$VAULT_TOKEN armory-vault \
  bao write pki_ext/issue/armory-external \
  common_name=myservice.example.com
```

### CA bundle — trusting issued certificates

After `vault-config/` apply, a CA bundle is written to `vault/ca-bundle.pem`
containing the root CA and both intermediates. Import it into your OS or browser
trust store so that all certificates issued by this Vault instance are trusted.

**Fedora / RHEL:**
```bash
sudo cp vault/ca-bundle.pem /etc/pki/ca-trust/source/anchors/armory-ca-bundle.pem
sudo update-ca-trust
```

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain vault/ca-bundle.pem
```

**Windows (PowerShell, run as Administrator):**
```powershell
Import-Certificate -FilePath vault\ca-bundle.pem `
  -CertStoreLocation Cert:\LocalMachine\Root
```

**Firefox** (manages its own trust store independently of the OS):
Preferences → Privacy & Security → Certificates → View Certificates →
Authorities → Import → select `ca-bundle.pem` → trust for websites.

---

## Roadmap (Project Armory)

1. Mount KV v2 for general secrets storage
2. ~~Mount PKI engine~~ ✓ Done — three-tier hierarchy via `vault-config/`
3. ~~Enable AppRole~~ ✓ Done — mounted at `approle/` via `vault-config/`
4. Enable audit logging to `/vault/logs/audit.log`
5. Define operator and service ACL policies; retire direct root token use
6. Evaluate auto-unseal options for the target environment
