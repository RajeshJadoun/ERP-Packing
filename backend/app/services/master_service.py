"""Caller-scoped PostgREST service helpers.

The service uses the verified caller JWT, never the Supabase service-role key.
Tables and selected fields are intentionally allow-listed. PostgreSQL RLS is
still the authorization authority for every request.
"""

from __future__ import annotations

from typing import Any

import httpx
from flask import current_app, g

from ..errors import ApiError

MASTER_TABLES = frozenset(
    {
        "material_categories",
        "parties",
        "products",
        "vendors",
        "units",
        "locations",
        "workers",
        "materials",
        "material_conversions",
    }
)

_READ_TABLES = MASTER_TABLES | frozenset(
    {
        "purchase_orders",
        "purchase_order_lines",
        "goods_receipts",
        "goods_receipt_lines",
        "stock_transactions",
        "material_location_balances",
        "stock_reservations",
        "stock_adjustments",
        "packing_jobs",
        "boms",
        "bom_lines",
        "bom_revision_events",
        "daily_plans",
        "packing_job_bom_snapshots",
        "packing_job_bom_snapshot_lines",
        "packing_job_revisions",
        "packing_job_events",
    }
)


def _headers() -> dict[str, str]:
    token = getattr(g, "auth_token", None)
    anon_key = current_app.config.get("SUPABASE_ANON_KEY")
    if not token or not anon_key:
        raise ApiError(503, "SUPABASE_NOT_CONFIGURED", "Database access is not configured.")
    return {
        "apikey": anon_key,
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }


def rest_select(table: str, *, params: dict[str, str]) -> list[dict[str, Any]]:
    """Read rows through PostgREST, with table-name allow-listing and user RLS."""
    if table not in _READ_TABLES:
        raise ValueError("PostgREST table is not allow-listed.")

    base_url = current_app.config.get("SUPABASE_URL", "").rstrip("/")
    if not base_url:
        raise ApiError(503, "SUPABASE_NOT_CONFIGURED", "Database access is not configured.")

    try:
        response = httpx.get(
            f"{base_url}/rest/v1/{table}",
            params=params,
            headers=_headers(),
            timeout=current_app.config.get("SUPABASE_RPC_TIMEOUT_SECONDS", 10.0),
        )
    except httpx.TimeoutException as exc:
        raise ApiError(504, "SUPABASE_TIMEOUT", "The database did not respond in time.") from exc
    except httpx.HTTPError as exc:
        current_app.logger.warning("PostgREST read failed for allow-listed table %s", table, exc_info=True)
        raise ApiError(503, "SUPABASE_UNAVAILABLE", "The database service is temporarily unavailable.") from exc

    if response.status_code == 401:
        raise ApiError(401, "UNAUTHORIZED", "Authentication must be refreshed before retrying this request.")
    if response.status_code == 403:
        raise ApiError(403, "FORBIDDEN", "Your application role does not permit this operation.")
    if response.status_code == 404:
        raise ApiError(404, "NOT_FOUND", "The requested resource was not found.")
    if response.status_code >= 400:
        current_app.logger.warning(
            "PostgREST query failed for table %s with HTTP %s", table, response.status_code
        )
        raise ApiError(502, "DATABASE_READ_FAILED", "The requested data could not be loaded.")

    try:
        rows = response.json()
    except ValueError as exc:
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The database returned an invalid response.") from exc
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The database returned an unexpected data format.")
    return rows


def get_master_record(resource: str, record_id: str, *, select: str) -> dict[str, Any] | None:
    if resource not in MASTER_TABLES:
        raise ValueError("Master resource is not allow-listed.")
    rows = rest_select(
        resource,
        params={"id": f"eq.{record_id}", "select": select, "limit": "1"},
    )
    return rows[0] if rows else None


def list_master_records(resource: str, *, select: str, limit: int = 100) -> list[dict[str, Any]]:
    """List a known reference catalog for server-side business validation."""
    if resource not in MASTER_TABLES:
        raise ValueError("Master resource is not allow-listed.")
    if not 1 <= limit <= 500:
        raise ValueError("Catalog limit must be from 1 to 500.")
    return rest_select(
        resource,
        params={"select": select, "limit": str(limit), "order": "id.asc"},
    )
