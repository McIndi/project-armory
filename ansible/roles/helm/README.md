# helm role

## Purpose
Install Helm with `dnf` and verify CLI availability.

## Supported platforms
- Fedora (all)

## Dependencies
- No role dependencies.
- Requires configured package repositories on the target host.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `helm_package_name` | `helm` | Package name installed by `dnf`. |
| `helm_package_state` | `present` | Desired package state. |

## Task flow
1. Install Helm package using `dnf`.
2. Run `helm version --short` as a non-changing validation task.

## Usage
```yaml
- hosts: all
  roles:
    - role: helm
```

Tag usage:
```bash
ansible-playbook playbooks/site.yml --tags helm_install
```

## Troubleshooting
- Helm package not found.
  Action: verify enabled repositories provide `helm`.
- Version check fails.
  Action: ensure binary is in PATH for the execution user.
- Validation skipped in check mode.
  Action: rerun without check mode for command verification.
