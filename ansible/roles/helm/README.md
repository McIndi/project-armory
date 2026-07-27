# helm role

## Purpose
Validate Helm CLI availability and install the `helm-diff` plugin when missing.

## Supported platforms
- OpenShift controller/workstation environments with Helm pre-provisioned

## Dependencies
- No role dependencies.
- Requires `helm` to already be present in PATH for the execution user.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|

## Task flow
1. Run `helm version --short` as a non-changing validation task.
2. Ensure the `helm-diff` plugin is installed when not already present.

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
- Version check fails.
  Action: ensure `helm` is installed and in PATH for the execution user.
- Validation skipped in check mode.
  Action: rerun without check mode for command verification.
