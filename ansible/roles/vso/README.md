# vso role

## Purpose
Install the **Vault Secrets Operator (VSO)** once, as a shared cluster
prerequisite. Any role that syncs OpenBao secrets into Kubernetes
(`keycloak`, `headlamp`) depends on this operator being
present, but each owns its own per-namespace VaultConnection / VaultAuth /
VaultStaticSecret resources.

## What this role does
1. Validates that a hardened/forked VSO chart is configured (explicit
   kube-rbac-proxy TLS cert/key support).
2. Renders the effective Helm values (controller kube-rbac-proxy TLS +
   `defaultVaultConnection` pointing at OpenBao).
3. Ensures the VSO namespace and copies the OpenBao CA secret into it.
4. Issues a cert-manager `Certificate` (ClusterIssuer `openbao-pki`) for the
   kube-rbac-proxy TLS and waits for the cert/secret.
5. `helm upgrade --install` of the hardened VSO chart.

When `use_declarative_ca_distribution: true`, this role no longer performs
namespace-local OpenBao CA copy. It expects trust-manager to have already
synced the configured CA target Secret into the VSO namespace.

## Chart source (env)
The hardened chart lives at `charts/vso-hardened`. Configure via environment:

```bash
VSO_CHART_PATH=/vagrant/project-armory/charts/vso-hardened   # local (preferred)
# or a pinned published chart:
VSO_CHART_REPO=...
VSO_CHART_NAME=...
VSO_CHART_VERSION=...
```

## Run
```bash
ansible-playbook playbooks/site.yml --tags vso
```

Must run before any VSO consumer (ordered ahead of keycloak/headlamp in
`site.yml`). Requires cert-manager + the OpenBao `openbao-pki` ClusterIssuer.

## History
Extracted from the former stack-deploy role (where the operator install was trapped in
the same block as the Agent Stack chart deploy). See
`doc/vso-extraction-plan.md`.
