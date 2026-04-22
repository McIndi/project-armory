#!/usr/bin/env bash
# =============================================================================
# rebuild.sh — Full teardown and rebuild of Project Armory from scratch.
#
# PURPOSE
# -------
# This script is the single entry point for a clean, reproducible rebuild of
# the entire Project Armory stack. It first destroys every existing deployment
# (containers, OpenTofu state, host directories) and then re-applies every
# module in the correct phase order. Think of it as "nuke and pave."
#
# WHY A SCRIPT INSTEAD OF JUST RUNNING TOFU MANUALLY?
# ----------------------------------------------------
# The Project Armory stack has hard inter-module dependencies that cannot be
# expressed inside a single OpenTofu module (they span separate state files).
# For example:
#   - Vault must be initialised and unsealed before vault-config can apply.
#   - vault-config must create the PKI hierarchy before services can request
#     certificates from the Vault Agent sidecar.
#   - PostgreSQL must be running and reachable from inside the Vault container
#     before vault-config can create the database static/dynamic roles.
# This script encodes that dependency order and adds the readiness gates
# (health checks, DNS resolution probes) needed between phases.
#
# USAGE
# -----
#   ./rebuild.sh [OPTIONS]
#
# OPTIONS
#   --skip-webserver   Skip Phase 4 (nginx + Vault Agent sidecar demo).
#                      Useful when you only need the core vault/db/auth stack.
#   --skip-keycloak    Skip Phases 6 and 9 (Keycloak and the agentic layer).
#                      Automatically implies --skip-agent.
#   --skip-agent       Skip Phase 9 (services/agent module only).
#                      Keycloak is still deployed; only the agent AppRole and
#                      services/agent tofu module are omitted.
#   --base-dir PATH    Override the runtime artefact root directory.
#                      Example: --base-dir /home/cliff/armory
#   --destroy-only     Run the teardown phase but do not rebuild. Useful for
#                      cleaning up a broken environment without rebuilding.
#   --help / -h        Print this header and exit.
#
# BASE DIRECTORY OVERRIDES
# ------------------------
# The runtime artefact root defaults to /opt/armory, but can be overridden by:
#   1) CLI flag:  ./rebuild.sh --base-dir /home/cliff/armory
#   2) Env var:   export ARMORY_BASE_DIR=/home/cliff/armory
#   3) One-shot:  ARMORY_BASE_DIR=/home/cliff/armory ./rebuild.sh
#
# PHASE SUMMARY
# -------------
#   Teardown  Destroy all modules in reverse dependency order, force-remove
#             containers, remove the armory-net Podman network, purge
#             $DEPLOY_DIR (default /opt/armory), and wipe all terraform.tfstate files so the
#             subsequent apply always starts from a completely clean slate.
#
#   Phase 0   Create $DEPLOY_DIR and chown it to $USER (rootless Podman
#             requires the deploy directory to be writable without sudo).
#
#   Phase 1   Apply vault/ — generates TLS certs, writes vault.hcl, and
#             starts the OpenBao container via podman compose.
#
#   Phase 2   Key ceremony: bao operator init (1-of-1 threshold) to obtain
#             the unseal key and root token, then immediately unseal Vault.
#             Credentials are saved to unseal_key-and-root_token.txt and the
#             root token is exported as TF_VAR_vault_token for all subsequent
#             tofu modules.
#
#   Phase 3   Apply vault-config/ — builds the three-tier PKI hierarchy
#             (pki / pki_int / pki_ext), AppRole auth method, userpass
#             operator account, OIDC auth stub, ACL policies, KV v2 engine
#             (Keycloak admin secret), and the Database secrets engine
#             connection (without roles yet — PostgreSQL is not running).
#
#   Phase 4   Apply services/webserver/ — nginx on port 8443 with a Vault
#             Agent sidecar that fetches and auto-rotates a TLS certificate
#             from pki_ext. Demonstrates the Vault Agent sidecar pattern.
#             (Skippable with --skip-webserver.)
#
#   Phase 5   Apply services/postgres/ — PostgreSQL 16 on armory-net with a
#             Vault Agent sidecar that renders a TLS cert from pki_int.
#             The script then waits until armory-postgres is both healthy
#             AND resolvable from inside the Vault container before
#             proceeding — this is critical for Phase 5b.
#
#   Phase 5b  Re-apply vault-config/ with database_roles_enabled=true —
#             creates the Keycloak static role and the app dynamic role.
#             Vault connects to armory-postgres immediately on role creation,
#             which is why Phase 5 must be fully up first.
#
#   Phase 6   Apply services/keycloak/ — Keycloak 24 on port 8444 with a
#             Vault Agent sidecar that renders: TLS cert (pki_ext), Postgres
#             password (database/static-creds/keycloak), and admin bootstrap
#             credentials (kv/data/keycloak/admin).
#             (Skippable with --skip-keycloak.)
#
#   Phase 9   Re-apply vault-config/ with agent_enabled=true, then apply
#             services/agent/ — writes role_id and wrapped_secret_id to
#             $DEPLOY_DIR/agent/approle/ for the FastAPI agentic layer.
#             (Skippable with --skip-agent or --skip-keycloak.)
#
# MANUAL STEPS NOT AUTOMATED BY THIS SCRIPT
# ------------------------------------------
#   Phase 7   Configure the Keycloak 'armory' realm via the admin console:
#             create the 'vault-operators' group, the 'vault' confidential
#             OIDC client (with a Group Membership protocol mapper), and the
#             'agent-cli' public OIDC client (PKCE/S256, no direct grant).
#             This requires browser-based interaction and a Keycloak client
#             secret that cannot be predicted ahead of time.
#
#   Phase 8   Enable the Vault OIDC auth method by re-applying vault-config/
#             with oidc_enabled=true and the client secret from Phase 7.
#             Must be done after Phase 7 because the secret is only known
#             once the Keycloak client exists.
#
#   Agent API Start the FastAPI server manually:
#             cd services/agent/agent && .venv/bin/python api.py
#             The wrapped_secret_id is single-use; re-run services/agent/
#             tofu apply to issue a new one before each cold start.
#
# DESIGN NOTES
# ------------
# - set -euo pipefail: any unhandled error, unbound variable, or failed pipe
#   segment causes the script to exit immediately. This prevents silent
#   partial deployments.
# - All tofu commands run inside ( cd ... ) subshells. This avoids changing
#   the working directory of the parent shell, which would break relative
#   paths in later phases.
# - Output from tofu is piped through sed to prefix every line with the
#   module name, making logs easier to follow in a long terminal session.
# - TF_VAR_vault_token is exported (not just set) so it is inherited by the
#   subshells that run tofu apply for each module.
# - The teardown wipes terraform.tfstate files after attempting graceful
#   tofu destroy. This is necessary because null_resource provisioners are
#   trigger-based: if the compose file content hash in stale state matches
#   the new content, tofu skips the `podman compose up` call entirely,
#   leaving the containers unstarted with no error.
# =============================================================================

set -euo pipefail

# =============================================================================
# COLOUR HELPERS
# =============================================================================
# ANSI escape codes for terminal colour output. Using -e with echo interprets
# these escape sequences. All output functions include a timestamp so you can
# correlate log lines with system activity when debugging slow phases.
# =============================================================================

RED='\033[0;31m'     # Errors
YELLOW='\033[1;33m'  # Warnings
GREEN='\033[0;32m'   # Success messages
CYAN='\033[0;36m'    # Informational log lines
BOLD='\033[1m'       # Section headers
RESET='\033[0m'      # Reset all attributes

# log: normal informational message, prefixed with a cyan timestamp.
log()     { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }

# success: action completed successfully, printed in green with a check mark.
success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓ $*${RESET}"; }

# warn: something non-fatal happened that the operator should know about.
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠ $*${RESET}"; }

# error: a fatal condition; the script will normally exit shortly after.
# Written to stderr so it stays visible even when stdout is redirected.
error()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗ $*${RESET}" >&2; }

# header: bold cyan banner to delimit major phases in the output.
header()  {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n"
}

# =============================================================================
# PATHS AND FLAGS
# =============================================================================

# SCRIPT_DIR: absolute path to the directory containing this script (the
# project root). Using BASH_SOURCE[0] instead of $0 is safer when the script
# is sourced or called via a symlink.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CREDS_FILE: where the unseal key and root token are saved after the key
# ceremony. This file is gitignored. It is also read during teardown so the
# script can re-unseal a sealed Vault before running tofu destroy against it.
CREDS_FILE="$SCRIPT_DIR/unseal_key-and-root_token.txt"

# DEPLOY_DIR: the host-side runtime directory tree. Every module writes its
# compose files, TLS certs, AppRole credentials, and other artefacts here.
# It is created in Phase 0 and purged in teardown.
ARMORY_BASE_DIR="${ARMORY_BASE_DIR:-/opt/armory}"
DEPLOY_DIR="$ARMORY_BASE_DIR"

# ── Feature flags (overridden by CLI arguments below) ────────────────────────

SKIP_WEBSERVER=false   # If true, Phase 4 (nginx) is skipped
SKIP_KEYCLOAK=false    # If true, Phases 6 and 9 are skipped
SKIP_AGENT=false       # If true, Phase 9 (services/agent) is skipped
DESTROY_ONLY=false     # If true, teardown runs but build() does not

# ── Argument parsing ──────────────────────────────────────────────────────────
# Simple positional flag parsing. No getopt dependency — keeps the script
# self-contained on minimal Linux installs.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-webserver)
      SKIP_WEBSERVER=true
      shift
      ;;
    --skip-keycloak)
      # Keycloak is a prerequisite for the agent (OIDC token validation).
      # Skipping Keycloak therefore forces --skip-agent as well.
      SKIP_KEYCLOAK=true
      SKIP_AGENT=true
      shift
      ;;
    --skip-agent)
      SKIP_AGENT=true
      shift
      ;;
    --base-dir)
      if [[ $# -lt 2 ]]; then
        error "--base-dir requires a path argument"
        exit 1
      fi
      ARMORY_BASE_DIR="$2"
      DEPLOY_DIR="$ARMORY_BASE_DIR"
      shift 2
      ;;
    --base-dir=*)
      ARMORY_BASE_DIR="${1#*=}"
      DEPLOY_DIR="$ARMORY_BASE_DIR"
      shift
      ;;
    --destroy-only)
      DESTROY_ONLY=true
      shift
      ;;
    --help|-h)
      # Print the usage block at the top of this file and exit cleanly.
      sed -n '2,80p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# =============================================================================
# PREREQUISITE CHECK
# =============================================================================
# Verifies that the two required binaries are on PATH before attempting any
# work. Failing early with a clear message is friendlier than watching a phase
# fail midway through with a cryptic "command not found" error.
# =============================================================================

check_prereqs() {
  local missing=0

  for cmd in tofu podman; do
    if ! command -v "$cmd" &>/dev/null; then
      error "Required tool not found on PATH: $cmd"
      missing=1
    fi
  done

  # Exit if anything is missing. Using a flag + single exit avoids reporting
  # only the first missing binary when multiple are absent.
  [[ $missing -eq 0 ]] || exit 1
}

# =============================================================================
# VAULT CREDENTIAL HELPERS
# =============================================================================
# These functions read the unseal key and root token from the credentials file
# written by the key ceremony in Phase 2. They are used by the teardown phase
# to re-unseal a sealed Vault before running tofu destroy, and to export the
# root token as TF_VAR_vault_token for Vault-backed tofu modules.
#
# The credential file is written in the exact format produced by
# `bao operator init`, which looks like:
#
#   Unseal Key 1: *****************
#   Initial Root Token: *****************
#
# grep -oP uses Perl-compatible regex with \K (lookbehind shorthand) to
# return only the value after the prefix, not the prefix itself.
# =============================================================================

# saved_unseal_key: prints the first unseal key from the credentials file,
# or prints nothing (and returns 0) if the file does not exist or has no key.
# The `|| true` prevents set -e from aborting when grep finds no match.
saved_unseal_key() {
  grep -oP 'Unseal Key \d+: \K\S+' "$CREDS_FILE" 2>/dev/null | head -1 || true
}

# saved_root_token: prints the root token from the credentials file, or
# prints nothing if the file is absent or unparseable.
saved_root_token() {
  grep -oP 'Initial Root Token: \K\S+' "$CREDS_FILE" 2>/dev/null | head -1 || true
}

# =============================================================================
# VAULT READINESS HELPERS
# =============================================================================

# wait_for_vault: polls the Vault /v1/sys/health endpoint until it returns
# any HTTP code that indicates the API is accepting connections.
#
# The health endpoint returns different HTTP codes depending on Vault's state:
#
#   200  Initialized, unsealed, active — normal operating state.
#   429  Standby node (HA mode) — API is up but not the active node.
#   472  Disaster Recovery replication secondary.
#   473  Performance standby.
#   501  Uninitialized — this is the expected state immediately after the
#        container starts, BEFORE bao operator init is run (Phase 2).
#   503  Sealed — Vault has been initialized but not yet unsealed.
#
# All of these codes mean the HTTP server is running and listening. The
# function therefore accepts all of them as "reachable." Distinguishing
# between sealed/unsealed happens elsewhere (vault_is_sealed / vault_is_uninit).
#
# The CA cert at $DEPLOY_DIR/vault/tls/ca.crt is a self-signed cert written
# by the vault/ tofu module. curl needs it to verify the TLS connection.
# -sk would suppress errors but also skip verification; --cacert is correct.
wait_for_vault() {
  local max_attempts="${1:-30}"   # Default: 30 attempts × 1 second = 30 seconds
  local attempt=0

  log "Waiting for Vault to become reachable..."
  until curl -sk --cacert "$DEPLOY_DIR/vault/tls/ca.crt" \
        https://127.0.0.1:8200/v1/sys/health \
        -o /dev/null -w "%{http_code}" 2>/dev/null \
        | grep -qE '^(200|429|472|473|501|503)$'; do

    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      error "Vault did not become reachable after ${max_attempts}s"
      return 1
    fi
    sleep 1
  done

  success "Vault is reachable"
}

# vault_is_sealed: returns exit code 0 (true) if Vault is sealed (HTTP 503),
# non-zero otherwise. Used to decide whether to unseal before tofu destroy.
vault_is_sealed() {
  local code
  code=$(curl -sk --cacert "$DEPLOY_DIR/vault/tls/ca.crt" \
         https://127.0.0.1:8200/v1/sys/health \
         -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  [[ "$code" == "503" ]]
}

# vault_is_uninit: returns exit code 0 (true) if Vault has never been
# initialized (HTTP 501). An uninitialised Vault has no token and no PKI
# hierarchy, so tofu destroy for Vault-backed modules would always fail.
# The teardown skips those modules when this is the case.
vault_is_uninit() {
  local code
  code=$(curl -sk --cacert "$DEPLOY_DIR/vault/tls/ca.crt" \
         https://127.0.0.1:8200/v1/sys/health \
         -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  [[ "$code" == "501" ]]
}

# try_unseal_vault: reads the saved unseal key and submits it to Vault.
# Called during teardown when the Vault container is running but sealed.
# If Vault is sealed, tofu destroy for vault-config and the services modules
# will fail because they make Vault API calls to revoke AppRole credentials,
# delete PKI mounts, etc.
try_unseal_vault() {
  local key
  key=$(saved_unseal_key)

  if [[ -z "$key" ]]; then
    warn "No saved unseal key found in $CREDS_FILE — Vault cannot be unsealed automatically"
    return 1
  fi

  log "Unsealing Vault with saved key..."
  # Suppress the verbose `bao operator unseal` output (it just echoes the key
  # back). Errors will still surface because of set -e in the subshell.
  podman exec armory-vault bao operator unseal "$key" >/dev/null

  # Give Vault 2 seconds to complete the unseal transition. The API may
  # briefly return 503 immediately after receiving the key.
  sleep 2

  if vault_is_sealed; then
    error "Vault is still sealed after unseal attempt"
    return 1
  fi

  success "Vault unsealed"
}

# =============================================================================
# POSTGRES READINESS HELPER
# =============================================================================
# wait_for_postgres: a two-stage readiness gate that must pass before Phase 5b
# (vault-config re-apply with database_roles_enabled=true) can run.
#
# Stage 1 — Host-side health check:
#   Polls the Docker/Podman container health status for armory-postgres until
#   it reports "healthy". The healthcheck in the compose template runs
#   `pg_isready -U postgres` every 5 seconds. PostgreSQL starts late because
#   the Vault Agent sidecar must first authenticate to Vault, render the TLS
#   certificate to disk, and become healthy before the postgres container's
#   depends_on condition is satisfied. This can take 60–90 seconds on a
#   cold pull.
#
# Stage 2 — Vault-side DNS resolution check:
#   Even after the container is healthy on the host, Vault (running inside
#   its own container on armory-net) must be able to resolve the hostname
#   "armory-postgres". Podman's internal DNS only propagates the name once
#   the container is connected to the network. This stage runs
#   `getent hosts armory-postgres` inside the Vault container and retries
#   until it succeeds or times out.
#
#   Without this gate, Phase 5b fails with:
#     "hostname resolving error: lookup armory-postgres ... no such host"
#   because Vault's database secrets engine tries to open a TCP connection
#   to armory-postgres:5432 immediately when the static role is created.
# =============================================================================

wait_for_postgres() {
  local max_attempts="${1:-120}"  # 120 × 2 seconds = 4 minutes maximum wait
  local attempt=0

  log "Waiting for armory-postgres container to become healthy..."
  log "(This can take 60–90s on first start while Vault Agent renders the TLS cert)"

  until [[ "$(podman inspect armory-postgres \
               --format '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]]; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $max_attempts ]]; then
      error "armory-postgres did not become healthy after $(( max_attempts * 2 ))s"
      # Print the last 20 log lines from the postgres container to help diagnose
      # whether the failure is in the Vault Agent sidecar (cert rendering) or
      # in PostgreSQL itself (init.sql error, permission problem, etc.).
      log "Last 20 lines from armory-postgres (if running):"
      podman logs armory-postgres --tail 20 2>/dev/null || true
      log "Last 20 lines from armory-postgres-vault-agent (if running):"
      podman logs armory-postgres-vault-agent --tail 20 2>/dev/null || true
      return 1
    fi
    sleep 2
  done

  success "armory-postgres is healthy"

  # Stage 2: verify DNS resolution from inside the Vault container.
  # armory-vault runs on armory-net and resolves peer hostnames via Podman's
  # internal DNS. `getent hosts` performs a forward lookup — if it returns a
  # line with an IP address, Vault can reach the container.
  log "Verifying armory-postgres is resolvable from inside the Vault container..."
  attempt=0

  until podman exec armory-vault sh -c "getent hosts armory-postgres" >/dev/null 2>&1; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge 30 ]]; then
      error "armory-postgres is not resolvable from inside armory-vault after 60s"
      return 1
    fi
    sleep 2
  done

  success "armory-postgres is resolvable and reachable from armory-vault"
}

# =============================================================================
# OPENTOFU HELPERS
# =============================================================================

# destroy_module: runs `tofu destroy -auto-approve` in the given module
# directory. Extra -var flags can be passed as additional arguments (e.g.,
# destroy_module "vault-config" -var agent_enabled=true).
#
# Skips gracefully if no terraform.tfstate file is present — this means the
# module was never applied (or was already destroyed), so there is nothing
# to clean up.
#
# The `|| warn` at the end means a destroy failure is treated as a warning,
# not a fatal error. This is intentional: during a rebuild, the destroy may
# fail if Vault is unreachable (e.g., the container crashed), but we still
# want to proceed with the rest of the teardown and wipe the state manually.
destroy_module() {
  local dir="$1"; shift
  # Collect any extra -var flags into an array. "$@" expands to nothing if no
  # extra arguments were passed, which is correct — tofu destroy needs no
  # extra vars for modules with no Vault resources.
  local extra_vars=("$@")

  if [[ ! -f "$SCRIPT_DIR/$dir/terraform.tfstate" ]]; then
    warn "No tfstate for $dir — skipping destroy (module was never applied or already destroyed)"
    return 0
  fi

  log "Destroying $dir ..."
  (
    cd "$SCRIPT_DIR/$dir"
    # Prefix every line of tofu output with the module name so it is easy to
    # identify which module produced a given log line in a long terminal session.
    tofu destroy -auto-approve "${extra_vars[@]}" 2>&1 \
      | sed "s/^/  [${dir}] /"
  ) || warn "tofu destroy for $dir reported errors (continuing with teardown)"

  success "Destroyed $dir"
}

# ensure_tfvars: copies example.tfvars → terraform.tfvars in the given module
# directory if terraform.tfvars does not already exist.
#
# All modules ship with an example.tfvars that contains production-safe defaults
# for a local demo environment. Some modules (vault, vault-config, webserver,
# postgres) already have a committed terraform.tfvars. Others (keycloak, agent)
# do not — they are generated here on first run so the operator can inspect and
# customise them before (or after) the initial deployment.
ensure_tfvars() {
  local dir="$1"
  local path="$SCRIPT_DIR/$dir/terraform.tfvars"

  if [[ ! -f "$path" ]]; then
    log "Copying example.tfvars → terraform.tfvars for $dir"
    cp "$SCRIPT_DIR/$dir/example.tfvars" "$path"
  fi
}

# =============================================================================
# TEARDOWN
# =============================================================================
# Destroys the entire stack in reverse dependency order, then cleans up all
# host-side artefacts. The goal is to leave the machine in exactly the same
# state it was in before the very first deployment.
#
# Destroy order (reverse of deploy):
#   services/agent    — depends on vault-config AppRole and Vault Agent
#   services/keycloak — depends on vault-config PKI (pki_ext) and DB roles
#   services/webserver — depends on vault-config PKI (pki_ext) and AppRole
#   vault-config      — depends on a running, unsealed Vault
#   services/postgres — has Vault resources (AppRole, policy) despite what the
#                       README says; must come after vault-config destroy so
#                       the AppRole backend is still available for revocation
#   vault             — last; stopping the container ends the Vault API
#
# After tofu destroy, these additional cleanups run unconditionally:
#   1. Bring down all compose stacks FIRST (before tofu destroy) — handles
#      the depends_on graph so vault-agent sidecars are removed in the right
#      order, avoiding the "has dependent containers" error from podman rm -f.
#   2. Force-remove any remaining armory-* containers (catches stragglers that
#      compose down or tofu destroy may have missed).
#   3. Remove the armory-net Podman network.
#   4. Purge /opt/armory (TLS material, Raft data, pgdata, rendered configs).
#   5. Wipe all terraform.tfstate files so the next apply starts clean.
# =============================================================================

teardown() {
  header "TEARDOWN — Destroying all modules"

  # ── Step 1: Bring down all compose stacks before anything else ────────────
  # This MUST be the first teardown action.
  #
  # Root cause of a subtle failure mode we discovered:
  #   Vault Agent sidecar containers (e.g. armory-postgres-vault-agent) have
  #   `depends_on` relationships with their sibling service containers
  #   (armory-postgres). Podman enforces this dependency graph even during
  #   forced removal: `podman rm -f armory-postgres-vault-agent` exits 125
  #   with "has dependent containers which must be removed before it."
  #
  #   The subsequent `|| true` in the force-remove step silently swallows
  #   that error, leaving the sidecar alive. On the next `podman compose up`,
  #   the existing sidecar container is reused. But its bind-mount for
  #   /vault/certs was established against the directory inode that existed at
  #   creation time. After teardown purged /opt/armory and the build recreated
  #   the directory, the sidecar is still pointing at the old (now-unlinked)
  #   inode. Files written by the agent go into that deleted directory, are
  #   invisible on the host, and the postgres container's awk entrypoint prints
  #   "No such file or directory" forever, causing the health check to never
  #   pass.
  #
  # `podman compose down` handles the dependency graph correctly: it stops and
  # removes the main service container before removing the sidecar. Running it
  # here (before tofu destroy) guarantees all containers are gone before we
  # purge /opt/armory or wipe tfstate.
  #
  # We iterate over all known compose project locations. Missing compose files
  # are skipped silently — a project that was never deployed has nothing to
  # bring down.
  log "Bringing down all compose stacks (handles depends_on ordering)..."
  local compose_projects=(
    "vault:$DEPLOY_DIR/vault/compose.yml"
    "webserver:$DEPLOY_DIR/webserver/compose.yml"
    "postgres:$DEPLOY_DIR/postgres/compose.yml"
    "keycloak:$DEPLOY_DIR/keycloak/compose.yml"
  )

  for entry in "${compose_projects[@]}"; do
    local name="${entry%%:*}"
    local compose_file="${entry##*:}"
    if [[ -f "$compose_file" ]]; then
      log "  podman compose down for $name ($compose_file)..."
      podman compose -f "$compose_file" down --timeout 10 2>/dev/null || true
    else
      log "  No compose file for $name — skipping"
    fi
  done
  success "Compose stacks brought down"

  # ── Step 3: Surface a valid Vault root token ──────────────────────────────
  # Most modules have Vault resources (policies, AppRoles, PKI roles) and
  # therefore need a Vault token for both apply and destroy. We read the token
  # that was saved during the last key ceremony from the credentials file and
  # export it as TF_VAR_vault_token so all subshell tofu invocations inherit it.
  local vault_token
  vault_token=$(saved_root_token)

  if [[ -n "$vault_token" ]]; then
    export TF_VAR_vault_token="$vault_token"
    log "Root token loaded from $CREDS_FILE"
  else
    warn "No saved root token found in $CREDS_FILE"
    warn "Vault-backed module destroys may fail. Continuing anyway."
  fi

  # ── Step 4: Ensure Vault is accessible for tofu destroy ───────────────────
  # tofu destroy for vault-config and the services modules makes live Vault API
  # calls to revoke credentials, delete mounts, etc. For those calls to
  # succeed, the Vault container must be running AND unsealed.
  #
  # Three possible states we handle here:
  #   a) Container not found  — warn and continue (destroy will fail for
  #                              Vault-backed modules, which is acceptable
  #                              because we wipe tfstate at the end anyway).
  #   b) Container running, sealed — try to unseal with the saved key.
  #   c) Container running, uninitialised — no token exists, no API operations
  #                                         are possible; skip Vault-backed modules.
  local vault_running=false

  if podman inspect armory-vault &>/dev/null 2>&1; then
    vault_running=true
    if vault_is_sealed; then
      log "Vault container is running but sealed — attempting to unseal with saved key"
      try_unseal_vault || vault_running=false
    elif vault_is_uninit; then
      warn "Vault container is running but uninitialized — no token available"
      warn "Skipping Vault-backed module destroys"
      vault_running=false
    else
      log "Vault container is running and unsealed — ready for destroy"
    fi
  else
    warn "armory-vault container not found — Vault-backed tofu destroys will likely fail"
    warn "The tfstate wipe at the end of teardown will still clean up local state"
  fi

  # ── Step 5: Destroy modules in reverse dependency order ───────────────────

  # services/agent — AppRole credentials in Vault; Vault Agent sidecar config
  # on disk. Must be destroyed before vault-config removes the AppRole backend.
  if [[ "$SKIP_AGENT" == "false" ]]; then
    destroy_module "services/agent" \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      -var deploy_dir="$DEPLOY_DIR/agent"
  else
    log "Skipping services/agent destroy (--skip-agent was passed)"
  fi

  # services/keycloak — AppRole credentials, PKI certificate from pki_ext,
  # and static DB credentials via the database secrets engine. Must be
  # destroyed before vault-config removes those backends.
  if [[ "$SKIP_KEYCLOAK" == "false" ]]; then
    destroy_module "services/keycloak" \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      -var deploy_dir="$DEPLOY_DIR/keycloak"
  else
    log "Skipping services/keycloak destroy (--skip-keycloak was passed)"
  fi

  # services/webserver — AppRole credentials and PKI certificate from pki_ext.
  # Same dependency on vault-config backends as keycloak.
  if [[ "$SKIP_WEBSERVER" == "false" ]]; then
    destroy_module "services/webserver" \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      -var deploy_dir="$DEPLOY_DIR/webserver"
  else
    log "Skipping services/webserver destroy (--skip-webserver was passed)"
  fi

  # vault-config — PKI mounts (pki, pki_int, pki_ext), AppRole auth method,
  # userpass auth method, ACL policies, KV v2 engine, Database secrets engine.
  # This module can only be destroyed when Vault is running and unsealed; we
  # pass agent_enabled and database_roles_enabled so tofu knows which optional
  # resources exist in state and need to be deleted.
  if [[ "$vault_running" == "true" && -n "$vault_token" ]]; then
    destroy_module "vault-config" \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      -var agent_enabled=true \
      -var database_roles_enabled=true
  else
    warn "Skipping vault-config destroy — Vault is not accessible"
  fi

  # services/postgres — despite the README stating "no Vault resources",
  # this module DOES have Vault resources: vault_policy.postgres,
  # vault_approle_auth_backend_role.postgres, and the wrapped secret_id.
  # These are destroyed here; the compose teardown also runs the destroy
  # provisioner to `podman compose down` the postgres containers.
  destroy_module "services/postgres" \
    -var armory_base_dir="$ARMORY_BASE_DIR" \
    -var deploy_dir="$DEPLOY_DIR/postgres"

  # vault — destroyed last because every other module's destroy provisioner
  # or Vault API call depends on it being available. The vault tofu module's
  # destroy provisioner runs `podman compose down` which stops and removes
  # the armory-vault container.
  destroy_module "vault" \
    -var deploy_dir="$DEPLOY_DIR/vault"

  # ── Step 6: Force-remove any lingering armory containers ──────────────────
  # Even after tofu destroy, containers may still be running if:
  #   - The compose down failed (e.g., the compose file was already deleted)
  #   - Containers were started manually outside of tofu
  #   - A previous rebuild attempt left containers behind
  # We use `podman ps -a` (not just `ps`) to also catch stopped containers
  # that would block a fresh `podman compose up` from reusing their names.
  log "Force-removing any lingering armory-* containers..."
  local containers
  containers=$(podman ps -a --format '{{.Names}}' 2>/dev/null \
               | grep -E '^armory-' || true)

  if [[ -n "$containers" ]]; then
    # xargs -r: only run podman rm if there is input (prevents "podman rm"
    # with no arguments, which would print a usage error).
    echo "$containers" | xargs -r podman rm -f 2>/dev/null || true
    success "Removed containers: $(echo "$containers" | tr '\n' ' ')"
  else
    log "No lingering armory-* containers found"
  fi

  # ── Step 7: Remove the Podman network ─────────────────────────────────────
  # armory-net is created by the vault/ compose stack as a named bridge
  # network. After the containers are gone we remove it explicitly so the
  # next deployment creates it fresh (avoids stale IP range conflicts).
  if podman network exists armory-net 2>/dev/null; then
    log "Removing Podman network armory-net..."
    podman network rm armory-net 2>/dev/null || true
    success "Removed armory-net"
  else
    log "armory-net network not found — nothing to remove"
  fi

  # ── Step 7b: Remove all Podman volumes ───────────────────────────────────
  # Remove all local Podman-managed volumes to guarantee no leftover data
  # survives between rebuilds.
  log "Removing all Podman volumes..."
  local volumes
  volumes=$(podman volume ls -q 2>/dev/null || true)

  if [[ -n "$volumes" ]]; then
    echo "$volumes" | xargs -r podman volume rm -f 2>/dev/null || true
    success "Removed Podman volumes"
  else
    log "No Podman volumes found — nothing to remove"
  fi

  # ── Step 8: Purge /opt/armory ─────────────────────────────────────────────
  # This directory contains all runtime artefacts: Vault Raft storage, TLS
  # key material, PostgreSQL pgdata, rendered compose files, AppRole
  # credential files, Vault Agent configs, and audit logs.
  # sudo is required because some subdirectories (particularly pgdata) are
  # owned by container-namespace UIDs (e.g., UID 70 for the Alpine postgres
  # user) that the host user cannot remove without privilege escalation.
  if [[ -d "$DEPLOY_DIR" ]]; then
    log "Purging $DEPLOY_DIR (requires sudo for container-owned subdirs)..."
    sudo rm -rf "$DEPLOY_DIR"
    success "Removed $DEPLOY_DIR"
  else
    log "$DEPLOY_DIR does not exist — nothing to purge"
  fi

  # ── Step 9: Wipe all terraform.tfstate files ──────────────────────────────
  # This is the most important cleanup step for ensuring a clean rebuild.
  #
  # The problem with stale tfstate:
  #   null_resource provisioners (used in every module to run `podman compose
  #   up -d`) are governed by a triggers map that typically contains the SHA256
  #   hash of the compose file content. If the content hash in the existing
  #   tfstate matches the hash of the newly-rendered compose file, OpenTofu
  #   considers the null_resource unchanged and SKIPS the provisioner
  #   entirely — meaning `podman compose up` never runs and the containers
  #   are never started. This produces a confusing "apply succeeded" with no
  #   containers running.
  #
  # By deleting the state files we force OpenTofu to treat every resource as
  # new on the next apply, guaranteeing the provisioners always execute.
  #
  # -maxdepth 3 limits the search to module directories (one level below
  # the project root) and prevents descending into .terraform/ provider caches
  # which also contain state-like files but must not be deleted.
  log "Wiping terraform.tfstate files to ensure a fully clean rebuild..."
  find "$SCRIPT_DIR" -maxdepth 3 -name "terraform.tfstate*" \
    -not -path "*/.terraform/*" -delete 2>/dev/null || true
  success "terraform.tfstate files removed"

  # ── Step 10: Remove .terraform dirs and all terraform.tfvars files ─────────────────
  # Aggressive local cleanup for a fully fresh init/apply:
  #   - Removes provider/plugin/module caches under every .terraform directory
  #   - Removes all terraform.tfvars files
  log "Removing all .terraform directories..."
  find "$SCRIPT_DIR" -type d -name ".terraform" -prune -exec rm -rf {} + 2>/dev/null || true
  success ".terraform directories removed"

  log "Removing all terraform.tfvars files..."
  find "$SCRIPT_DIR" -type f -name "terraform.tfvars" -delete 2>/dev/null || true
  success "terraform.tfvars files removed"

  log "Removing all .terraform.tfstate.lock.info files..."
  find "$SCRIPT_DIR" -type f -name ".terraform.tfstate.lock.info" -delete 2>/dev/null || true
  success ".terraform.tfstate.lock.info files removed"

  success "Teardown complete"
}

# =============================================================================
# BUILD
# =============================================================================
# Applies all modules in dependency order. Each phase is a discrete step that
# produces artefacts consumed by subsequent phases.
# =============================================================================

build() {

  # ── Phase 0: Host prerequisite ─────────────────────────────────────────────
  # /opt/armory must exist and be owned by the current user before any tofu
  # module runs. The modules write files here directly (via local_file
  # resources and null_resource provisioners), and rootless Podman mounts
  # subdirectories into containers using bind mounts — both require the
  # directory to be writable by the host user without sudo.
  #
  # The `chown $USER:$USER` is important: sudo mkdir creates the directory
  # owned by root, and subsequent tofu apply operations (running as the host
  # user) would fail to create subdirectories or write files.
  header "PHASE 0 — Host prerequisites"
  log "Creating $DEPLOY_DIR and setting ownership to $USER..."
  sudo mkdir -p "$DEPLOY_DIR"
  sudo chown "$USER:$USER" "$DEPLOY_DIR"
  success "$DEPLOY_DIR ready"

  # ── Phase 1: Deploy Vault ───────────────────────────────────────────────────
  # The vault/ module is the foundation of the entire stack. It:
  #   - Generates a self-signed CA certificate and server TLS certificate
  #     using the OpenTofu `tls` provider (no external CA required).
  #   - Writes vault.hcl (Raft storage, TLS config, listener block).
  #   - Generates the compose.yml for the armory-vault container.
  #   - Starts the container via `podman compose up -d`.
  #
  # After this phase, Vault is running but uninitialized (HTTP 501). The key
  # ceremony in Phase 2 initialises and unseals it.
  #
  # Note: this module does NOT require TF_VAR_vault_token — it uses only the
  # `tls`, `local`, and `null` providers. TF_VAR_vault_token is not yet
  # available at this point anyway (it is captured in Phase 2).
  header "PHASE 1 — Deploy Vault"
  ensure_tfvars "vault"
  (
    cd "$SCRIPT_DIR/vault"
    log "Initialising OpenTofu providers for vault/..."
    tofu init -upgrade 2>&1 | sed 's/^/  [vault] /'
    log "Applying vault/ module..."
    tofu apply -auto-approve \
      -var deploy_dir="$DEPLOY_DIR/vault" \
      2>&1 | sed 's/^/  [vault] /'
  )
  success "Vault container deployed"

  # ── Phase 2: Key ceremony (init + unseal) ───────────────────────────────────
  # This is the most critical phase. The output of `bao operator init` produces
  # the ONLY copy of the unseal key and root token — they are never stored
  # inside Vault itself. Losing them means the Vault data is permanently
  # inaccessible.
  #
  # We use a 1-of-1 key share / threshold configuration (single unseal key,
  # single share required to unseal) which is appropriate for a local demo
  # environment. Production deployments should use a higher threshold (e.g.,
  # 3-of-5) and distribute shares to separate key custodians.
  #
  # The key ceremony output is saved verbatim to $CREDS_FILE so teardown can
  # re-unseal Vault on subsequent runs without human interaction.
  #
  # SECURITY NOTE: The credentials file is gitignored but lives on disk in
  # plaintext. Do not use this approach on shared hosts or in CI. See ADR-012.
  header "PHASE 2 — Key ceremony (init + unseal)"

  # Wait for Vault's HTTP API to accept connections before running init.
  # The container may take 5–15 seconds to start listening. We allow up to
  # 60 seconds to accommodate slow pulls or slow container runtimes.
  wait_for_vault 60

  log "Running bao operator init (1-of-1 key shares)..."
  local init_output
  init_output=$(podman exec armory-vault bao operator init \
    -key-shares=1 -key-threshold=1 2>&1)

  # Write the raw init output to the credentials file, prepended with a
  # timestamp header. The grep-based parsers (saved_unseal_key,
  # saved_root_token) work directly on this format.
  {
    echo "# Generated by rebuild.sh on $(date)"
    echo "# DO NOT COMMIT — this file is gitignored"
    echo ""
    echo "$init_output"
  } > "$CREDS_FILE"
  success "Credentials saved to $CREDS_FILE"

  # Parse the unseal key and root token from the init output.
  # If either is empty, the init command produced unexpected output (e.g.,
  # Vault was already initialized from a prior run) — abort with diagnostics.
  local UNSEAL_KEY ROOT_TOKEN
  UNSEAL_KEY=$(echo "$init_output" | grep -oP 'Unseal Key \d+: \K\S+' | head -1)
  ROOT_TOKEN=$(echo "$init_output"  | grep -oP 'Initial Root Token: \K\S+'  | head -1)

  if [[ -z "$UNSEAL_KEY" || -z "$ROOT_TOKEN" ]]; then
    error "Failed to parse unseal key or root token from init output."
    error "Full init output follows:"
    echo "$init_output"
    exit 1
  fi

  log "Unsealing Vault..."
  podman exec armory-vault bao operator unseal "$UNSEAL_KEY"

  # Brief pause to allow Vault to complete the unseal transition internally
  # before we query the health endpoint.
  sleep 2

  if vault_is_sealed; then
    error "Vault is still sealed after unseal attempt — something is wrong"
    exit 1
  fi

  success "Vault unsealed and ready"

  # Export the root token as TF_VAR_vault_token. All subsequent tofu modules
  # (vault-config and every service module) reference this environment variable
  # in their vault provider configuration. Exporting at the function level
  # makes it available to all subshells spawned by build() for the rest of
  # this script's execution.
  export TF_VAR_vault_token="$ROOT_TOKEN"
  log "Root token exported as TF_VAR_vault_token"

  # ── Phase 3: Configure Vault ────────────────────────────────────────────────
  # The vault-config/ module builds the entire logical configuration on top of
  # the running Vault instance. It applies in a single `tofu apply` pass:
  #
  #   PKI hierarchy:
  #     pki/         Root CA (10-year, ECDSA P-384, no direct leaf issuance)
  #     pki_int/     Internal intermediate CA (5-year, signs *.armory.internal)
  #     pki_ext/     External intermediate CA (5-year, signs external services)
  #
  #   Auth methods:
  #     AppRole      Used by Vault Agent sidecars in every service
  #     userpass     Human operator account (password: armory-demo-2026)
  #     OIDC stub    Disabled by default; enabled in Phase 8 after Keycloak
  #
  #   ACL policies:
  #     One policy per service, granting least-privilege access to its PKI
  #     role, database credential path, or KV path.
  #
  #   Secrets engines:
  #     kv/          KV v2 — stores the Keycloak admin bootstrap credentials
  #     database/    Database secrets engine — connection to armory-postgres
  #                  (roles are NOT created here; see Phase 5b)
  #
  # The `vault/ca-bundle.pem` output file is written to the project repo
  # directory (not /opt/armory). It covers all three PKI CAs and is used by
  # curl, browsers, and the bao CLI to trust certificates issued by any of
  # the three PKI mounts.
  header "PHASE 3 — Configure Vault (PKI, auth, policies, KV, DB engine)"
  ensure_tfvars "vault-config"
  (
    cd "$SCRIPT_DIR/vault-config"
    log "Initialising OpenTofu providers for vault-config/..."
    tofu init -upgrade 2>&1 | sed 's/^/  [vault-config] /'
    log "Applying vault-config/ module (PKI, auth, policies, KV, DB connection)..."
    tofu apply -auto-approve \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      2>&1 | sed 's/^/  [vault-config] /'
  )
  success "Vault configured: PKI hierarchy, auth methods, policies, KV, and DB engine ready"

  # ── Phase 4: Deploy webserver (optional) ────────────────────────────────────
  # The webserver service is a demonstration of the Vault Agent sidecar pattern
  # applied to a public-facing service. It consists of:
  #   - An nginx container serving HTTPS on port 8443.
  #   - A Vault Agent sidecar that authenticates via AppRole, fetches a TLS
  #     certificate from pki_ext, and renders it to disk. nginx does not start
  #     until the Agent healthcheck confirms the cert is present.
  #   - Automatic certificate rotation: the Agent re-renders a new cert before
  #     the current one expires (configurable TTL, default 720h).
  #
  # This phase is optional (--skip-webserver) if you only need the core
  # vault/postgres/keycloak stack.
  if [[ "$SKIP_WEBSERVER" == "false" ]]; then
    header "PHASE 4 — Deploy webserver (nginx + Vault Agent TLS sidecar)"
    ensure_tfvars "services/webserver"
    (
      cd "$SCRIPT_DIR/services/webserver"
      log "Initialising OpenTofu providers for services/webserver/..."
      tofu init -upgrade 2>&1 | sed 's/^/  [webserver] /'
      log "Applying services/webserver/ module..."
      tofu apply -auto-approve \
        -var armory_base_dir="$ARMORY_BASE_DIR" \
        -var deploy_dir="$DEPLOY_DIR/webserver" \
        2>&1 | sed 's/^/  [webserver] /'
    )
    success "Webserver deployed — reachable at https://127.0.0.1:8443"
  else
    warn "Skipping Phase 4 (webserver) — --skip-webserver flag was passed"
  fi

  # ── Phase 5: Deploy PostgreSQL ──────────────────────────────────────────────
  # The postgres service deploys PostgreSQL 16 with TLS enabled, using a
  # certificate issued by pki_int (the internal intermediate CA). It also
  # creates a Vault Agent sidecar that:
  #   1. Authenticates to Vault via AppRole.
  #   2. Issues a certificate for armory-postgres.armory.internal from pki_int.
  #   3. Writes the combined cert+CA+key PEM to /opt/armory/postgres/certs/.
  #   4. The postgres container's entrypoint splits this PEM into separate
  #      cert and key files before starting the server.
  #
  # The init.sql script (rendered from a template by tofu) creates:
  #   - The `keycloak` database and `keycloak` user
  #   - The `app` database and `app` user
  #   - The `vault_mgmt` superuser used by the Vault Database secrets engine
  #     to rotate passwords and create ephemeral credentials
  #
  # IMPORTANT: After this phase, wait_for_postgres() must confirm that the
  # container is healthy AND resolvable from inside the Vault container before
  # Phase 5b proceeds. The database static/dynamic role creation in Phase 5b
  # requires Vault to open a live TCP connection to armory-postgres:5432.
  header "PHASE 5 — Deploy PostgreSQL"
  ensure_tfvars "services/postgres"
  (
    cd "$SCRIPT_DIR/services/postgres"
    log "Initialising OpenTofu providers for services/postgres/..."
    tofu init -upgrade 2>&1 | sed 's/^/  [postgres] /'
    log "Applying services/postgres/ module..."
    tofu apply -auto-approve \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      -var deploy_dir="$DEPLOY_DIR/postgres" \
      2>&1 | sed 's/^/  [postgres] /'
  )
  success "PostgreSQL deployed"

  # Wait for both the postgres container to be healthy AND for armory-postgres
  # to be resolvable via Podman DNS from inside the Vault container. Phase 5b
  # will fail with a DNS resolution error if we proceed before this gate passes.
  wait_for_postgres

  # ── Phase 5b: Enable Vault database roles ───────────────────────────────────
  # Re-apply vault-config/ with database_roles_enabled=true. This creates:
  #
  #   database/static-roles/keycloak
  #     A static role that maps to the `keycloak` PostgreSQL user. Vault
  #     manages this user's password and rotates it on a schedule. Keycloak's
  #     Vault Agent sidecar reads this credential path to populate
  #     KC_DB_PASSWORD in keycloak.env.
  #
  #   database/roles/app
  #     A dynamic role that creates short-lived `app_*` PostgreSQL users with
  #     SELECT/INSERT/UPDATE/DELETE privileges on the `app` database. The
  #     agentic layer issues these credentials per-task and revokes them on
  #     completion.
  #
  # This must run AFTER Phase 5 (not Phase 3) because Vault immediately
  # attempts to connect to armory-postgres:5432 when the static role is created,
  # to verify credentials and set the initial password. If PostgreSQL is not
  # running and reachable, the Vault API returns a 500 error and tofu fails.
  header "PHASE 5b — Enable Vault database roles (re-apply vault-config)"
  (
    cd "$SCRIPT_DIR/vault-config"
    log "Re-applying vault-config/ with database_roles_enabled=true..."
    tofu apply -auto-approve \
      -var armory_base_dir="$ARMORY_BASE_DIR" \
      -var database_roles_enabled=true \
      2>&1 | sed 's/^/  [vault-config] /'
  )
  success "Vault database roles created: static 'keycloak', dynamic 'app'"

  # ── Phase 6: Deploy Keycloak ────────────────────────────────────────────────
  # Keycloak serves as the OIDC identity provider for the entire stack. Its
  # Vault Agent sidecar renders three files before Keycloak starts:
  #
  #   /opt/armory/keycloak/certs/keycloak.pem
  #     TLS certificate from pki_ext (cert + CA chain + private key in one
  #     PEM). Keycloak is configured to read this combined file for HTTPS.
  #
  #   /opt/armory/keycloak/secrets/keycloak.env
  #     KC_DB_PASSWORD — the current password for the `keycloak` PostgreSQL
  #     user, fetched from database/static-creds/keycloak. Vault Agent
  #     re-renders this file when the static role rotates the password.
  #
  #   /opt/armory/keycloak/secrets/keycloak-admin.env
  #     KC_BOOTSTRAP_ADMIN_USERNAME and KC_BOOTSTRAP_ADMIN_PASSWORD —
  #     the initial admin credentials fetched from kv/data/keycloak/admin.
  #     These are only used on first startup to seed the master realm.
  #
  # After this phase, Keycloak is running on port 8444 with TLS. The admin
  # console is at https://127.0.0.1:8444/admin. However, the armory realm,
  # OIDC clients, and group mappings must be created manually (Phase 7).
  if [[ "$SKIP_KEYCLOAK" == "false" ]]; then
    header "PHASE 6 — Deploy Keycloak (OIDC identity provider)"
    ensure_tfvars "services/keycloak"
    (
      cd "$SCRIPT_DIR/services/keycloak"
      log "Initialising OpenTofu providers for services/keycloak/..."
      tofu init -upgrade 2>&1 | sed 's/^/  [keycloak] /'
      log "Applying services/keycloak/ module..."
      tofu apply -auto-approve \
        -var armory_base_dir="$ARMORY_BASE_DIR" \
        -var deploy_dir="$DEPLOY_DIR/keycloak" \
        2>&1 | sed 's/^/  [keycloak] /'
    )
    success "Keycloak deployed — admin console at https://127.0.0.1:8444/admin"
  else
    warn "Skipping Phase 6 (Keycloak) — --skip-keycloak flag was passed"
  fi

  # ── Phase 9: Deploy the agentic layer ───────────────────────────────────────
  # The agentic layer is a FastAPI application that exposes a task-based API
  # for running SELECT queries against PostgreSQL. It enforces:
  #   - OIDC token validation (Bearer token from Keycloak)
  #   - Group membership check (token must contain 'vault-operators')
  #   - Per-task dynamic database credentials (issued and revoked via Vault)
  #   - SELECT-only enforcement at both parse and execution layers
  #
  # Phase 9 runs in two steps:
  #
  #   Step 1 — Enable the agent AppRole in vault-config/:
  #     Re-apply vault-config/ with agent_enabled=true (and
  #     database_roles_enabled=true to preserve the existing db roles).
  #     This creates the `agent` AppRole and the `agent` ACL policy.
  #
  #   Step 2 — Apply services/agent/:
  #     Writes role_id and a response-wrapped secret_id to
  #     /opt/armory/agent/approle/. The secret_id is single-use — the FastAPI
  #     application unwraps it on first startup to obtain the actual secret_id
  #     and exchanges it for a Vault token.
  #
  # NOTE: Running the FastAPI server (api.py) is a manual step — see the
  # summary banner printed after this script completes.
  if [[ "$SKIP_AGENT" == "false" ]]; then
    header "PHASE 9 — Deploy agentic layer (AppRole + services/agent module)"

    log "Step 1: Enabling agent AppRole in vault-config (agent_enabled=true)..."
    (
      cd "$SCRIPT_DIR/vault-config"
      # Both vars must be true: agent_enabled creates the agent AppRole;
      # database_roles_enabled prevents tofu from destroying the db roles
      # that were created in Phase 5b (omitting a var reverts it to its
      # default, which is false for both of these).
      tofu apply -auto-approve \
        -var armory_base_dir="$ARMORY_BASE_DIR" \
        -var agent_enabled=true \
        -var database_roles_enabled=true \
        2>&1 | sed 's/^/  [vault-config] /'
    )
    success "Agent AppRole and policy created in Vault"

    log "Step 2: Applying services/agent/ to write AppRole credentials to disk..."
    ensure_tfvars "services/agent"
    (
      cd "$SCRIPT_DIR/services/agent"
      log "Initialising OpenTofu providers for services/agent/..."
      tofu init -upgrade 2>&1 | sed 's/^/  [agent] /'
      log "Applying services/agent/ module..."
      tofu apply -auto-approve \
        -var armory_base_dir="$ARMORY_BASE_DIR" \
        -var deploy_dir="$DEPLOY_DIR/agent" \
        2>&1 | sed 's/^/  [agent] /'
    )
    success "Agent credentials written to $DEPLOY_DIR/agent/approle/"
    log "  role_id and wrapped_secret_id are ready for api.py"
  else
    warn "Skipping Phase 9 (agent) — --skip-agent or --skip-keycloak flag was passed"
  fi
}

# =============================================================================
# POST-BUILD SUMMARY
# =============================================================================
# Prints a human-readable summary of what was deployed, where to reach each
# service, which CA certificates to trust, and what manual steps remain.
# =============================================================================

print_summary() {
  header "BUILD COMPLETE"

  echo -e "${GREEN}Vault credentials saved to:${RESET} $CREDS_FILE"
  echo -e "${YELLOW}Keep this file safe. Losing the unseal key means Vault cannot be unsealed after a restart.${RESET}"
  echo ""

  echo -e "${BOLD}Deployed services:${RESET}"
  echo "  Vault UI      : https://127.0.0.1:8200/ui"
  [[ "$SKIP_WEBSERVER" == "false" ]] && \
    echo "  nginx         : https://127.0.0.1:8443   (Vault Agent TLS sidecar demo)"
  echo "  PostgreSQL    : 127.0.0.1:5432             (internal; use psql or a client)"
  [[ "$SKIP_KEYCLOAK"  == "false" ]] && \
    echo "  Keycloak      : https://127.0.0.1:8444/admin"
  echo ""

  echo -e "${BOLD}CA certificates — BOTH must be trusted for full connectivity:${RESET}"
  echo "  $DEPLOY_DIR/vault/tls/ca.crt"
  echo "    Covers: Vault server TLS only (self-signed by OpenTofu tls provider)"
  echo "  $SCRIPT_DIR/vault/ca-bundle.pem"
  echo "    Covers: all PKI-issued certs — Keycloak, nginx, agent, PostgreSQL"
  echo ""
  echo "  To trust both on Fedora/RHEL:"
  echo "    sudo cp $DEPLOY_DIR/vault/tls/ca.crt \\"
  echo "         /etc/pki/ca-trust/source/anchors/armory-vault-ca.crt"
  echo "    sudo cp $SCRIPT_DIR/vault/ca-bundle.pem \\"
  echo "         /etc/pki/ca-trust/source/anchors/armory-ca-bundle.crt"
  echo "    sudo update-ca-trust"
  echo ""

  echo -e "${YELLOW}Manual steps still required:${RESET}"

  if [[ "$SKIP_KEYCLOAK" == "false" ]]; then
    echo ""
    echo "  Phase 7 — Configure the Keycloak 'armory' realm (browser-based):"
    echo "    1. Log in to https://127.0.0.1:8444/admin"
    echo "    2. Create realm: armory"
    echo "    3. Create group: vault-operators  (add your operator user)"
    echo "    4. Create OIDC client 'vault' (confidential, with Group Membership mapper)"
    echo "    5. Create OIDC client 'agent-cli' (public, PKCE S256, no direct grant)"
    echo "    See README.md Phase 7 for the full step-by-step."
    echo ""
    echo "  Phase 8 — Enable Vault OIDC auth (after Phase 7):"
    echo "    cd vault-config/"
    echo "    export TF_VAR_vault_token=<ROOT_TOKEN_FROM_$CREDS_FILE>"
    echo "    tofu apply \\"
    echo "      -var oidc_enabled=true \\"
    echo "      -var oidc_client_id=vault \\"
    echo "      -var 'oidc_client_secret=<SECRET_FROM_KEYCLOAK_VAULT_CLIENT>'"
  fi

  if [[ "$SKIP_AGENT" == "false" ]]; then
    echo ""
    echo "  Agent API — start the FastAPI server manually:"
    echo "    cd services/agent/agent/"
    echo "    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    echo "    export VAULT_ADDR=https://127.0.0.1:8200"
    echo "    export ARMORY_CACERT=$DEPLOY_DIR/vault/tls/ca.crt"
    echo "    export APPROLE_DIR=$DEPLOY_DIR/agent/approle"
    echo "    export KEYCLOAK_URL=https://127.0.0.1:8444"
    echo "    export OIDC_CLIENT_ID=agent-cli"
    echo "    export POSTGRES_HOST=armory-postgres"
    echo "    export POSTGRES_DB=app"
    echo "    .venv/bin/python api.py"
    echo ""
    echo "  NOTE: The wrapped_secret_id is single-use. Re-run the following"
    echo "  before each cold start of api.py:"
    echo "    cd services/agent/"
    echo "    export TF_VAR_vault_token=<ROOT_TOKEN>"
    echo "    tofu apply -auto-approve"
  fi

  echo ""
  echo -e "${YELLOW}Vault must be manually unsealed after every restart:${RESET}"
  echo "  podman exec armory-vault bao operator unseal <UNSEAL_KEY_FROM_$CREDS_FILE>"
}

# =============================================================================
# MAIN
# =============================================================================
# Entry point. Validates prerequisites, runs teardown, and (unless
# --destroy-only was passed) runs the full build and prints the summary.
# =============================================================================

main() {
  header "PROJECT ARMORY — Full Rebuild"

  log "Script directory : $SCRIPT_DIR"
  log "Deploy directory : $DEPLOY_DIR"
  log "Credentials file : $CREDS_FILE"
  log "Flags            : skip-webserver=$SKIP_WEBSERVER  skip-keycloak=$SKIP_KEYCLOAK  skip-agent=$SKIP_AGENT  destroy-only=$DESTROY_ONLY"

  check_prereqs
  teardown

  if [[ "$DESTROY_ONLY" == "true" ]]; then
    success "Destroy-only run complete — rebuild skipped"
    exit 0
  fi

  build
  print_summary
}

main "$@"
