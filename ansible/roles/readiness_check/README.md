# readiness_check role

## Purpose
Perform post-deployment validation of the Armory OpenShift environment. Checks connectivity, health endpoints, resource status, and credential availability across all major infrastructure components. Aggregates results into a summary report and indicates pass/fail/warn status without stopping on first failure.

Intended to be run after core platform roles complete to verify all services are ready for use.

## Supported platforms
- Fedora (all)

## Prerequisites
- The environment should already have been provisioned by the relevant roles before running readiness checks: `openbao`, `envoy_proxy`, `keycloak`
- This role intentionally has no runtime metadata dependencies so it can be executed in isolation.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `readiness_check_helm_enabled` | `true` | Validate Helm availability and repo access. |
| `readiness_check_openbao_enabled` | `true` | Validate OpenBao connectivity, health, and unsealed status. |
| `readiness_check_keycloak_enabled` | `true` | Validate Keycloak namespace/service/secret and OIDC discovery endpoint. |
| `readiness_check_trace_boundary_enabled` | `true` | Verify the trace-context trust boundary via an ephemeral echo backend behind the Envoy edge. |
| `readiness_check_connect_timeout` | `5` | TCP connection timeout in seconds. |
| `readiness_check_connect_retries` | `2` | Number of retry attempts for network checks. |
| `readiness_check_validate_tls` | `false` | Validate TLS certificate expiry and validity. |
| `readiness_check_strict_tls_checks_enabled` | `true` | Strict TLS trust checks for service endpoints using explicit CA bundles. |
| `readiness_check_validate_credentials` | `false` | Attempt to use stored credentials to verify they work. |
| `readiness_check_fail_on_issues` | `true` | Fail at end of role if any critical issues detected. |

## Task flow
1. Resolve the `ARMORY_LOG_NOLOG` flag and the kubeconfig path.
2. Import subtask files (one per component), each gated on its `*_enabled` toggle:
   - `check_helm.yml`: Helm CLI version, Helm repo availability.
   - `check_openbao.yml`: OpenBao TCP port 8200, health endpoint, and unsealed status via the internal TLS service address.
   - `check_openbao_ui.yml`: OpenBao UI ingress reachability and expected OIDC policies/groups.
   - `check_trace_boundary_envoy.yml`: forged external trace context is stripped at the edge, a fresh gateway trace-id reaches the backend, and the inbound traceparent is captured in the forensic header.
   - `check_keycloak.yml`: Keycloak namespace, service, admin secret, OIDC discovery endpoint checks with ingress fallback, and Postgres TLS verify-full posture checks when enabled.
3. Render summary report and per-component breakdown from template.
4. Print report to console.
5. Fail at end with aggregated issues if `readiness_check_fail_on_issues=true` and any failures detected.

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
ansible-playbook playbooks/site.yml -e 'readiness_check_keycloak_enabled=true readiness_check_openbao_enabled=false' --tags readiness_check
```

Run with debug output:
```bash
ansible-playbook playbooks/site.yml --tags readiness_check
```

## Troubleshooting
- **Some checks fail but role continues to end**: This is expected behavior. The role collects all results before reporting, so you see the complete picture.
- **Credential checks fail**: If `readiness_check_validate_credentials=true`, this may indicate bad credentials in OpenBao or Kubernetes secrets. Verify using commands in the main README.md.
- **TLS certificate checks fail**: Verify ingress TLS secrets exist and are valid: `oc get secret -n keycloak`.

## Notes
- The role does **not** perform exhaustive integration tests or data validation; it checks basic connectivity and readiness indicators.
- Network checks do not print sensitive information (credentials, tokens, keys); they report pass/fail/warn status instead.
- All checks run in check mode compatible context (many checks use `changed_when: false` for idempotency).
