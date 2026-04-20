import os
import re
import psycopg2
import structlog

log = structlog.get_logger()

POSTGRES_HOST   = os.environ["POSTGRES_HOST"]
POSTGRES_PORT   = int(os.environ.get("POSTGRES_PORT", "5432"))
POSTGRES_DB     = os.environ.get("POSTGRES_DB", "app")
# POSTGRES_CACERT overrides ARMORY_CACERT for postgres TLS verification.
# Useful when the postgres cert is signed by a different CA (e.g. pki_int)
# than the Vault TLS CA (ARMORY_CACERT).
POSTGRES_CACERT = os.environ.get("POSTGRES_CACERT") or os.environ["ARMORY_CACERT"]

# Only SELECT queries are permitted. The agent's Vault-issued DB role carries
# only read grants (defined in services/postgres/templates/init.sql.tpl), but
# rejecting non-SELECT queries at this layer makes the intent explicit and
# prevents accidental writes if grants ever widen.
_SELECT_ONLY = re.compile(r"^\s*SELECT\b", re.IGNORECASE)


def query_database(db_creds: dict, query: str) -> list[dict]:
    """
    Execute a read-only query against the app database using Vault-issued credentials.

    TLS is verified against the Armory CA (sslmode=verify-full).
    """
    if not _SELECT_ONLY.match(query):
        raise ValueError("Only SELECT queries are permitted")

    log.info(
        "tool.query_database.start",
        pg_user=db_creds["username"],
        host=POSTGRES_HOST,
        db=POSTGRES_DB,
    )

    conn = psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=db_creds["username"],
        password=db_creds["password"],
        sslmode="verify-full",
        sslrootcert=POSTGRES_CACERT,
    )

    try:
        with conn.cursor() as cur:
            cur.execute(query)
            columns = [desc[0] for desc in cur.description]
            rows    = [dict(zip(columns, row)) for row in cur.fetchall()]
        log.info("tool.query_database.complete", row_count=len(rows))
        return rows
    finally:
        conn.close()
