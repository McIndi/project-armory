"""
Session fixtures: full lifecycle management for Armory integration tests.

vault_env sequence:
  destroy (vault-config/) → destroy (vault/) →
  init (vault/) → init (vault-config/) → apply (vault/) →
  wait → init → unseal → wait → apply (vault-config/) →
  [ tests ] →
  collect logs → teardown (unless ARMORY_NO_TEARDOWN=1)

webserver_env sequence (builds on vault_env):
  apply (services/webserver/) → wait for nginx → [ tests ] → destroy
"""
import json
import os
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).parent.parent
VAULT_MODULE = PROJECT_ROOT / "vault"
VAULT_CONFIG_MODULE = PROJECT_ROOT / "vault-config"
WEBSERVER_MODULE = PROJECT_ROOT / "services" / "webserver"
AGENT_MODULE = PROJECT_ROOT / "services" / "agent"
POSTGRES_MODULE = PROJECT_ROOT / "services" / "postgres"
LOGS_DIR = Path(__file__).parent / "logs"

VAULT_ADDR = "https://127.0.0.1:8200"
VAULT_CACERT = "/opt/armory/vault/tls/ca.crt"

NO_TEARDOWN = os.environ.get("ARMORY_NO_TEARDOWN", "").lower() in ("1", "true", "yes")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run(cmd, cwd=None, env=None, check=True):
    result = subprocess.run(
        cmd, shell=True,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed (exit {result.returncode}): {cmd}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def _vault_status():
    r = _run(
        "podman exec armory-vault bao status -format=json",
        check=False,
    )
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def _wait_for_vault_ready(timeout=90, interval=3):
    """Wait until the Vault API responds with parseable JSON (any seal state)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _vault_status() is not None:
            return
        time.sleep(interval)
    raise TimeoutError("Vault API did not respond within timeout")


def _wait_for_active(timeout=60, interval=3):
    """Wait until Vault is unsealed and active (is_self=true in OpenBao JSON)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = _vault_status()
        if status and not status.get("sealed") and status.get("is_self"):
            return
        time.sleep(interval)
    raise TimeoutError("Vault did not reach active state within timeout")


def _wait_for_postgres(timeout=90, interval=3):
    """Wait until PostgreSQL accepts TCP connections on 127.0.0.1:5432.

    Uses -h 127.0.0.1 to force a TCP check (not the Unix socket), ensuring
    vault-config can connect over the network before we proceed.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = _run(
            "podman exec armory-postgres pg_isready -U postgres -h 127.0.0.1",
            check=False,
        )
        if r.returncode == 0:
            return
        time.sleep(interval)
    raise TimeoutError("PostgreSQL did not become ready within timeout")


def _wait_for_agent_api(timeout=30, interval=2):
    """Wait until the agent API returns 200 on /health."""
    import httpx
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = httpx.get("http://127.0.0.1:8000/health", timeout=2)
            if r.status_code == 200:
                return
        except Exception:
            pass
        time.sleep(interval)
    raise TimeoutError("Agent API did not become reachable within timeout")


def _wait_for_nginx(timeout=60, interval=3):
    """Wait until nginx accepts TCP connections on port 8443."""
    import socket
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", 8443), timeout=2):
                return
        except (ConnectionRefusedError, OSError):
            time.sleep(interval)
    raise TimeoutError("nginx did not become reachable on port 8443 within timeout")


def _collect_logs():
    LOGS_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = LOGS_DIR / f"vault_{timestamp}.log"
    r = subprocess.run(
        "podman logs armory-vault",
        shell=True, capture_output=True, text=True,
    )
    with open(log_path, "w") as f:
        f.write(r.stdout)
        if r.stderr:
            f.write("\n--- STDERR ---\n")
            f.write(r.stderr)
    return log_path


def _collect_webserver_logs():
    LOGS_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    for name in ("armory-webserver", "armory-vault-agent"):
        log_path = LOGS_DIR / f"{name}_{timestamp}.log"
        r = subprocess.run(
            f"podman logs {name}",
            shell=True, capture_output=True, text=True,
        )
        with open(log_path, "w") as f:
            f.write(r.stdout)
            if r.stderr:
                f.write("\n--- STDERR ---\n")
                f.write(r.stderr)


def _check_prerequisites():
    for name, cmd in [("tofu", ["tofu", "version"]), ("podman", ["podman", "--version"])]:
        try:
            r = subprocess.run(cmd, capture_output=True)
            if r.returncode != 0:
                raise RuntimeError(
                    f"'{name}' exited with code {r.returncode}. "
                    "Ensure it is installed and working before running integration tests."
                )
        except FileNotFoundError:
            raise RuntimeError(
                f"'{name}' not found on PATH — install it before running integration tests."
            )


@pytest.fixture(scope="session", autouse=True)
def check_prerequisites():
    _check_prerequisites()


# ---------------------------------------------------------------------------
# Vault session fixture
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def vault_env():
    base_env = os.environ.copy()

    # 1. Destroy any existing state (best-effort).
    #    Use compose down before rm -f to avoid stale bind mounts on re-deploy:
    #    podman rm -f alone can leave containers in zombie state with bind mounts
    #    pointing to deleted directory inodes after rm -rf on the host path.
    _run("podman compose --project-name armory-webserver -f /opt/armory/webserver/compose.yml down 2>/dev/null || true",
         check=False)
    _run("podman compose --project-name armory-postgres -f /opt/armory/postgres/compose.yml down 2>/dev/null || true",
         check=False)
    _run("podman rm -f armory-webserver armory-vault-agent armory-postgres armory-postgres-vault-agent 2>/dev/null || true",
         check=False)
    _run("tofu destroy -auto-approve", cwd=WEBSERVER_MODULE, env=base_env, check=False)
    _run("tofu destroy -auto-approve", cwd=VAULT_CONFIG_MODULE, env=base_env, check=False)
    _run("tofu destroy -auto-approve", cwd=VAULT_MODULE, check=False)

    # Clear stale tfstate — vault is about to be recreated fresh so all vault-side
    # resource IDs are invalid regardless of whether the destroys above succeeded.
    for module in (WEBSERVER_MODULE, VAULT_CONFIG_MODULE):
        for fname in ("terraform.tfstate", "terraform.tfstate.backup"):
            (module / fname).unlink(missing_ok=True)

    # Remove deploy directories — previous runs leave read-only files (0444)
    # that block fresh writes by local_sensitive_file resources.
    # Use podman unshare in case container-user-owned files exist.
    for d in ("/opt/armory/webserver", "/opt/armory/vault"):
        _run(f"podman unshare rm -rf {d} 2>/dev/null || rm -rf {d} 2>/dev/null || true",
             check=False)

    # 2. Init modules (idempotent; required on fresh checkout / CI)
    _run("tofu init -upgrade", cwd=VAULT_MODULE)
    _run("tofu init -upgrade", cwd=VAULT_CONFIG_MODULE, env=base_env)

    # 3. Deploy Vault
    _run("tofu apply -auto-approve", cwd=VAULT_MODULE)

    # 4. Wait for container API
    _wait_for_vault_ready()

    # 5. Init
    result = _run("podman exec armory-vault bao operator init -key-shares=1 -key-threshold=1")
    unseal_key = re.search(r"Unseal Key 1:\s+(\S+)", result.stdout).group(1)
    root_token = re.search(r"Initial Root Token:\s+(\S+)", result.stdout).group(1)

    # 6. Unseal
    _run(f"podman exec armory-vault bao operator unseal {unseal_key}")

    # 7. Wait for active
    _wait_for_active()

    # 8. Configure Vault
    config_env = base_env.copy()
    config_env["TF_VAR_vault_token"] = root_token
    _run("tofu apply -auto-approve", cwd=VAULT_CONFIG_MODULE, env=config_env)

    yield {
        "addr": VAULT_ADDR,
        "cacert": VAULT_CACERT,
        "token": root_token,
        "unseal_key": unseal_key,
        "config_env": config_env,
    }

    # 9. Always collect logs
    log_path = _collect_logs()
    print(f"\nVault logs saved to: {log_path}")

    # 10. Teardown
    if NO_TEARDOWN:
        print(f"\nARMORY_NO_TEARDOWN is set — environment left running.")
        print(f"Root token: {root_token}")
    else:
        _run("tofu destroy -auto-approve", cwd=VAULT_CONFIG_MODULE, env=config_env, check=False)
        _run("tofu destroy -auto-approve", cwd=VAULT_MODULE, check=False)


@pytest.fixture(scope="session")
def vault_client(vault_env):
    import hvac
    client = hvac.Client(
        url=vault_env["addr"],
        token=vault_env["token"],
        verify=vault_env["cacert"],
    )
    assert client.is_authenticated(), "Vault client failed to authenticate"
    return client


# ---------------------------------------------------------------------------
# Webserver session fixture
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def webserver_env(vault_env):
    config_env = vault_env["config_env"]

    # Apply webserver module
    _run("tofu init", cwd=WEBSERVER_MODULE, env=config_env)
    _run("tofu apply -auto-approve", cwd=WEBSERVER_MODULE, env=config_env)

    # Wait for nginx to be reachable (vault-agent must auth + write certs first)
    _wait_for_nginx(timeout=180)

    # The nginx cert is issued by pki_ext (Armory External Intermediate CA).
    # Use the PKI CA bundle (written by vault-config) to verify the chain.
    pki_ca_bundle = str(PROJECT_ROOT / "vault" / "ca-bundle.pem")

    yield {
        "cacert": pki_ca_bundle,
        "url": "https://127.0.0.1:8443",
    }

    # Always collect webserver logs
    _collect_webserver_logs()

    if not NO_TEARDOWN:
        _run("tofu destroy -auto-approve", cwd=WEBSERVER_MODULE, env=config_env, check=False)


# ---------------------------------------------------------------------------
# PostgreSQL session fixture
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def postgres_env(vault_env):
    """
    Deploy services/postgres/ and enable database roles in vault-config.

    Re-applies vault-config with database_roles_enabled=true after Postgres
    is running so the database secrets engine can connect.
    """
    config_env = vault_env["config_env"]

    # Stop any running postgres containers first.
    # podman compose down guarantees containers are fully removed before we delete
    # the host directory — podman rm -f alone can leave containers in a zombie
    # state with bind mounts pointing to deleted directory inodes.
    _run(
        "podman compose --project-name armory-postgres -f /opt/armory/postgres/compose.yml down 2>/dev/null || true",
        check=False,
    )
    _run(
        "podman rm -f armory-postgres armory-postgres-vault-agent 2>/dev/null || true",
        check=False,
    )
    _run(
        "podman unshare rm -rf /opt/armory/postgres 2>/dev/null || rm -rf /opt/armory/postgres 2>/dev/null || true",
        check=False,
    )
    for fname in ("terraform.tfstate", "terraform.tfstate.backup"):
        (POSTGRES_MODULE / fname).unlink(missing_ok=True)

    _run("tofu init", cwd=POSTGRES_MODULE, env=config_env)
    _run("tofu apply -auto-approve", cwd=POSTGRES_MODULE, env=config_env)

    _wait_for_postgres(timeout=90)

    # Enable database roles now that Postgres is reachable
    _run(
        "tofu apply -auto-approve -var database_roles_enabled=true",
        cwd=VAULT_CONFIG_MODULE,
        env=config_env,
    )

    yield {
        "postgres_host": "armory-postgres",
        "vault_addr":    VAULT_ADDR,
        "vault_cacert":  VAULT_CACERT,
    }

    if not NO_TEARDOWN:
        _run("tofu destroy -auto-approve", cwd=POSTGRES_MODULE, env=config_env, check=False)


# ---------------------------------------------------------------------------
# Agent session fixture
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def agent_env(vault_env, postgres_env):
    """
    Apply services/agent/ (requires vault-config applied with agent_enabled=true).

    The wrapped_secret_id written here is single-use. Each test run must re-apply
    services/agent/ to issue a fresh one — the fixture handles this automatically.
    """
    config_env = vault_env["config_env"].copy()
    config_env["TF_VAR_agent_enabled"] = "true"

    # Re-apply vault-config with both flags — must carry forward database_roles_enabled
    # since postgres_env already enabled it (omitting it would revert to false).
    _run(
        "tofu apply -auto-approve -var agent_enabled=true -var database_roles_enabled=true",
        cwd=VAULT_CONFIG_MODULE,
        env=config_env,
    )

    # Clean up any stale agent credentials from a previous run so local_sensitive_file
    # can write fresh files (0444 files are read-only for the owner on some systems).
    _run(
        "podman unshare rm -rf /opt/armory/agent 2>/dev/null || rm -rf /opt/armory/agent 2>/dev/null || true",
        check=False,
    )
    for fname in ("terraform.tfstate", "terraform.tfstate.backup"):
        (AGENT_MODULE / fname).unlink(missing_ok=True)

    _run("tofu init", cwd=AGENT_MODULE, env=config_env)
    _run("tofu apply -auto-approve", cwd=AGENT_MODULE, env=config_env)

    approle_dir = "/opt/armory/agent/approle"

    yield {
        "vault_addr":   VAULT_ADDR,
        "vault_cacert": VAULT_CACERT,
        "approle_dir":  approle_dir,
    }

    if not NO_TEARDOWN:
        _run("tofu destroy -auto-approve", cwd=AGENT_MODULE, env=config_env, check=False)


@pytest.fixture(scope="session")
def agent_api_env(agent_env, postgres_env, vault_client):
    """
    Start the agent API subprocess and yield its base URL.

    Issues a fresh wrapped secret_id before starting — the agent_env fixture
    may have already consumed the one on disk (single-use property).
    """
    import subprocess
    import hvac

    approle_dir = agent_env["approle_dir"]

    # Issue a fresh wrapped secret_id so the subprocess can authenticate
    response = vault_client.auth.approle.generate_secret_id(
        role_name="agent",
        wrap_ttl="10m",
    )
    wrap_token = response["wrap_info"]["token"]
    wrap_path  = f"{approle_dir}/wrapped_secret_id"
    # The file is 0444 — remove before rewriting
    _run(f"podman unshare rm -f {wrap_path} 2>/dev/null || rm -f {wrap_path} 2>/dev/null || true", check=False)
    Path(wrap_path).write_text(wrap_token)
    Path(wrap_path).chmod(0o444)

    agent_dir = AGENT_MODULE / "agent"
    venv_python = PROJECT_ROOT / ".venv" / "bin" / "python"

    env = os.environ.copy()
    env.update({
        "VAULT_ADDR":      VAULT_ADDR,
        "ARMORY_CACERT":   VAULT_CACERT,
        "APPROLE_DIR":     approle_dir,
        "KEYCLOAK_URL":    "https://127.0.0.1:8444",  # not used in integration tests
        "OIDC_CLIENT_ID":  "agent-cli",
        "POSTGRES_HOST":   "armory-postgres",
        "POSTGRES_DB":     "app",
    })

    proc = subprocess.Popen(
        [str(venv_python), "api.py"],
        cwd=str(agent_dir),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        _wait_for_agent_api(timeout=30)
        yield {"url": "http://127.0.0.1:8000", "vault_client": vault_client}
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
