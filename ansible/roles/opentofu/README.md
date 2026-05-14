# opentofu role

## Purpose
Install OpenTofu on Fedora hosts and validate installation.

## Supported platforms
- Fedora (all)

## Dependencies
- No role dependencies.
- Uses `dnf` package repositories configured on the target host.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `opentofu_package_name` | `opentofu` | Package name installed by `dnf`. |
| `opentofu_package_state` | `present` | Desired package state. |

## Task flow
1. Install OpenTofu with `dnf` (with cache refresh).
2. On failure, clean dnf caches and remove stale OpenTofu RPM cache artifacts.
3. Retry OpenTofu installation.
4. Run `tofu version` for verification.

## Usage
```yaml
- hosts: all
  roles:
    - role: opentofu
```

Tag usage:
```bash
ansible-playbook playbooks/site.yml --tags tofu_install
```

## Troubleshooting
- Package verification or metadata failures.
  Action: rerun role; built-in rescue path clears common stale cache issues.
- `tofu` command not found after run.
  Action: verify package repositories include OpenTofu and inspect role output.
- Version check skipped in dry-run.
  Action: run without check mode to execute command verification tasks.
