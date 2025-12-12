"""
FastMCP server exposing underwriting submission details.

Key update:
- Supports identifier_type + identifier_value (friendly_id | convr_id | internal_id)
- Resolves to Underwriting.Submissions.Id first
- Runs one canonical query using WHERE s.Id = ?
"""

from __future__ import annotations

import logging
import os
import struct
from dataclasses import asdict, dataclass
from datetime import datetime
from queue import LifoQueue
from threading import Lock
from time import perf_counter
from typing import Optional, Tuple

import pyodbc
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from fastmcp import FastMCP

logger = logging.getLogger(__name__)

# -------------------------
# Configuration (env-based)
# -------------------------
SQL_DRIVER = os.getenv("SQL_DRIVER", "ODBC Driver 18 for SQL Server")
SQL_SERVER = os.getenv("SQL_SERVER", "your-server.database.windows.net")
SQL_DATABASE = os.getenv("SQL_DATABASE", "your-db")

# For Azure SQL, the scope is typically "https://database.windows.net//.default"
SQL_TOKEN_SCOPE = os.getenv("SQL_TOKEN_SCOPE", "https://database.windows.net//.default")

# Microsoft ODBC attribute for access tokens
SQL_COPT_SS_ACCESS_TOKEN = 1256  # documented constant used by msodbcsql

# -------------------------
# Credentials (MI -> Default)
# -------------------------
_MANAGED_IDENTITY_CREDENTIAL: ManagedIdentityCredential | None = None
_DEFAULT_CREDENTIAL: DefaultAzureCredential | None = None
_CREDENTIAL_LOCK = Lock()


def get_access_token_for_sql() -> str:
    """Get an Azure AD access token for Azure SQL. Prefer Managed Identity, fallback to DefaultAzureCredential."""
    global _MANAGED_IDENTITY_CREDENTIAL, _DEFAULT_CREDENTIAL

    with _CREDENTIAL_LOCK:
        if _MANAGED_IDENTITY_CREDENTIAL is None:
            try:
                _MANAGED_IDENTITY_CREDENTIAL = ManagedIdentityCredential()
            except Exception as exc:  # MI init can fail in local dev
                logger.debug("Managed Identity credential unavailable during init: %s", exc)
                _MANAGED_IDENTITY_CREDENTIAL = None

        if _MANAGED_IDENTITY_CREDENTIAL is not None:
            try:
                token = _MANAGED_IDENTITY_CREDENTIAL.get_token(SQL_TOKEN_SCOPE)
                logger.debug("Authenticated with Managed Identity")
                return token.token
            except Exception as exc:
                logger.warning("Managed Identity authentication failed (fallback): %s", exc)

        if _DEFAULT_CREDENTIAL is None:
            # Exclude interactive browser to avoid hanging in headless environments
            _DEFAULT_CREDENTIAL = DefaultAzureCredential(exclude_interactive_browser_credential=True)

        token = _DEFAULT_CREDENTIAL.get_token(SQL_TOKEN_SCOPE)
        logger.debug("Authenticated with DefaultAzureCredential")
        return token.token


# -------------------------
# Dataclasses
# -------------------------
@dataclass(frozen=True)
class SubmissionDetails:
    """Container for the underwriting submission snapshot."""
    broker_name: Optional[str]
    submission_received_date: Optional[datetime]
    spark_submission_id: str
    account_id: Optional[str]
    insurance_applied_for: Optional[str]
    third_party_enrichment: Optional[str]


@dataclass(frozen=True)
class SubmissionQueryMetrics:
    """Timing information collected while retrieving a submission."""
    connection_ms: float
    query_ms: float
    total_ms: float


@dataclass
class _ConnectionRecord:
    connection: pyodbc.Connection
    created_at: float


# -------------------------
# Connection pool
# -------------------------
class ConnectionPool:
    """Simple LIFO connection pool with token-expiry awareness."""

    def __init__(self, max_size: int, token_ttl_seconds: float) -> None:
        self._max_size = max(0, max_size)
        self._token_ttl_seconds = max(0.0, float(token_ttl_seconds))
        self._queue: LifoQueue[_ConnectionRecord] = LifoQueue(maxsize=self._max_size or 0)
        self._lock = Lock()
        self._created = 0
        self._connection_string = self._build_connection_string()

    def connection(self) -> "_ConnectionContext":
        return _ConnectionContext(self)

    def _acquire(self) -> tuple[_ConnectionRecord, float]:
        start = perf_counter()
        while True:
            record = self._get_record_or_create()
            if self._is_expired(record):
                self._dispose(record)
                self._decrement_created()
                continue
            return record, (perf_counter() - start) * 1000

    def _get_record_or_create(self) -> _ConnectionRecord:
        try:
            record = self._queue.get_nowait()
            return record
        except Exception:
            with self._lock:
                if self._max_size and self._created >= self._max_size:
                    # Pool exhausted; block until one is available
                    record = self._queue.get()
                    return record
                self._created += 1

            try:
                return self._create_connection()
            except Exception:
                # _create_connection already decremented created on failure
                raise

    def _release(self, record: _ConnectionRecord, had_error: bool) -> None:
        if had_error or self._is_expired(record):
            self._dispose(record)
            self._decrement_created()
            return

        if self._max_size == 0:
            # No pooling requested
            self._dispose(record)
            self._decrement_created()
            return

        try:
            self._queue.put_nowait(record)
        except Exception:
            self._dispose(record)
            self._decrement_created()

    def _create_connection(self) -> _ConnectionRecord:
        access_token = get_access_token_for_sql()
        token_bytes = access_token.encode("utf-16-le")
        token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)

        logger.debug("Creating new SQL connection to %s / %s", SQL_SERVER, SQL_DATABASE)

        try:
            connection = pyodbc.connect(
                self._connection_string,
                attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct},
                timeout=30,
                autocommit=True,
            )
        except pyodbc.Error:
            logger.error("Failed to establish SQL connection", exc_info=True)
            self._decrement_created()
            raise

        return _ConnectionRecord(connection=connection, created_at=perf_counter())

    def _dispose(self, record: _ConnectionRecord) -> None:
        try:
            record.connection.close()
        except Exception:
            logger.debug("Error closing SQL connection", exc_info=True)

    def _is_expired(self, record: _ConnectionRecord) -> bool:
        if self._token_ttl_seconds <= 0:
            return False
        return (perf_counter() - record.created_at) > self._token_ttl_seconds

    def _decrement_created(self) -> None:
        with self._lock:
            if self._created > 0:
                self._created -= 1

    def _build_connection_string(self) -> str:
        # NOTE: No Authentication=... here because we pass token via attrs_before
        return (
            f"Driver={{{SQL_DRIVER}}};"
            f"Server=tcp:{SQL_SERVER},1433;"
            f"Database={SQL_DATABASE};"
            "Encrypt=yes;"
            "TrustServerCertificate=no;"
        )


class _ConnectionContext:
    def __init__(self, pool: ConnectionPool) -> None:
        self._pool = pool
        self._record: _ConnectionRecord | None = None
        self._acquire_ms = 0.0

    def __enter__(self) -> tuple[pyodbc.Connection, float]:
        self._record, self._acquire_ms = self._pool._acquire()
        return self._record.connection, self._acquire_ms

    def __exit__(self, exc_type, exc, exc_tb) -> bool:
        had_error = exc_type is not None
        if self._record is not None:
            self._pool._release(self._record, had_error)
        return False


def parse_int_env(variable: str, default: int) -> int:
    raw_value = os.getenv(variable)
    if raw_value is None:
        return default
    try:
        return int(raw_value)
    except ValueError:
        logger.warning("Invalid integer value for %s: %s. Using default %s", variable, raw_value, default)
        return default


SQL_POOL_MAX_SIZE = parse_int_env("SQL_POOL_MAX_SIZE", 4)
SQL_POOL_TOKEN_TTL_SECONDS = parse_int_env("SQL_POOL_TOKEN_TTL_SECONDS", 3300)

CONNECTION_POOL = ConnectionPool(
    max_size=SQL_POOL_MAX_SIZE,
    token_ttl_seconds=float(SQL_POOL_TOKEN_TTL_SECONDS),
)

# -------------------------
# SQL (Canonical Query)
# -------------------------
_SUBMISSION_DETAILS_SQL = """
SELECT
    b.Name AS BrokerName,
    s.SubmissionReceivedDate,
    s.SparkSubmissionId,
    s.AccountNumber AS AccountId,
    lob.InsuranceAppliedFor,
    providers.ProviderNames AS ThirdPartyEnrichment
FROM Underwriting.Submissions AS s
LEFT JOIN Underwriting.Brokers AS b
    ON b.Id = s.BrokerId
OUTER APPLY (
    SELECT TOP (1)
        cp_inner.OriginalConvrPayloadJson
    FROM Underwriting.ConvrPayloads AS cp_inner
    WHERE cp_inner.SubmissionId = s.Id
    ORDER BY
        cp_inner.ProcessedAtUtc DESC,
        cp_inner.ReceivedAtUtc DESC,
        cp_inner.CreatedAt DESC
) AS cp
OUTER APPLY (
    SELECT
        STRING_AGG(lob_entries.Lob, ', ') WITHIN GROUP (ORDER BY lob_entries.Lob) AS InsuranceAppliedFor
    FROM OPENJSON(cp.OriginalConvrPayloadJson, '$.d3Submission.d3LineOfBusiness')
    WITH (Lob NVARCHAR(200) '$.lob') AS lob_entries
) AS lob
OUTER APPLY (
    SELECT
        STRING_AGG(tpd.ProviderName, ', ') WITHIN GROUP (ORDER BY tpd.ProviderName) AS ProviderNames
    FROM thirdpartydata.ThirdPartyDataRecords AS tpd
    WHERE tpd.SubmissionId = s.Id
      AND (tpd.IsActive IS NULL OR tpd.IsActive = 1)
) AS providers
WHERE s.Id = ?;
"""

# -------------------------
# Identifier resolution (NEW)
# -------------------------
SUPPORTED_IDENTIFIER_TYPES = {"friendly_id", "convr_id", "internal_id"}


def resolve_submission_id(
    cursor: pyodbc.Cursor,
    identifier_type: str,
    identifier_value: str,
) -> Optional[int]:
    """Resolve any supported identifier to Underwriting.Submissions.Id (internal PK)."""
    identifier_type = (identifier_type or "").strip().lower()
    identifier_value = (identifier_value or "").strip()

    if identifier_type not in SUPPORTED_IDENTIFIER_TYPES:
        raise ValueError(f"identifier_type must be one of {sorted(SUPPORTED_IDENTIFIER_TYPES)}")

    if not identifier_value:
        raise ValueError("identifier_value must not be empty")

    if identifier_type == "friendly_id":
        cursor.execute(
            "SELECT Id FROM Underwriting.Submissions WHERE SparkSubmissionId = ?",
            (identifier_value,),
        )
    elif identifier_type == "convr_id":
        cursor.execute(
            "SELECT Id FROM Underwriting.Submissions WHERE SubmissionSourceCode = ?",
            (identifier_value,),
        )
    else:  # internal_id
        cursor.execute(
            "SELECT Id FROM Underwriting.Submissions WHERE Id = ?",
            (identifier_value,),
        )

    row = cursor.fetchone()
    return int(row[0]) if row else None


def fetch_submission_details(cursor: pyodbc.Cursor, submission_id: int) -> Optional[SubmissionDetails]:
    """Fetch submission details using an existing pyodbc cursor and internal submission_id."""
    cursor.execute(_SUBMISSION_DETAILS_SQL, (submission_id,))
    row = cursor.fetchone()
    if not row:
        return None

    return SubmissionDetails(
        broker_name=row[0],
        submission_received_date=row[1],
        spark_submission_id=row[2],
        account_id=row[3],
        insurance_applied_for=row[4],
        third_party_enrichment=row[5],
    )


def metrics_to_dict(metrics: SubmissionQueryMetrics | None, tool_total_ms: float | None) -> Optional[dict[str, float]]:
    if metrics is None and tool_total_ms is None:
        return None
    data: dict[str, float] = {}
    if metrics is not None:
        data["connection_ms"] = round(metrics.connection_ms, 2)
        data["query_ms"] = round(metrics.query_ms, 2)
        data["db_total_ms"] = round(metrics.total_ms, 2)
    if tool_total_ms is not None:
        data["tool_total_ms"] = round(tool_total_ms, 2)
    return data


def serialise_submission_details(
    details: SubmissionDetails,
    metrics: SubmissionQueryMetrics | None = None,
    tool_total_ms: float | None = None,
) -> dict:
    """Convert the dataclass into a JSON-serialisable dict."""
    payload = asdict(details)
    received = payload.get("submission_received_date")
    if isinstance(received, datetime):
        payload["submission_received_date"] = received.isoformat()
    metrics_dict = metrics_to_dict(metrics, tool_total_ms)
    if metrics_dict:
        payload["metrics"] = metrics_dict
    return payload


def fetch_submission_details_with_connection(
    identifier_type: str,
    identifier_value: str,
) -> Tuple[Optional[SubmissionDetails], Optional[int], SubmissionQueryMetrics]:
    """Convenience wrapper that manages the SQL connection lifecycle and collects timing metrics."""
    total_start = perf_counter()

    query_elapsed_ms = 0.0
    details: Optional[SubmissionDetails] = None
    resolved_submission_id: Optional[int] = None

    with CONNECTION_POOL.connection() as (connection, connection_elapsed_ms):
        cursor = connection.cursor()
        query_start = perf_counter()
        try:
            # Resolve identifier -> internal submission id
            resolved_submission_id = resolve_submission_id(cursor, identifier_type, identifier_value)
            if resolved_submission_id is not None:
                details = fetch_submission_details(cursor, resolved_submission_id)
        finally:
            query_elapsed_ms = (perf_counter() - query_start) * 1000
            try:
                cursor.close()
            except Exception:
                logger.debug("Failed to close cursor cleanly", exc_info=True)

    total_elapsed_ms = (perf_counter() - total_start) * 1000
    metrics = SubmissionQueryMetrics(
        connection_ms=connection_elapsed_ms,
        query_ms=query_elapsed_ms,
        total_ms=total_elapsed_ms,
    )
    return details, resolved_submission_id, metrics


# -------------------------
# FastMCP server + tool
# -------------------------
mcp = FastMCP("Underwriting Submission MCP")


@mcp.tool()
def get_submission_overview(identifier_type: str, identifier_value: str) -> dict:
    """
    Return broker, submission metadata, lines of business, and third-party enrichment summary.

    identifier_type:
      - friendly_id  -> Underwriting.Submissions.SparkSubmissionId
      - convr_id     -> Underwriting.Submissions.SubmissionSourceCode
      - internal_id  -> Underwriting.Submissions.Id

    identifier_value: the identifier value as a string
    """
    tool_start = perf_counter()

    identifier_type_clean = (identifier_type or "").strip().lower()
    identifier_value_clean = (identifier_value or "").strip()

    if identifier_type_clean not in SUPPORTED_IDENTIFIER_TYPES:
        return {
            "found": False,
            "identifier_type": identifier_type_clean,
            "identifier_value": identifier_value_clean,
            "error": f"identifier_type must be one of {sorted(SUPPORTED_IDENTIFIER_TYPES)}",
        }

    if not identifier_value_clean:
        return {
            "found": False,
            "identifier_type": identifier_type_clean,
            "identifier_value": identifier_value_clean,
            "error": "identifier_value must not be empty",
        }

    try:
        details, submission_id, metrics = fetch_submission_details_with_connection(
            identifier_type_clean,
            identifier_value_clean,
        )
    except Exception as exc:
        logger.exception(
            "Failed to fetch submission using %s=%s",
            identifier_type_clean,
            identifier_value_clean,
        )
        elapsed_ms = (perf_counter() - tool_start) * 1000
        return {
            "found": False,
            "identifier_type": identifier_type_clean,
            "identifier_value": identifier_value_clean,
            "error": str(exc),
            "metrics": {"tool_total_ms": round(elapsed_ms, 2)},
        }

    tool_total_ms = (perf_counter() - tool_start) * 1000

    if submission_id is None:
        # Could not resolve identifier -> internal id
        response = {
            "found": False,
            "identifier_type": identifier_type_clean,
            "identifier_value": identifier_value_clean,
            "error": "Submission not found (identifier did not resolve)",
        }
        metrics_dict = metrics_to_dict(metrics, tool_total_ms)
        if metrics_dict:
            response["metrics"] = metrics_dict
        logger.warning(
            "Identifier %s=%s did not resolve (conn %.2f ms, query %.2f ms)",
            identifier_type_clean,
            identifier_value_clean,
            metrics.connection_ms,
            metrics.query_ms,
        )
        return response

    if not details:
        # Identifier resolved to an internal id, but canonical query returned nothing
        response = {
            "found": False,
            "identifier_type": identifier_type_clean,
            "identifier_value": identifier_value_clean,
            "submission_id": submission_id,
            "error": "Submission details not found",
        }
        metrics_dict = metrics_to_dict(metrics, tool_total_ms)
        if metrics_dict:
            response["metrics"] = metrics_dict
        logger.warning(
            "Submission %s resolved but details not found (conn %.2f ms, query %.2f ms)",
            submission_id,
            metrics.connection_ms,
            metrics.query_ms,
        )
        return response

    logger.info(
        "Submission resolved (%s=%s -> id=%s) in %.2f ms (conn %.2f ms, query %.2f ms)",
        identifier_type_clean,
        identifier_value_clean,
        submission_id,
        metrics.total_ms,
        metrics.connection_ms,
        metrics.query_ms,
    )

    result = serialise_submission_details(details, metrics=metrics, tool_total_ms=tool_total_ms)
    # Include resolution info (very useful for debugging & auditing)
    result["found"] = True
    result["identifier_type"] = identifier_type_clean
    result["identifier_value"] = identifier_value_clean
    result["submission_id"] = submission_id
    return result


def run_server() -> None:
    """Start the FastMCP server using the streamable HTTP transport."""
    host = os.getenv("MCP_SSE_HOST", "127.0.0.1")
    port = int(os.getenv("MCP_SSE_PORT", "8083"))
    logger.info("Starting FastMCP streamable HTTP server on %s:%s", host, port)
    mcp.run(transport="streamable-http", host=host, port=port)


if __name__ == "__main__":
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
    )
    run_server()
