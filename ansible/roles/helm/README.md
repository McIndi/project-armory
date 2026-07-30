# helm role

## Purpose
Install Helm when missing, validate the CLI, and install the `helm-diff` plugin
when missing.

## Supported platforms
- Fedora OpenShift controller/workstation environments

## Dependencies
- No role dependencies.
- Requires Fedora repositories that provide the `helm` package.

## Variables
Defined in `defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|

## Task flow
1. Check whether `helm` is already available.
2. Install the `helm` package with `dnf` only when the check fails.
3. Run `helm version --short` as a non-changing validation task.
4. Ensure the `helm-diff` plugin is installed when not already present.

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
  Action: confirm the Fedora repositories provide the `helm` package and that
  the installed executable is in PATH for the execution user.
- Validation skipped in check mode.
  Action: rerun without check mode for command verification.
