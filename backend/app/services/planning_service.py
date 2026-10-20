"""Application services for daily plans, snapshots and job quantity lifecycle."""

from __future__ import annotations  # noqa: I001

from typing import Any
from uuid import UUID

from flask import current_app

from ..errors import ApiError
from ..supabase_rpc import call_supabase_rpc
from .master_service import rest_select


_PLAN_SELECT = (
    "id,plan_number,plan_date,shift_code,status,notes,released_at,created_at,"
    "packing_jobs(id,job_code,daily_plan_id,party_id,product_id,master_bom_id,"
    "assigned_worker_id,status,priority,original_planned_quantity,current_revised_quantity,"
    "completed_quantity,pending_quantity,cancelled_quantity,created_at,"
    "packing_job_bom_snapshots(id,source_bom_id,bom_version,is_customized,customization_notes,"
    "frozen_at,packing_job_bom_snapshot_lines(material_id,quantity_per_unit,unit_id,"
    "canonical_qty_per_unit,canonical_unit_id,conversion_rule_id,conversion_factor_frozen,"
    "conversion_direction,conversion_type,is_optional,notes)))"
)
_JOB_SELECT = (
    "id,job_code,daily_plan_id,party_id,product_id,master_bom_id,assigned_worker_id,status,"
    "priority,original_planned_quantity,current_revised_quantity,completed_quantity,"
    "pending_quantity,cancelled_quantity,created_at,"
    "packing_job_bom_snapshots(id,source_bom_id,bom_version,is_customized,customization_notes,"
    "frozen_at,packing_job_bom_snapshot_lines(material_id,quantity_per_unit,unit_id,"
    "canonical_qty_per_unit,canonical_unit_id,conversion_rule_id,conversion_factor_frozen,"
    "conversion_direction,conversion_type,is_optional,notes))"
)


def _required_uuid(value: str, field: str) -> str:
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError(400, "BAD_REQUEST", f"{field} must be a valid UUID.") from exc


def _job_response(row: dict[str, Any]) -> dict[str, Any]:
    snapshots = row.get("packing_job_bom_snapshots")
    # PostgREST can encode a one-to-one FK relation as an object (unique FK)
    # or as a list depending on the exposed relationship metadata/version.
    if isinstance(snapshots, dict):
        snapshot = snapshots
    elif isinstance(snapshots, list) and snapshots:
        snapshot = snapshots[0]
    else:
        snapshot = None
    frozen_lines = []
    if snapshot:
        frozen_lines = [
            {
                "materialId": line["material_id"],
                "quantityPerUnit": line["quantity_per_unit"],
                "unitId": line["unit_id"],
                "canonicalQuantityPerUnit": line["canonical_qty_per_unit"],
                "canonicalUnitId": line["canonical_unit_id"],
                "conversionRuleId": line.get("conversion_rule_id"),
                "conversionFactorFrozen": line.get("conversion_factor_frozen", 1),
                "conversionDirection": line.get("conversion_direction", "NONE"),
                "conversionClassification": line.get("conversion_type", "EXACT"),
                "isOptional": line.get("is_optional", False),
                "applicationNotes": line.get("notes"),
            }
            for line in snapshot.get("packing_job_bom_snapshot_lines", [])
        ]

    return {
        "id": row["id"],
        "jobCode": row["job_code"],
        "dailyPlanId": row["daily_plan_id"],
        "partyId": row["party_id"],
        "productId": row["product_id"],
        "masterBomId": row.get("master_bom_id"),
        "isCustomized": row.get("master_bom_id") is None,
        "assignedWorkerId": row.get("assigned_worker_id"),
        "status": row["status"],
        "priority": row.get("priority", 1),
        "quantityStatus": {
            "originalPlannedQuantity": row["original_planned_quantity"],
            "currentRevisedQuantity": row["current_revised_quantity"],
            "completedQuantity": row["completed_quantity"],
            "pendingQuantity": row["pending_quantity"],
            "cancelledQuantity": row["cancelled_quantity"],
        },
        "snapshot": (
            {
                "id": snapshot["id"],
                "sourceBomId": snapshot.get("source_bom_id"),
                "bomVersion": snapshot.get("bom_version"),
                "isCustomized": snapshot["is_customized"],
                "customizationNotes": snapshot.get("customization_notes"),
                "frozenAt": snapshot.get("frozen_at"),
                "lines": frozen_lines,
            }
            if snapshot
            else None
        ),
    }


def _daily_plan_response(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "planNumber": row.get("plan_number"),
        "planDate": row["plan_date"],
        "shiftCode": row["shift_code"],
        "status": row["status"],
        "notes": row.get("notes"),
        "releasedAt": row.get("released_at"),
        "jobs": [_job_response(job) for job in row.get("packing_jobs", [])],
    }


def _require_plan_result(result: Any, *, operation: str) -> dict[str, Any]:
    if not isinstance(result, dict) or not result.get("id"):
        current_app.logger.error("%s RPC returned an invalid success payload.", operation)
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", f"The {operation} operation could not be confirmed.")
    return result


def create_daily_plan(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    master_jobs = [
        {
            "partyId": str(job["party_id"]),
            "productId": str(job["product_id"]),
            "masterBomId": str(job["master_bom_id"]),
            "plannedQuantity": job["planned_quantity"],
        }
        for job in payload.get("master_derived_jobs", [])
    ]
    custom_jobs = [
        {
            "partyId": str(job["party_id"]),
            "productId": str(job["product_id"]),
            "plannedQuantity": job["planned_quantity"],
            "customizationNotes": job.get("customization_notes"),
            "customBomLines": [
                {
                    "materialId": str(line["material_id"]),
                    "quantityPerUnit": str(line["quantity_per_unit"]),
                    "unitId": str(line["unit_id"]),
                    "isOptional": bool(line.get("is_optional", False)),
                    "applicationNotes": line.get("application_notes"),
                }
                for line in job["custom_bom_lines"]
            ],
        }
        for job in payload.get("custom_jobs", [])
    ]
    result = call_supabase_rpc(
        "rpc_create_daily_plan",
        {
            "p_plan_date": payload["plan_date"].isoformat(),
            "p_shift_code": payload["shift_code"],
            "p_notes": payload.get("notes"),
            "p_master_derived_jobs": master_jobs,
            "p_custom_jobs": custom_jobs,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_plan_result(result, operation="daily plan creation")


def get_daily_plan(plan_id: str) -> dict[str, Any]:
    normalized_id = _required_uuid(plan_id, "Daily plan ID")
    rows = rest_select(
        "daily_plans",
        params={"id": f"eq.{normalized_id}", "select": _PLAN_SELECT, "limit": "1"},
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The daily plan was not found.")
    return _daily_plan_response(rows[0])


def release_daily_plan(plan_id: str, *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_release_daily_plan",
        {
            "p_daily_plan_id": _required_uuid(plan_id, "Daily plan ID"),
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_plan_result(result, operation="daily plan release")


def get_packing_job(job_id: str) -> dict[str, Any]:
    normalized_id = _required_uuid(job_id, "Packing job ID")
    rows = rest_select(
        "packing_jobs",
        params={"id": f"eq.{normalized_id}", "select": _JOB_SELECT, "limit": "1"},
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The packing job was not found.")
    return _job_response(rows[0])


def revise_packing_job(
    job_id: str, *, revised_quantity: int, reason: str, idempotency: Any
) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_revise_packing_job_api",
        {
            "p_packing_job_id": _required_uuid(job_id, "Packing job ID"),
            "p_revised_quantity": revised_quantity,
            "p_reason": reason,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_plan_result(result, operation="packing job revision")


def cancel_packing_job(job_id: str, *, reason: str, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_cancel_packing_job_api",
        {
            "p_packing_job_id": _required_uuid(job_id, "Packing job ID"),
            "p_reason": reason,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_plan_result(result, operation="packing job cancellation")
