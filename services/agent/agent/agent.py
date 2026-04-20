import uuid
import structlog
from vault_client import authenticate, get_dynamic_db_credentials, revoke_token
from tools import query_database

log = structlog.get_logger()


def run_task(task: dict, operator: dict) -> dict:
    """
    Execute one agent task as a discrete, auditable unit.

    A request_id is generated per invocation and bound to every log entry,
    allowing API log entries and Vault audit log entries to be correlated
    by request.

    task     = {"type": "db_query", "query": "SELECT current_user, now() AS ts"}
    operator = decoded Keycloak JWT claims (sub, preferred_username, groups)
    """
    request_id = str(uuid.uuid4())

    bound_log = log.bind(
        request_id=request_id,
        operator_sub=operator.get("sub"),
        operator=operator.get("preferred_username"),
        task_type=task["type"],
    )

    bound_log.info("agent.task.start")

    client = None
    try:
        client = authenticate()

        if task["type"] == "db_query":
            db_creds = get_dynamic_db_credentials(client)
            results  = query_database(db_creds, task["query"])
            bound_log.info("agent.task.complete", row_count=len(results))
            return {"status": "ok", "request_id": request_id, "results": results}

        else:
            bound_log.warning("agent.task.unknown_type")
            return {
                "status":     "error",
                "request_id": request_id,
                "message":    f"Unknown task type: {task['type']}",
            }

    except Exception as e:
        bound_log.error("agent.task.failed", error=str(e))
        return {"status": "error", "request_id": request_id, "message": str(e)}

    finally:
        if client is not None:
            revoke_token(client)
