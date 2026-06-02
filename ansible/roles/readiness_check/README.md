# readiness_check role

## Purpose
Perform post-deployment validation of the Armory2 environment. Checks connectivity, health endpoints, resource status, and credential availability across all major infrastructure components. Aggregates results into a summary report and indicates pass/fail/warn status without stopping on first failure.

Intended to be run after core platform roles complete to verify all services are ready for use.

## Supported platforms
- Fedora (all)

## Prerequisites
- The environment should already have been provisioned by the relevant roles before running readiness checks: `env_guard`, `system_update`, `k3s`, `openbao`, `nginx_ingress`, `vso`, `keycloak`, `headlamp`
- This role intentionally has no runtime metadata dependencies so it can be executed in isolation.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `readiness_check_host_enabled` | `true` | Validate host-level readiness (firewall, SELinux, packages). |
| `readiness_check_k3s_enabled` | `true` | Validate k3s cluster health and node status. |
| `readiness_check_helm_enabled` | `true` | Validate Helm availability and repo access. |
| `readiness_check_openbao_enabled` | `true` | Validate OpenBao connectivity, health, and unsealed status. |
| `readiness_check_vso_enabled` | `true` | Validate Vault Secrets Operator deployment and vaultconnection resources. |
| `readiness_check_nginx_enabled` | `true` | Validate nginx ingress controller and TLS certificates. |
| `readiness_check_keycloak_enabled` | `true` | Validate Keycloak namespace/service/secret and OIDC discovery endpoint. |
| `readiness_check_connect_timeout` | `5` | TCP connection timeout in seconds. |
| `readiness_check_connect_retries` | `2` | Number of retry attempts for network checks. |
| `readiness_check_validate_tls` | `false` | Validate TLS certificate expiry and validity. |
| `readiness_check_validate_credentials` | `false` | Attempt to use stored credentials to verify they work. |
| `readiness_check_fail_on_issues` | `true` | Fail at end of role if any critical issues detected. |

## Task flow
2. Initialize result aggregator facts.
3. Import subtask files (one per component):
   - `check_host.yml`: firewall rules, SELinux status, DNS resolution, kernel parameters, installed packages.
   - `check_k3s.yml`: cluster nodes, kube-apiserver connectivity, k3s service status.
   - `check_helm.yml`: Helm CLI version, Helm repo availability.
  - `check_openbao.yml`: OpenBao TCP port 8200, health endpoint, and unsealed status via the internal TLS service address.
   - `check_vso.yml`: Vault Secrets Operator deployment running, vaultconnection resources present.
   - `check_nginx.yml`: nginx ingress controller pods, ingress rules, TLS certificate validity.
  - `check_keycloak.yml`: Keycloak namespace, service, admin secret, and OIDC discovery endpoint checks with ingress fallback when DNS is unavailable.
4. Render summary report and per-component breakdown from template.
5. Print report to console.
6. Fail at end with aggregated issues if `readiness_check_fail_on_issues=true` and any failures detected.

## Usage
```yaml
- hosts: all
  roles:
    - role: readiness_check
```

Tag usage:
```bash
# Run full readiness check
ansible-playbook playbooks/site.yml --tags readiness_check

# Run subset of checks
ansible-playbook playbooks/site.yml -e 'readiness_check_keycloak_enabled=true readiness_check_k3s_enabled=true' --tags readiness_check
```

Run with debug output:
```bash
ansible-playbook playbooks/site.yml --tags readiness_check
```

## Troubleshooting
- **Some checks fail but role continues to end**: This is expected behavior. The role collects all results before reporting, so you see the complete picture.
- **Credential checks fail**: If `readiness_check_validate_credentials=true`, this may indicate bad credentials in OpenBao or Kubernetes secrets. Verify using commands in the main README.md.
- **TLS certificate checks fail**: Verify ingress TLS secrets exist and are valid: `kubectl get secret -n keycloak`.
- **k3s not ready**: Check node status with `kubectl get nodes` and pod status with `kubectl get pods -n kube-system`.

## Notes
- The role does **not** perform exhaustive integration tests or data validation; it checks basic connectivity and readiness indicators.
- Network checks do not print sensitive information (credentials, tokens, keys); they report pass/fail/warn status instead.
- All checks run in check mode compatible context (many checks use `changed_when: false` for idempotency).
