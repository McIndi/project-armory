# system_update role

## Purpose
Apply package updates on Fedora hosts with `dnf`.

## Supported platforms
- Fedora (all)

## Dependencies
- No role dependencies.
- Requires package manager access and repository connectivity.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `system_update_package_state` | `latest` | Package state passed to `dnf`. |
| `system_update_update_only` | `true` | When true, only installed packages are updated. |
| `system_update_update_cache` | `true` | When true, refresh package metadata before update. |

## Task flow
1. Run `dnf` update for all installed packages.
2. Emit debug output with the update result structure.

## Usage
```yaml
- hosts: all
  roles:
    - role: system_update
```

Tag usage:
```bash
ansible-playbook playbooks/site.yml --tags dnf_update
```

## Troubleshooting
- Update fails with repo errors.
  Action: verify network and enabled repositories on the target host.
- Slow update runs.
  Action: confirm mirrors are reachable and metadata refresh is expected.
- Unexpected package changes.
  Action: set `system_update_update_only` and review repository configuration.
