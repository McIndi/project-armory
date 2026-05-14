# Kubernetes State — Armory

> VM: `armory-fedora44` · IP: `192.168.0.150` · Distribution: k3s (latest stable) on Fedora 44

---

## Cluster Configuration

| Setting | Value |
|---|---|
| Distribution | k3s (single-node) |
| Config file | `/etc/rancher/k3s/config.yaml` |
| Disabled components | `traefik` |
| Secrets encryption at rest | `true` (etcd-level encryption) |
| Kubeconfig | `/etc/rancher/k3s/k3s.yaml` |
| API server | `https://127.0.0.1:6443` |

---

## Namespaces

| Namespace | Purpose |
|---|---|
| `kube-system` | k3s core system components |
| `kube-public` | Cluster CA configmap |
| `openbao` | OpenBao secrets manager |
| `cert-manager` | cert-manager certificate controller |
| `ingress-nginx` | nginx Ingress controller |
| `vault-secrets-operator-system` | Vault Secrets Operator (VSO) |
| `agentstack` | BeeAI Agent Stack (all app workloads) |

---

## Deployed Workloads

### `openbao` namespace

| Resource | Kind | Notes |
|---|---|---|
| `openbao` | Deployment | OpenBao server (standalone, file storage at `/openbao/data`) |
| `openbao` | Service | NodePort `32200` → port `8200`; also used in-cluster at `openbao.openbao.svc.cluster.local:8200` |
| `openbao` | ServiceAccount | Bound to `system:auth-delegator` ClusterRole for token review |
| `openbao` (PVC) | PersistentVolumeClaim | 1 Gi, stores all KV and PKI data |

**Helm release:** `openbao` from `https://openbao.github.io/openbao-helm`  
**Values file:** `/opt/openbao/values.yaml` (rendered by Ansible)

---

### `cert-manager` namespace

| Resource | Kind | Notes |
|---|---|---|
| `cert-manager` | Deployment | Core controller |
| `cert-manager-webhook` | Deployment | Admission webhook for Certificate validation |
| `cert-manager-cainjector` | Deployment | CA bundle injection |
| `openbao-pki` | ClusterIssuer | cert-manager Vault-type issuer → OpenBao PKI `pki/sign/armory-dot-local` |
| `armory-tls` | Certificate | Issued to `armory.local` + SAN IP `192.168.0.150`; stored as Secret `armory-tls` in `ingress-nginx` |

**Helm release:** `cert-manager` from `https://charts.jetstack.io`  
**CRDs installed:** yes (`crds.enabled=true`)

---

### `ingress-nginx` namespace

| Resource | Kind | Notes |
|---|---|---|
| `ingress-nginx-controller` | Deployment | nginx Ingress controller |
| `ingress-nginx-controller` | Service | NodePort `30080` (HTTP) / `30443` (HTTPS); `externalIPs: [192.168.0.150]` |
| `armory-tls` | Secret | TLS cert + key synced from cert-manager Certificate resource |

**Helm release:** `ingress-nginx` from `https://kubernetes.github.io/ingress-nginx`

---

### `vault-secrets-operator-system` namespace

| Resource | Kind | Notes |
|---|---|---|
| `vault-secrets-operator` | Deployment | VSO controller; watches VaultStaticSecret/VaultDynamicSecret CRDs cluster-wide |
| `vault-secrets-operator` | Service | Internal only |

**Helm release:** `vault-secrets-operator` from `https://helm.releases.hashicorp.com`  
**Default VaultConnection:** pre-configured at install time to `http://openbao.openbao.svc.cluster.local:8200`

---

### `agentstack` namespace

#### Application Deployments

| Workload | Kind | Service Type | Port | Ingress Path |
|---|---|---|---|---|
| `agentstack` (API) | Deployment | ClusterIP | `8080` | `https://armory.local/api/*` |
| `agentstack-ui` | Deployment | ClusterIP | `3000` | `https://armory.local/` |
| `agentstack-keycloak` | Deployment | ClusterIP | `8080` | `https://armory.local/realms/*` |
| `postgresql` (primary) | StatefulSet | ClusterIP | `5432` | — (internal only) |
| `seaweedfs` | Deployment/StatefulSet | ClusterIP | varies | — (internal only) |

#### Ingress Resources

| Name | Host | TLS Secret | Backend |
|---|---|---|---|
| `agentstack-ui` | `armory.local` | `armory-tls` | `agentstack-ui:3000` (path `/`) |
| `agentstack-api` | `armory.local` | `armory-tls` | `agentstack:8080` (path `/api/*`, rewrite) |
| `agentstack-keycloak` | `armory.local` | `armory-tls` | `agentstack-keycloak:8080` (path `/realms`) |

#### VSO Resources

| Resource | Kind | OpenBao Path | Syncs To |
|---|---|---|---|
| `default` | VaultConnection | `http://openbao.openbao.svc.cluster.local:8200` | — |
| `beeai-vaultauth` | VaultAuth | k8s auth / role `beeai-vso` | — |
| `beeai-credentials-sync` | VaultStaticSecret | `secret/data/beeai/credentials` | k8s Secret `beeai-credentials` |
| `beeai-enckey-sync` | VaultStaticSecret | `secret/data/beeai/encryption-key` | k8s Secret `beeai-encryption-key` |
| `beeai-vso` | ServiceAccount | — | Used by VSO to authenticate with OpenBao |

#### k8s Secrets (VSO-managed)

| Secret Name | Keys | Consumed By |
|---|---|---|
| `beeai-credentials` | `admin_password`, `pg_admin_password`, `pg_user_password`, `seaweedfs_secret` | Chart `existingSecret` refs for postgresql + seaweedfs; Keycloak user seeding |
| `beeai-encryption-key` | `value` | `encryptionKey` Helm value |

**Helm release:** `agentstack` from `oci://ghcr.io/i-am-bee/agentstack/chart`  
**Deploy tool:** OpenTofu Helm provider (working dir `/opt/beeai-agentstack-tofu`)

---

## Firewall Rules (firewalld, zone: `public`)

| Port/Proto | Purpose |
|---|---|
| `6443/tcp` | Kubernetes API server |
| `10250/tcp` | Kubelet metrics |
| `8472/udp` | Flannel VXLAN |
| `32200/tcp` | OpenBao NodePort (Ansible access) |
| `30080/tcp` | nginx HTTP NodePort |
| `30443/tcp` | nginx HTTPS NodePort |

> Ports `30333`, `30334`, `31288` (previous BeeAI NodePorts) are **no longer open**.

---

## Notable k8s Objects (cluster-scoped)

| Resource | Kind | Notes |
|---|---|---|
| `openbao-tokenreview` | ClusterRoleBinding | Binds `openbao` SA → `system:auth-delegator` |
| `openbao-pki` | ClusterIssuer | cert-manager issuer (see cert-manager section) |

---

## Access URLs

| Service | URL | Notes |
|---|---|---|
| BeeAI UI | `https://armory.local` | Via nginx Ingress, TLS from OpenBao PKI |
| BeeAI API | `https://armory.local/api/` | Via nginx Ingress |
| Keycloak | `https://armory.local/realms/agentstack` | Via nginx Ingress |
| OpenBao (from VM) | `http://127.0.0.1:32200` | NodePort, Ansible + admin use only |
| OpenBao (in-cluster) | `http://openbao.openbao.svc.cluster.local:8200` | Used by VSO, cert-manager |

---

## Retrieve Credentials

```bash
# Get admin password from OpenBao (authenticated, audit-logged)
vagrant ssh -c "sudo BAO_ADDR=http://127.0.0.1:32200 BAO_TOKEN=\$(ansible-vault decrypt --vault-password-file /opt/openbao/.vault-pass --output - /opt/openbao/init-keys.yml | python3 -c \"import sys,yaml; print(yaml.safe_load(sys.stdin)['root_token'])\") bao kv get -field=admin_password secret/beeai/credentials"

# Decrypt init keys file for human inspection
vagrant ssh -c "sudo python3 /vagrant/ansible/scripts/decrypt_vaulted_items.py --vault-password-file /opt/openbao/.vault-pass /opt/openbao/init-keys.yml"

# Get root token only
vagrant ssh -c "sudo python3 /vagrant/ansible/scripts/decrypt_vaulted_items.py --vault-password-file /opt/openbao/.vault-pass --key root_token /opt/openbao/init-keys.yml"
```
