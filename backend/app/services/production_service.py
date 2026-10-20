"""Transactional production completion and physical consumption verification services."""

from __future__ import annotations

from decimal import Decimal
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


def _number(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(Decimal(str(value)))
    except (ValueError, TypeError, ArithmeticError) as exc:
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The database returned an invalid quantity.") from exc


def _count_payload(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "materialId": str(item["material_id"]),
            "physicallyConfirmedQuantity": str(item["physically_confirmed_quantity"]),
            "unitId": str(item["unit_id"]),
            "measurementMethod": item["measurement_method"],
            "measurementEvidence": item.get("measurement_evidence"),
        }
        for item in items
    ]


def _require_result(result: Any, *, operation: str) -> dict[str, Any]:
    if not isinstance(result, dict) or not result.get("id"):
        current_app.logger.error("%s RPC returned an invalid success payload.", operation)
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", f"The {operation} operation could not be confirmed.")
    return result


def record_production_completion(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    actual_usage = _count_payload(payload.get("actual_material_usage", []))
    result = call_supabase_rpc(
        "rpc_complete_production",
        {
            "p_packing_job_id": _required_uuid(payload["packing_job_id"], "Packing job ID"),
            "p_completed_units": payload["completed_units"],
            "p_worker_id": _required_uuid(payload["worker_id"], "Worker ID"),
            "p_remarks": payload.get("remarks"),
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
            "p_completion_policy": payload["completion_policy"],
            "p_actual_material_usage": actual_usage,
        },
    )
    return _require_result(result, operation="production completion")


def verify_production_consumption(
    completion_id: str, *, actual_material_usage: list[dict[str, Any]], idempotency: Any
) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_verify_production_consumption",
        {
            "p_completion_id": _required_uuid(completion_id, "Production completion ID"),
            "p_actual_material_usage": _count_payload(actual_material_usage),
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_result(result, operation="physical consumption verification")


def get_production_completion(completion_id: str) -> dict[str, Any]:
    normalized_id = _required_uuid(completion_id, "Production completion ID")
    completions = rest_select(
        "production_completions",
        params={
            "id": f"eq.{normalized_id}",
            "select": "id,packing_job_id,completion_number,completed_units,completed_by_worker_id,completion_timestamp,created_at,remarks,completion_policy",
            "limit": "1",
        },
    )
    if not completions:
        raise ApiError(404, "NOT_FOUND", "The production completion was not found.")
    completion = completions[0]

    rows = rest_select(
        "material_consumption_records",
        params={
            "production_completion_id": f"eq.{normalized_id}",
            "select": (
                "id,material_id,theoretical_quantity,posted_ledger_quantity,"
                "physically_confirmed_quantity,physically_confirmed_unit_id,variance_quantity,"
                "variance_status,physical_measurement_method,physical_measurement_evidence,stock_transaction_id"
            ),
            "order": "material_id.asc",
            "limit": "500",
        },
    )

    transaction_ids = sorted({str(row["stock_transaction_id"]) for row in rows if row.get("stock_transaction_id")})
    transaction_by_id: dict[str, dict[str, Any]] = {}
    if transaction_ids:
        # These IDs originate from UUID columns returned by PostgreSQL, not raw client input.
        tx_rows = rest_select(
            "stock_transactions",
            params={
                "id": f"in.({','.join(transaction_ids)})",
                "select": "id,unit_id,is_estimated,measurement_method",
                "limit": str(min(500, len(transaction_ids))),
            },
        )
        transaction_by_id = {str(row["id"]): row for row in tx_rows}

    consumptions = []
    for row in rows:
        transaction = transaction_by_id.get(str(row["stock_transaction_id"]), {})
        consumptions.append(
            {
                "id": row["id"],
                "materialId": row["material_id"],
                "theoreticalQuantity": _number(row["theoretical_quantity"]),
                "postedLedgerQuantity": _number(row["posted_ledger_quantity"]),
                "physicallyConfirmedQuantity": _number(row["physically_confirmed_quantity"]),
                "physicallyConfirmedUnitId": row.get("physically_confirmed_unit_id"),
                "varianceQuantity": _number(row["variance_quantity"]),
                "varianceStatus": row["variance_status"],
                "physicalMeasurementMethod": row.get("physical_measurement_method"),
                "physicalMeasurementEvidence": row.get("physical_measurement_evidence"),
                "stockTransactionId": row["stock_transaction_id"],
                "canonicalUnitId": transaction.get("unit_id"),
                "ledgerQuantityEstimated": transaction.get("is_estimated"),
                "backflushMeasurementMethod": transaction.get("measurement_method"),
            }
        )

    has_physical_counts = bool(consumptions) and all(
        item["physicallyConfirmedQuantity"] is not None for item in consumptions
    )
    return {
        "success": True,
        "id": completion["id"],
        "completionId": completion["id"],
        "completionNumber": completion["completion_number"],
        "packingJobId": completion["packing_job_id"],
        "completedUnits": completion["completed_units"],
        "workerId": completion["completed_by_worker_id"],
        "createdAt": completion.get("completion_timestamp") or completion.get("created_at"),
        "remarks": completion.get("remarks"),
        "completionPolicy": completion.get("completion_policy") or ("CONFIRMED_ACTUAL_ENTRY" if has_physical_counts else "AUTO_BOM_THEORETICAL"),
        "consumptions": consumptions,
    }
