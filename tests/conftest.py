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

    # 1. Destroy any existing state (best-effort)
    #    Webserver tofu destroy requires Vault to be running, so also stop containers directly.
    _run("podman rm -f armory-webserver armory-vault-agent 2>/dev/null || true",
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
