# env_guard role

## Purpose
Preflight validation for required environment variables before any infrastructure changes run.

## Supported platforms
- Fedora (all)

## Dependencies
- No role dependencies.
- Intended to run first in playbooks so failures happen early.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `env_guard_sentry_var_name` | `ARMORY_ENV_SOURCED` | Environment variable name to validate. |
| `env_guard_expected_value` | `armory2-env-loaded-v1` | Expected value for the sentry variable. |

## Task flow
1. Read sentry value from controller environment.
2. Assert the variable exists.
3. Assert the value matches the expected value.

## Usage
```yaml
- hosts: all
  roles:
    - role: env_guard
```

Override example:
```yaml
- hosts: all
  roles:
    - role: env_guard
      vars:
        env_guard_sentry_var_name: CUSTOM_ENV_SENTRY
        env_guard_expected_value: loaded
```

## Troubleshooting
- Error: missing sentry variable.
  Action: source `.env` before running Ansible.
- Error: sentry value mismatch.
  Action: re-copy `.env` from `.env.example`, source it, and rerun.
- Role appears skipped.
  Action: ensure the role is included in the play and not filtered out by tags.
