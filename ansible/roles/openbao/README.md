# openbao role

## Purpose
Deploy OpenBao and configure it for PKI issuance, Kubernetes auth, and BeeAI secret storage.

## Supported platforms
- Fedora (all)

## Dependencies
- Runtime dependencies:
  - k3s cluster must be available.
  - Helm must be installed.
- Cross-role dependencies:
  - Consumed by `nginx_ingress` (PKI issuer integration).
  - Consumed by `beeai_agentstack_tofu` (VSO-authenticated secret sync).

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `openbao_work_dir` | `/opt/openbao` | Local working directory for rendered files and local artifacts. |
| `openbao_init_keys_file` | `{{ openbao_work_dir }}/init-keys.yml` | Path to encrypted init keys file. |
| `openbao_vault_pass_file` | `{{ openbao_work_dir }}/.vault-pass` | Local vault password file used to encrypt/decrypt init keys file. |
| `openbao_namespace` | `openbao` | Kubernetes namespace for OpenBao deployment. |
| `openbao_release_name` | `openbao` | Helm release name. |
| `openbao_chart_repo` | `https://openbao.github.io/openbao-helm` | OpenBao Helm repository URL. |
| `openbao_chart_name` | `openbao` | Helm chart name. |
| `openbao_chart_version` | `""` | Chart version override; empty uses latest. |
| `openbao_startup_wait_timeout` | `300s` | Timeout for pod startup wait. |
| `openbao_ready_wait_timeout` | `600s` | Timeout for readiness checks. |
| `openbao_node_port` | `32200` | Exposed NodePort for API access from host VM. |
| `openbao_api_addr` | `http://127.0.0.1:{{ openbao_node_port }}` | API endpoint used by Ansible tasks. |
| `openbao_cluster_addr` | `http://openbao.openbao.svc.cluster.local:8200` | In-cluster OpenBao address for integrations. |
| `openbao_key_shares` | `5` | Shamir secret share count for initialization. |
| `openbao_key_threshold` | `3` | Shamir threshold for unseal. |
| `openbao_kv_mount` | `secret` | KV v2 mount path for app credentials. |
| `openbao_pki_mount` | `pki` | PKI secrets engine mount path. |
| `openbao_pki_common_name` | `Armory Root CA` | Root CA common name. |
| `openbao_pki_ttl` | `87600h` | Root CA max TTL. |
| `openbao_pki_cert_role` | `armory-dot-local` | PKI role name used for certificate issuance. |
| `openbao_pki_internal_allowed_domains` | `svc.cluster.local` | Additional internal DNS suffixes allowed for in-cluster service certs. |
| `openbao_pki_allowed_domains` | `armory.local,svc.cluster.local` | Allowed certificate domains. |
| `openbao_pki_cert_ttl` | `8760h` | Issued certificate max TTL. |
| `openbao_beeai_namespace` | `agentstack` | Namespace used for BeeAI auth role bindings. |
| `openbao_vso_sa_name` | `beeai-vso` | Service account used by Vault Secrets Operator auth role. |
| `openbao_certmanager_namespace` | `cert-manager` | Namespace used for cert-manager auth role binding. |
| `openbao_certmanager_sa_name` | `cert-manager` | cert-manager service account bound to PKI policy. |
| `openbao_firewall_manage` | `true` | Whether to manage firewalld for OpenBao NodePort. |
| `openbao_firewall_zone` | `public` | firewalld zone used for OpenBao NodePort. |

## Task flow
1. Create local working directory.
2. Install OpenBao with Helm and wait for pod/API readiness (`install.yml`).
3. Initialize OpenBao on first run and persist encrypted init keys (`init.yml`).
4. Unseal OpenBao on subsequent runs when needed (`unseal.yml`).
5. Configure engines, auth methods, policies, and auth roles (`configure.yml`).
6. Generate and persist BeeAI credentials/encryption key in KV (`credentials.yml`).

## Usage
```yaml
- hosts: all
  roles:
    - role: openbao
```

Override example:
```yaml
- hosts: all
  roles:
    - role: openbao
      vars:
        openbao_node_port: 32200
        openbao_pki_allowed_domains: "armory.local,example.local"
```

## Troubleshooting
- OpenBao pod does not become ready.
  Action: check task failure diagnostics from `install.yml` (pod describe/log output is captured).
- Unseal fails.
  Action: verify `openbao_vault_pass_file` and `openbao_init_keys_file` exist and are readable by root.
- cert-manager or VSO integration fails.
  Action: verify `openbao_cluster_addr`, mount paths, and auth role/service account names match consumer roles.
