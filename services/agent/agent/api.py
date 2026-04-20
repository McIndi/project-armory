import os
import re
import uvicorn
import structlog

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

log = structlog.get_logger()
app = FastAPI(title="Armory Agent API")


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
    uvicorn.run(app, host="0.0.0.0", port=8000)
