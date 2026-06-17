#!/usr/bin/env bash

# Capture a broad, comparison-friendly deployment snapshot.
# The script is intentionally read-only and safe to run before or after plays.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
START_TS=$(date +%s)

OUTPUT_DIR="${1:-${REPO_ROOT}/log/run-snapshots}"
mkdir -p "${OUTPUT_DIR}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="${OUTPUT_DIR}/run-snapshot-${STAMP}.log"
INDEX=1
while [[ -e "${OUTFILE}" ]]; do
  OUTFILE="${OUTPUT_DIR}/run-snapshot-${STAMP}-${INDEX}.log"
  INDEX=$((INDEX + 1))
done

if [[ -f /vagrant/.env ]]; then
  set -a
  # shellcheck source=/dev/null
  source /vagrant/.env
  set +a
fi

KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() {
  printf '%s\n' "$*" >> "${OUTFILE}"
}

progress() {
  local message="$1"
  local now_ts

  now_ts=$(date +%s)
  printf '%s [runtime=%ss] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((now_ts - START_TS))" "${message}" >&2
}

header() {
  log
  log "===== $* ====="
}

run_cmd() {
  local title="$1"
  local cmd="$2"

  progress "Starting: ${title}"
  header "${title}"
  log "$ ${cmd}"

  if output=$(bash -o pipefail -lc "${cmd}" 2>&1); then
    log "${output}"
    log "[rc=0]"
  else
    rc=$?
    log "${output}"
    log "[rc=${rc}]"
  fi
}

hash_jsonpath_field() {
  local ns="$1"
  local secret="$2"
  local field="$3"
  local label="$4"

  if sudo -n k3s kubectl get secret -n "${ns}" "${secret}" --kubeconfig "${KUBECONFIG_PATH}" >/dev/null 2>&1; then
    run_cmd "Secret hash: ${label}" "sudo -n k3s kubectl get secret -n ${ns} ${secret} --kubeconfig ${KUBECONFIG_PATH} -o jsonpath='{${field}}' | sha256sum"
  else
    progress "Skipping: Secret hash: ${label} (missing ${ns}/${secret})"
    header "Secret hash: ${label}"
    log "Secret ${ns}/${secret} not found"
    log "[rc=1]"
  fi
}

progress "Initializing snapshot output"
log "Snapshot file: ${OUTFILE}"
log "Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

run_cmd "Host context" "hostnamectl; echo; date -u; echo; whoami; echo; pwd"
run_cmd "Repository context" "if command -v git >/dev/null 2>&1; then cd '${REPO_ROOT}' && git rev-parse --short HEAD && git -c core.autocrlf=true status --short; else echo 'git not installed in VM PATH'; fi"
run_cmd "Tool versions" "ansible --version 2>/dev/null | head -n 2; echo; helm version --short 2>/dev/null; echo; k3s --version 2>/dev/null | head -n 1; echo; sudo -n k3s kubectl version --client 2>/dev/null | head -n 1"

run_cmd "Kubernetes nodes" "sudo -n k3s kubectl get nodes --kubeconfig ${KUBECONFIG_PATH} -o wide"
run_cmd "Kubernetes namespaces" "sudo -n k3s kubectl get ns --kubeconfig ${KUBECONFIG_PATH}"
run_cmd "All pods" "sudo -n k3s kubectl get pods -A --kubeconfig ${KUBECONFIG_PATH} -o wide"
run_cmd "All deployments" "sudo -n k3s kubectl get deploy -A --kubeconfig ${KUBECONFIG_PATH}"
run_cmd "All statefulsets" "sudo -n k3s kubectl get sts -A --kubeconfig ${KUBECONFIG_PATH}"
run_cmd "All jobs and cronjobs" "sudo -n k3s kubectl get jobs,cronjobs -A --kubeconfig ${KUBECONFIG_PATH}"
run_cmd "Helm releases" "sudo -n helm list -A --kubeconfig ${KUBECONFIG_PATH}"

run_cmd "OpenBao pod identity" "sudo -n k3s kubectl get pod -n openbao -l app.kubernetes.io/name=openbao --kubeconfig ${KUBECONFIG_PATH} -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,START:.status.startTime' --no-headers"
run_cmd "Keycloak pod identity" "sudo -n k3s kubectl get pod -n keycloak keycloak-0 --kubeconfig ${KUBECONFIG_PATH} -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,START:.status.startTime' --no-headers"

run_cmd "OpenBao CA certificate fingerprint" "if [[ -f /opt/openbao/tls/ca.crt ]]; then openssl x509 -in /opt/openbao/tls/ca.crt -noout -fingerprint -sha256 -serial -enddate; else echo 'missing: /opt/openbao/tls/ca.crt'; exit 1; fi"
run_cmd "OpenBao server certificate fingerprint" "if [[ -f /opt/openbao/tls/tls.crt ]]; then openssl x509 -in /opt/openbao/tls/tls.crt -noout -fingerprint -sha256 -serial -enddate; else echo 'missing: /opt/openbao/tls/tls.crt'; exit 1; fi"

hash_jsonpath_field "openbao" "openbao-ca" ".data.ca\\.crt" "openbao/openbao-ca ca.crt"
hash_jsonpath_field "openbao" "openbao-server-tls" ".data.tls\\.crt" "openbao/openbao-server-tls tls.crt"

run_cmd "Recent cluster events" "sudo -n k3s kubectl get events -A --sort-by=.lastTimestamp --kubeconfig ${KUBECONFIG_PATH} | tail -n 200"

progress "Snapshot complete"
echo "Snapshot written: ${OUTFILE}"
