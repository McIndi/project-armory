"""
Session fixture: full lifecycle management for Armory integration tests.

Sequence:
  destroy (vault-config/) → destroy (vault/) → apply (vault/) →
  wait → init → unseal → wait → apply (vault-config/) →
  [ tests ] →
  collect logs → teardown (unless ARMORY_NO_TEARDOWN=1)
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


# ---------------------------------------------------------------------------
# Session fixture
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def vault_env():
    base_env = os.environ.copy()

    # 1. Destroy any existing state (best-effort)
    _run("tofu destroy -auto-approve", cwd=VAULT_CONFIG_MODULE, env=base_env, check=False)
    _run("tofu destroy -auto-approve", cwd=VAULT_MODULE, check=False)

    # 2. Deploy Vault
    _run("tofu apply -auto-approve", cwd=VAULT_MODULE)

    # 3. Wait for container API
    _wait_for_vault_ready()

    # 4. Init
    result = _run("podman exec armory-vault bao operator init -key-shares=1 -key-threshold=1")
    unseal_key = re.search(r"Unseal Key 1:\s+(\S+)", result.stdout).group(1)
    root_token = re.search(r"Initial Root Token:\s+(\S+)", result.stdout).group(1)

    # 5. Unseal
    _run(f"podman exec armory-vault bao operator unseal {unseal_key}")

    # 6. Wait for active
    _wait_for_active()

    # 7. Configure Vault
    config_env = base_env.copy()
    config_env["TF_VAR_vault_token"] = root_token
    _run("tofu apply -auto-approve", cwd=VAULT_CONFIG_MODULE, env=config_env)

    yield {
        "addr": VAULT_ADDR,
        "cacert": VAULT_CACERT,
        "token": root_token,
        "unseal_key": unseal_key,
    }

    # 8. Always collect logs
    log_path = _collect_logs()
    print(f"\nVault logs saved to: {log_path}")

    # 9. Teardown
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
