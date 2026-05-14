# k3s role

## Purpose
Install and configure a single-node k3s cluster with SELinux and firewalld preparation.

## Supported platforms
- Fedora (all)

## Dependencies
- No role dependencies.
- Expects network access to `https://get.k3s.io` for initial install.
- Uses `firewalld` and SELinux tooling on the target host.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `k3s_version` | `""` | k3s version; empty installs latest stable from installer script. |
| `k3s_install_dir` | `/usr/local/bin` | k3s binary location used for install checks. |
| `k3s_config_dir` | `/etc/rancher/k3s` | Directory for k3s config and runtime settings. |
| `k3s_disable` | `[traefik]` | Built-in components disabled at startup. |
| `k3s_secrets_encryption` | `true` | Enables etcd secrets encryption in rendered config. |
| `k3s_firewall_zone` | `public` | Firewalld zone for k3s ports. |
| `k3s_api_port` | `6443` | Kubernetes API server TCP port. |
| `k3s_kubelet_port` | `10250` | Kubelet TCP port. |
| `k3s_flannel_port` | `8472` | Flannel VXLAN UDP port. |
| `k3s_pod_cidr` | `10.42.0.0/16` | k3s pod network CIDR allowed in firewalld. |
| `k3s_service_cidr` | `10.43.0.0/16` | k3s service CIDR allowed in firewalld. |
| `k3s_firewall_allow_cluster_cidrs` | `true` | Enables explicit firewalld source allowances for k3s CIDRs. |

## Task flow
1. Import SELinux tasks (`tasks/selinux.yml`).
2. Import firewall tasks (`tasks/firewall.yml`).
3. Import install tasks (`tasks/install.yml`) to:
   - check existing install,
   - render `config.yaml`,
   - run installer when needed,
   - remove Traefik HelmChart resources if disabled,
   - ensure k3s service is enabled and started.
4. Trigger handlers to reload firewalld and restart k3s when required.

## Usage
```yaml
- hosts: all
  roles:
    - role: k3s
```

Override example:
```yaml
- hosts: all
  roles:
    - role: k3s
      vars:
        k3s_version: v1.31.6+k3s1
        k3s_disable: [traefik, servicelb]
```

## Troubleshooting
- Installer download or execution fails.
  Action: verify outbound network access and DNS resolution.
- API server not reachable.
  Action: check firewalld rules, service status, and `k3s kubectl get nodes` output.
- Traefik remains after disabling.
  Action: rerun role without check mode so cleanup command executes.
