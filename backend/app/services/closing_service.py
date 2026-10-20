"""Shift-closing transaction services."""

from __future__ import annotations

from typing import Any
from uuid import UUID

from flask import current_app

from ..errors import ApiError
from ..supabase_rpc import call_supabase_rpc
from .master_service import rest_select


def _required_uuid(value: str, field: str) -> str:
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError(400, "BAD_REQUEST", f"{field} must be a valid UUID.") from exc


def _require_result(result: Any, *, operation: str) -> dict[str, Any]:
    if not isinstance(result, dict) or not result.get("id"):
        current_app.logger.error("%s RPC returned an invalid success payload.", operation)
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", f"The {operation} operation could not be confirmed.")
    return result


def _normalise_disposition(item: dict[str, Any]) -> dict[str, Any]:
    result = {
        "packingJobId": str(item["packing_job_id"]),
        "disposition": item["disposition"],
        "reason": item.get("reason"),
    }
    if item.get("target_plan_date") is not None:
        result["targetPlanDate"] = item["target_plan_date"].isoformat()
    if item.get("target_shift_code") is not None:
        result["targetShiftCode"] = item["target_shift_code"]
    return result


def close_daily_plan(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    dispositions = [_normalise_disposition(item) for item in payload.get("pending_dispositions", [])]
    result = call_supabase_rpc(
        "rpc_close_daily_plan",
        {
            "p_daily_plan_id": _required_uuid(payload["daily_plan_id"], "Daily plan ID"),
            "p_shift_code": payload["shift_code"].strip().upper(),
            "p_allow_discrepancy_override": bool(payload.get("allow_discrepancy_override", False)),
            "p_supervisor_override_reason": payload.get("supervisor_override_reason"),
            "p_pending_dispositions": dispositions,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_result(result, operation="daily closing")


def get_daily_closing(closing_id: str) -> dict[str, Any]:
    normalized_id = _required_uuid(closing_id, "Daily closing ID")
    rows = rest_select(
        "daily_closings",
        params={
            "id": f"eq.{normalized_id}",
            "select": (
                "id,daily_plan_id,shift_code,closing_date,total_planned_units,total_completed_units,"
                "total_pending_units,total_cancelled_units,unresolved_discrepancies_count,"
                "override_reason,closed_at,is_reopened,reopen_reason,pending_dispositions,discrepancy_details"
            ),
            "limit": "1",
        },
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The daily closing was not found.")
    row = rows[0]
    jobs = rest_select(
        "packing_jobs",
        params={
            "daily_plan_id": f"eq.{row['daily_plan_id']}",
            "select": "id",
            "limit": "500",
        },
    )
    return {
        "success": True,
        "id": row["id"],
        "dailyPlanId": row["daily_plan_id"],
        "shiftCode": row["shift_code"],
        "closingDate": row["closing_date"],
        "totalPlannedUnits": row["total_planned_units"],
        "totalCompletedUnits": row["total_completed_units"],
        "totalPendingUnits": row["total_pending_units"],
        "totalCancelledUnits": row["total_cancelled_units"],
        "totalJobsPlanned": len(jobs),
        "totalUnitsPacked": row["total_completed_units"],
        "unresolvedDiscrepanciesCount": row["unresolved_discrepancies_count"],
        "supervisorOverrideReason": row.get("override_reason"),
        "closedAt": row["closed_at"],
        "isReopened": row["is_reopened"],
        "reopenReason": row.get("reopen_reason"),
        "pendingDispositions": row.get("pending_dispositions") or [],
        "discrepancyDetails": row.get("discrepancy_details") or [],
    }


def reopen_daily_closing(closing_id: str, *, reason: str, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_reopen_daily_closing",
        {
            "p_daily_closing_id": _required_uuid(closing_id, "Daily closing ID"),
            "p_reopen_reason": reason,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_result(result, operation="daily closing reopen")
