#!/usr/bin/env python3
import json
import socket
import ssl
import time
import urllib.request
from datetime import datetime, timezone

VAULT_HEALTH_URL = "${vault_health_url}"
KEYCLOAK_HEALTH_URL = "${keycloak_health_url}"
POSTGRES_HOST = "${postgres_host}"
POSTGRES_PORT = ${postgres_port}
INTERVAL = ${observer_interval_seconds}
OUT_FILE = "/observer/armory-observer.log"

CTX = ssl.create_default_context(cafile="/vault/tls/ca.crt")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def check_https(name: str, url: str) -> dict:
    start = time.perf_counter()
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, context=CTX, timeout=5) as resp:
            duration_ms = round((time.perf_counter() - start) * 1000, 2)
            return {
                "check": name,
                "target": url,
                "ok": True,
                "status_code": resp.status,
                "duration_ms": duration_ms,
            }
    except Exception as exc:
        duration_ms = round((time.perf_counter() - start) * 1000, 2)
        return {
            "check": name,
            "target": url,
            "ok": False,
            "duration_ms": duration_ms,
            "error": str(exc),
        }


def check_tcp(name: str, host: str, port: int) -> dict:
    start = time.perf_counter()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    try:
        sock.connect((host, port))
        duration_ms = round((time.perf_counter() - start) * 1000, 2)
        return {
            "check": name,
            "target": f"{host}:{port}",
            "ok": True,
            "duration_ms": duration_ms,
        }
    except Exception as exc:
        duration_ms = round((time.perf_counter() - start) * 1000, 2)
        return {
            "check": name,
            "target": f"{host}:{port}",
            "ok": False,
            "duration_ms": duration_ms,
            "error": str(exc),
        }
    finally:
        sock.close()


def emit(record: dict) -> None:
    line = json.dumps(record, separators=(",", ":"))
    with open(OUT_FILE, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


while True:
    ts = utc_now()
    checks = [
        check_https("vault_health", VAULT_HEALTH_URL),
        check_https("keycloak_health", KEYCLOAK_HEALTH_URL),
        check_tcp("postgres_tcp", POSTGRES_HOST, POSTGRES_PORT),
    ]

    for check in checks:
        emit({"ts": ts, "service": "armory-observer", **check})

    time.sleep(INTERVAL)
