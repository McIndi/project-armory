#!/usr/bin/env bash
# Mint a short-lived token for the armory automation account and write a
# kubeconfig that uses it.
#
# The token is created per run rather than stored, so no standing credential
# sits on the controller. You authorise the run by being logged in as an admin
# when you call this; the playbook itself then executes with an identity that
# can only reach armory's own projects.
#
#   source scripts/use-automation-sa.sh
#   ansible-playbook playbooks/site.yml
#
# Sourcing (not executing) matters: it exports KUBECONFIG into your shell so the
# playbook picks it up.

# This file is meant to be `source`d (see usage above), not executed — that's
# how KUBECONFIG reaches your shell. But `source` runs in the CURRENT shell,
# not a subshell, so `set -euo pipefail` and any bare `exit` here would apply
# to (and can kill) the interactive/SSH shell that sourced it: the very next
# unrelated command that returns non-zero silently terminates that shell once
# errexit has leaked into it, and `exit 1` below would end the session outright
# instead of just this script. Scope strict-mode to this script's own body and
# restore the caller's original options when done; use `return`, never `exit`.
_use_automation_sa_prev_opts="$(set +o)"
_use_automation_sa_prev_umask="$(umask)"
trap 'eval "${_use_automation_sa_prev_opts}"; umask "${_use_automation_sa_prev_umask}"; trap - RETURN' RETURN
set -euo pipefail

SA_NAME="${ARMORY_AUTOMATION_SA_NAME:-tex26-automation}"
SA_NAMESPACE="${ARMORY_AUTOMATION_SA_NAMESPACE:-tex26-automation}"
DURATION="${ARMORY_AUTOMATION_TOKEN_DURATION:-4h}"
OUT="${ARMORY_AUTOMATION_KUBECONFIG:-${HOME}/.armory/automation.kubeconfig}"

# Read from the CURRENT (admin) session before we switch away from it. The
# admin context may trust the cluster via an inline CA, a CA file path, or
# (common on a dev/lab cluster with a self-signed router cert, e.g. behind
# `oc login --insecure-skip-tls-verify`) no CA at all. Carry forward whichever
# form is actually in use instead of assuming inline CA data always exists —
# otherwise the generated kubeconfig silently falls back to strict
# verification with an empty CA and every call fails with "certificate signed
# by unknown authority".
SERVER="$(oc whoami --show-server)"
CA_DATA="$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
CA_FILE="$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
INSECURE="$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}')"

if [[ -z "${CA_DATA}" && -n "${CA_FILE}" && -f "${CA_FILE}" ]]; then
  CA_DATA="$(base64 -w0 <"${CA_FILE}")"
fi

if [[ -n "${CA_DATA}" ]]; then
  CLUSTER_TLS_LINE="      certificate-authority-data: ${CA_DATA}"
elif [[ "${INSECURE}" == "true" ]]; then
  CLUSTER_TLS_LINE="      insecure-skip-tls-verify: true"
else
  echo "ERROR: current oc session has neither a CA (inline or file) nor" >&2
  echo "insecure-skip-tls-verify=true; cannot build a trusted automation kubeconfig." >&2
  return 1
fi

echo "Minting a ${DURATION} token for ${SA_NAMESPACE}:${SA_NAME} as $(oc whoami)..."
TOKEN="$(oc create token "${SA_NAME}" -n "${SA_NAMESPACE}" --duration="${DURATION}")"

mkdir -p "$(dirname "${OUT}")"
umask 077
cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: armory
    cluster:
      server: ${SERVER}
${CLUSTER_TLS_LINE}
users:
  - name: ${SA_NAME}
    user:
      token: ${TOKEN}
contexts:
  - name: armory
    context:
      cluster: armory
      user: ${SA_NAME}
current-context: armory
EOF

export KUBECONFIG="${OUT}"

echo "KUBECONFIG=${KUBECONFIG}"
echo "Now running as: $(oc whoami)"
echo "Token expires in ${DURATION}. Re-source this script if a run outlives it."
