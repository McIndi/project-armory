import os
import re
import uvicorn
import structlog
from contextlib import asynccontextmanager

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)

from fastapi import FastAPI, Depends
from pydantic import BaseModel, field_validator
from oidc import validate_token
from agent import run_task
from vault_client import initialize_runtime_client, shutdown_runtime_client

log = structlog.get_logger()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    log.info("api.startup.vault_auth")
    initialize_runtime_client()
    try:
        yield
    finally:
        log.info("api.shutdown.vault_revoke")
        shutdown_runtime_client()


app = FastAPI(title="Armory Agent API", lifespan=lifespan)


class TaskRequest(BaseModel):
    type: str
    query: str | None = None

    @field_validator("query")
    @classmethod
    def query_must_be_select(cls, v: str | None) -> str | None:
        if v is not None and not re.match(r"^\s*SELECT\b", v, re.IGNORECASE):
            raise ValueError("Only SELECT queries are permitted")
        return v


@app.post("/task")
def submit_task(
    task: TaskRequest,
    operator: dict = Depends(validate_token),
):
    """
    Submit a task for execution.

    Plain def (not async) so FastAPI routes it to a thread pool.
    run_task() performs blocking I/O (Vault auth, DB query) that must
    not block the asyncio event loop.
    """
    log.info(
        "api.task.received",
        operator=operator.get("preferred_username"),
        task_type=task.type,
    )
    return run_task(task.model_dump(), operator)


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    host = os.environ.get("AGENT_API_HOST", "0.0.0.0")
    port = int(os.environ.get("AGENT_API_PORT", "8443"))
    tls_cert = os.environ.get("AGENT_TLS_CERT_FILE")
    tls_key = os.environ.get("AGENT_TLS_KEY_FILE") or tls_cert

    uvicorn_kwargs = {
        "host": host,
        "port": port,
    }

    if tls_cert:
        uvicorn_kwargs["ssl_certfile"] = tls_cert
        uvicorn_kwargs["ssl_keyfile"] = tls_key

    uvicorn.run(app, **uvicorn_kwargs)
