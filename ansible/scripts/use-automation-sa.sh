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

set -euo pipefail

SA_NAME="${ARMORY_AUTOMATION_SA_NAME:-tex26-automation}"
SA_NAMESPACE="${ARMORY_AUTOMATION_SA_NAMESPACE:-tex26-automation}"
DURATION="${ARMORY_AUTOMATION_TOKEN_DURATION:-4h}"
OUT="${ARMORY_AUTOMATION_KUBECONFIG:-${HOME}/.armory/automation.kubeconfig}"

# Read from the CURRENT (admin) session before we switch away from it.
SERVER="$(oc whoami --show-server)"
CA_DATA="$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

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
      certificate-authority-data: ${CA_DATA}
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
