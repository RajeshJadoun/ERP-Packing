"""Stock ledger queries and transactional movement service orchestration.

PostgreSQL RPCs remain the only write path for inventory movements. Reads use
explicitly allow-listed tables, caller JWTs, and the database's RLS policies.
"""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from typing import Any
from uuid import UUID, uuid4

from flask import current_app

from ..errors import ApiError
from ..supabase_rpc import call_supabase_rpc
from .master_service import rest_select

_FACILITY_NODE_TYPES = {
    "STORE_SHELF",
    "RECEIVING_BAY",
    "SHOP_FLOOR_BUFFER",
    "WORKER_CUSTODY",
    "DAMAGE_QUARANTINE",
    "DISPATCH",
}

_STOCK_TRANSACTION_FIELDS = (
    "id,movement_type,material_id,source_location_id,destination_location_id,"
    "worker_id,quantity,unit_id,entered_quantity,entered_unit_id,measurement_method,"
    "measurement_evidence,conversion_factor_applied,conversion_direction,conversion_type_used,"
    "is_estimated,movement_reason,goods_receipt_id,packing_job_id,production_completion_id,"
    "stock_adjustment_id,created_at"
)


def _normalize_uuid(value: str, label: str) -> str:
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError(400, "BAD_REQUEST", f"{label} must be a valid UUID.") from exc


def _number(value: Any) -> float:
    try:
        return float(Decimal(str(value if value is not None else 0)))
    except (ValueError, TypeError, ArithmeticError) as exc:
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The database returned an invalid quantity.") from exc


def _paged_rows(table: str, params: dict[str, str], *, page_size: int = 500) -> list[dict[str, Any]]:
    """Read a bounded catalog/query in pages so PostgREST's row limit is not silently truncated."""
    rows: list[dict[str, Any]] = []
    offset = 0
    while True:
        page_params = dict(params)
        page_params["limit"] = str(page_size)
        page_params["offset"] = str(offset)
        page = rest_select(table, params=page_params)
        rows.extend(page)
        if len(page) < page_size:
            return rows
        offset += page_size
        if offset > 100_000:
            raise ApiError(422, "QUERY_TOO_LARGE", "The requested stock query exceeds the supported result window.")


def _id_filter(values: set[str]) -> str:
    # Values come from UUID-validated query parameters or UUID columns returned
    # by PostgreSQL, so no raw client string is interpolated into PostgREST filters.
    safe_values = sorted({_normalize_uuid(value, "Database ID") for value in values})
    return f"in.({','.join(safe_values)})"


def _fetch_by_ids(table: str, ids: set[str], select: str) -> dict[str, dict[str, Any]]:
    if not ids:
        return {}
    rows = _paged_rows(
        table,
        {"select": select, "id": _id_filter(ids), "order": "id.asc"},
    )
    return {str(row["id"]): row for row in rows if row.get("id") is not None}


def _stock_balance_rows(material_id: str | None, location_id: str | None) -> list[dict[str, Any]]:
    params = {
        "select": "material_id,location_id,on_hand_quantity",
        "order": "material_id.asc,location_id.asc",
    }
    if material_id:
        params["material_id"] = f"eq.{_normalize_uuid(material_id, 'materialId')}"
    if location_id:
        params["location_id"] = f"eq.{_normalize_uuid(location_id, 'locationId')}"
    return _paged_rows("material_location_balances", params)


def get_stock_balances(
    *, material_id: str | None = None, location_id: str | None = None
) -> list[dict[str, Any]]:
    """Return balances only at active leaf facility nodes, preventing parent roll-up double counts."""
    balance_rows = _stock_balance_rows(material_id, location_id)
    material_ids = {str(row["material_id"]) for row in balance_rows}
    location_ids = {str(row["location_id"]) for row in balance_rows}
    if not balance_rows:
        return []

    materials = _fetch_by_ids(
        "materials",
        material_ids,
        "id,material_code,name,category_id,canonical_unit_id,is_active",
    )
    locations = _fetch_by_ids(
        "locations",
        location_ids,
        "id,location_code,name,location_type,is_leaf,is_active",
    )
    category_ids = {str(row["category_id"]) for row in materials.values() if row.get("category_id")}
    unit_ids = {str(row["canonical_unit_id"]) for row in materials.values() if row.get("canonical_unit_id")}
    categories = _fetch_by_ids("material_categories", category_ids, "id,code,name,is_active")
    units = _fetch_by_ids("units", unit_ids, "id,code,name")

    active_reservations = _paged_rows(
        "stock_reservations",
        {
            "select": "material_id,location_id,reserved_quantity",
            "status": "eq.ACTIVE",
            "material_id": _id_filter(material_ids),
            "location_id": _id_filter(location_ids),
            "order": "material_id.asc,location_id.asc",
        },
    )
    reserved_by_pair: dict[tuple[str, str], Decimal] = {}
    for reservation in active_reservations:
        pair = (str(reservation["material_id"]), str(reservation["location_id"]))
        reserved_by_pair[pair] = reserved_by_pair.get(pair, Decimal(0)) + Decimal(
            str(reservation["reserved_quantity"])
        )

    result: list[dict[str, Any]] = []
    for row in balance_rows:
        material_key = str(row["material_id"])
        location_key = str(row["location_id"])
        material = materials.get(material_key)
        location = locations.get(location_key)
        if not material or not location:
            current_app.logger.error(
                "Stock balance has no visible material/location master record (material=%s, location=%s)",
                material_key,
                location_key,
            )
            raise ApiError(502, "INVALID_DATABASE_RESPONSE", "A stock balance references missing master data.")
        if (
            location.get("is_active") is not True
            or location.get("is_leaf") is not True
            or location.get("location_type") not in _FACILITY_NODE_TYPES
            or material.get("is_active") is not True
        ):
            # Parent locations are never emitted; their balances would double-count
            # the leaf-node projections. Inactive masters are fail-closed.
            continue

        reserved = reserved_by_pair.get((material_key, location_key), Decimal(0))
        on_hand = Decimal(str(row["on_hand_quantity"]))
        is_quarantine = location["location_type"] == "DAMAGE_QUARANTINE"
        available = Decimal(0) if is_quarantine else max(Decimal(0), on_hand - reserved)
        category = categories.get(str(material.get("category_id")))
        unit = units.get(str(material.get("canonical_unit_id")))
        result.append(
            {
                "materialId": material_key,
                "materialCode": material["material_code"],
                "materialName": material["name"],
                "categoryName": category.get("name") if category else None,
                "locationId": location_key,
                "locationCode": location["location_code"],
                "locationType": location["location_type"],
                "onHandQuantity": _number(on_hand),
                "reservedQuantity": _number(reserved),
                "availableQuantity": _number(available),
                "canonicalUnitCode": unit.get("code") if unit else None,
                "estimatedSecondaryQuantity": None,
                "secondaryUnitCode": None,
            }
        )

    return sorted(result, key=lambda item: (item["materialCode"], item["locationCode"]))


def _transaction_detail(row: dict[str, Any], canonical_unit_id: str) -> dict[str, Any]:
    return {
        "id": row["id"],
        "movementType": row["movement_type"],
        "materialId": row["material_id"],
        "sourceLocationId": row.get("source_location_id"),
        "destinationLocationId": row.get("destination_location_id"),
        "enteredQuantity": _number(row["entered_quantity"]),
        "enteredUnitId": row["entered_unit_id"],
        "canonicalQuantity": _number(row["quantity"]),
        "canonicalUnitId": canonical_unit_id,
        "conversionFactorApplied": _number(row.get("conversion_factor_applied", 1)),
        "conversionDirection": row.get("conversion_direction", "NONE"),
        "measurementMethod": row.get("measurement_method"),
        "measurementEvidence": row.get("measurement_evidence"),
        "goodsReceiptId": row.get("goods_receipt_id"),
        "packingJobId": row.get("packing_job_id"),
        "productionCompletionId": row.get("production_completion_id"),
        "stockAdjustmentId": row.get("stock_adjustment_id"),
        "createdAt": row["created_at"],
    }


def get_stock_transaction(transaction_id: str) -> dict[str, Any]:
    transaction_id = _normalize_uuid(transaction_id, "Stock transaction ID")
    rows = rest_select(
        "stock_transactions",
        params={
            "id": f"eq.{transaction_id}",
            "select": _STOCK_TRANSACTION_FIELDS,
            "limit": "1",
        },
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The stock transaction was not found.")
    row = rows[0]
    material = _fetch_by_ids(
        "materials",
        {str(row["material_id"])},
        "id,canonical_unit_id",
    ).get(str(row["material_id"]))
    if not material or not material.get("canonical_unit_id"):
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The transaction's canonical unit could not be resolved.")
    return _transaction_detail(row, str(material["canonical_unit_id"]))


def get_stock_ledger(
    *,
    material_id: str | None = None,
    from_date: str | None = None,
    to_date: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """Return the immutable ledger in stable newest-first order with bounded pagination."""
    if not 1 <= limit <= 500:
        raise ApiError(400, "BAD_REQUEST", "limit must be between 1 and 500.")
    if not 0 <= offset <= 100_000:
        raise ApiError(400, "BAD_REQUEST", "offset must be between 0 and 100000.")

    params = {
        "select": _STOCK_TRANSACTION_FIELDS,
        "order": "created_at.desc,id.desc",
        "limit": str(limit),
        "offset": str(offset),
    }
    if material_id:
        params["material_id"] = f"eq.{_normalize_uuid(material_id, 'materialId')}"
    if from_date and to_date:
        from datetime import date, timedelta

        to_exclusive = (date.fromisoformat(to_date) + timedelta(days=1)).isoformat()
        params["and"] = f"(created_at.gte.{from_date}T00:00:00Z,created_at.lt.{to_exclusive}T00:00:00Z)"
    elif from_date:
        params["created_at"] = f"gte.{from_date}T00:00:00Z"
    elif to_date:
        from datetime import date, timedelta

        to_exclusive = (date.fromisoformat(to_date) + timedelta(days=1)).isoformat()
        params["created_at"] = f"lt.{to_exclusive}T00:00:00Z"
    rows = rest_select("stock_transactions", params=params)
    if not rows:
        return []

    materials = _fetch_by_ids(
        "materials",
        {str(row["material_id"]) for row in rows},
        "id,canonical_unit_id",
    )
    result = []
    for row in rows:
        material = materials.get(str(row["material_id"]))
        if not material or not material.get("canonical_unit_id"):
            raise ApiError(502, "INVALID_DATABASE_RESPONSE", "A transaction's canonical unit could not be resolved.")
        result.append(_transaction_detail(row, str(material["canonical_unit_id"])))
    return result


def get_worker_custody(*, worker_id: str | None = None) -> list[dict[str, Any]]:
    """Summarize physical stock at the leaf custody location assigned to each worker."""
    workers_params = {"select": "id,worker_code,name,assigned_location_id,is_active", "order": "worker_code.asc"}
    if worker_id:
        workers_params["id"] = f"eq.{_normalize_uuid(worker_id, 'workerId')}"
    workers = _paged_rows("workers", workers_params)
    if not workers:
        return []

    balances = get_stock_balances()
    workers_by_location: dict[str, list[dict[str, Any]]] = {}
    for worker in workers:
        workers_by_location.setdefault(str(worker["assigned_location_id"]), []).append(worker)

    result: list[dict[str, Any]] = []
    for balance in balances:
        if balance["locationType"] != "WORKER_CUSTODY":
            continue
        for worker in workers_by_location.get(balance["locationId"], []):
            result.append(
                {
                    "workerId": worker["id"],
                    "workerCode": worker["worker_code"],
                    "workerName": worker["name"],
                    "workerIsActive": worker["is_active"],
                    "locationId": balance["locationId"],
                    "materialId": balance["materialId"],
                    "materialCode": balance["materialCode"],
                    "materialName": balance["materialName"],
                    "onHandQuantity": balance["onHandQuantity"],
                    "reservedQuantity": balance["reservedQuantity"],
                    "availableQuantity": balance["availableQuantity"],
                    "canonicalUnitCode": balance["canonicalUnitCode"],
                }
            )
    return sorted(result, key=lambda item: (item["workerCode"], item["materialCode"]))


def _rpc_payload(result: Any) -> dict[str, Any]:
    if not isinstance(result, dict) or not result.get("stockTransactionId"):
        current_app.logger.error("Stock movement RPC returned an invalid success payload.")
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The stock movement could not be confirmed.")
    return result


def _stock_movement_response(result: Any) -> dict[str, Any]:
    response = _rpc_payload(result)
    detail = get_stock_transaction(str(response["stockTransactionId"]))
    return {
        "success": True,
        "stockTransactionId": detail["id"],
        "movementType": detail["movementType"],
        "materialId": detail["materialId"],
        "canonicalQuantity": detail["canonicalQuantity"],
        "canonicalUnitId": detail["canonicalUnitId"],
        "sourceLocationId": detail["sourceLocationId"],
        "destinationLocationId": detail["destinationLocationId"],
        "createdAt": detail["createdAt"],
    }


def _quantity(payload: dict[str, Any], field: str = "quantity") -> str:
    value = Decimal(str(payload[field]))
    if not value.is_finite() or value <= 0:
        raise ApiError(422, "VALIDATION_ERROR", f"{field} must be a finite number greater than zero.")
    return format(value, "f")


def transfer_stock(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_transfer_stock",
        {
            "p_material_id": str(payload["material_id"]),
            "p_source_location_id": str(payload["source_location_id"]),
            "p_destination_location_id": str(payload["destination_location_id"]),
            "p_quantity": _quantity(payload),
            "p_unit_id": str(payload["unit_id"]),
            "p_reason": payload["reason"],
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _stock_movement_response(result)


def _worker_location(worker_id: str) -> str:
    from .master_service import get_master_record

    worker_id = _normalize_uuid(worker_id, "workerId")
    worker = get_master_record(
        "workers",
        worker_id,
        select="id,assigned_location_id,is_active",
    )
    if not worker or worker.get("is_active") is not True:
        raise ApiError(422, "VALIDATION_ERROR", "The worker does not exist or is inactive.")
    return _normalize_uuid(worker["assigned_location_id"], "Worker custody location")


def issue_to_worker(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    custody_location = _worker_location(str(payload["worker_id"]))
    if str(payload["destination_location_id"]) != custody_location:
        raise ApiError(422, "VALIDATION_ERROR", "destinationLocationId must match the worker's assigned custody location.")
    result = call_supabase_rpc(
        "rpc_issue_to_worker",
        {
            "p_packing_job_id": str(payload["job_id"]),
            "p_worker_id": str(payload["worker_id"]),
            "p_material_id": str(payload["material_id"]),
            "p_source_location_id": str(payload["source_location_id"]),
            "p_quantity": _quantity(payload),
            "p_unit_id": str(payload["unit_id"]),
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
            "p_measurement_method": payload["measurement_method"],
            "p_measurement_evidence": payload.get("measurement_evidence"),
        },
    )
    return _stock_movement_response(result)


def return_from_worker(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    custody_location = _worker_location(str(payload["worker_id"]))
    if str(payload["source_location_id"]) != custody_location:
        raise ApiError(422, "VALIDATION_ERROR", "sourceLocationId must match the worker's assigned custody location.")
    result = call_supabase_rpc(
        "rpc_return_from_worker",
        {
            "p_packing_job_id": str(payload["job_id"]),
            "p_worker_id": str(payload["worker_id"]),
            "p_material_id": str(payload["material_id"]),
            "p_destination_location_id": str(payload["destination_location_id"]),
            "p_quantity": _quantity(payload),
            "p_unit_id": str(payload["unit_id"]),
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
            "p_measurement_method": payload["measurement_method"],
            "p_measurement_evidence": payload.get("measurement_evidence"),
        },
    )
    return _stock_movement_response(result)


def quarantine_stock(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_quarantine_stock",
        {
            "p_material_id": str(payload["material_id"]),
            "p_source_location_id": str(payload["source_location_id"]),
            "p_destination_location_id": str(payload["destination_location_id"]),
            "p_quantity": _quantity(payload),
            "p_unit_id": str(payload["unit_id"]),
            "p_worker_id": None,
            "p_packing_job_id": None,
            "p_reason": payload["reason"],
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _stock_movement_response(result)


def dispose_scrap(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_scrap_disposal",
        {
            "p_material_id": str(payload["material_id"]),
            "p_source_location_id": str(payload["source_location_id"]),
            "p_quantity": _quantity(payload),
            "p_unit_id": str(payload["unit_id"]),
            "p_reason": payload["reason"],
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _stock_movement_response(result)


def post_stock_adjustment(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    material_id = _normalize_uuid(str(payload["material_id"]), "materialId")
    material = _fetch_by_ids("materials", {material_id}, "id,canonical_unit_id,is_active").get(material_id)
    if not material or material.get("is_active") is not True:
        raise ApiError(422, "VALIDATION_ERROR", "The material does not exist or is inactive.")
    counted_unit_id = _normalize_uuid(str(payload["counted_unit_id"]), "countedUnitId")
    if counted_unit_id != str(material["canonical_unit_id"]):
        raise ApiError(
            422,
            "VALIDATION_ERROR",
            "Cycle counts must be entered in the material's canonical unit so the ledger remains unambiguous.",
        )

    adjustment_number = f"ADJ-{datetime.now(UTC):%Y%m%d}-{uuid4().hex[:8].upper()}"
    counted = Decimal(str(payload["counted_quantity"]))
    if not counted.is_finite() or counted < 0:
        raise ApiError(422, "VALIDATION_ERROR", "countedQuantity must be a finite non-negative number.")

    result = call_supabase_rpc(
        "rpc_post_stock_adjustment",
        {
            "p_adjustment_number": adjustment_number,
            "p_material_id": material_id,
            "p_location_id": _normalize_uuid(str(payload["location_id"]), "locationId"),
            "p_counted_quantity": format(counted, "f"),
            "p_reason": payload["reason"],
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    if not isinstance(result, dict) or not result.get("stockAdjustmentId"):
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The stock adjustment could not be confirmed.")
    return get_stock_adjustment(str(result["stockAdjustmentId"]), counted_unit_id=counted_unit_id)


def get_stock_adjustment(adjustment_id: str, *, counted_unit_id: str | None = None) -> dict[str, Any]:
    adjustment_id = _normalize_uuid(adjustment_id, "Stock adjustment ID")
    rows = rest_select(
        "stock_adjustments",
        params={
            "id": f"eq.{adjustment_id}",
            "select": "id,adjustment_number,material_id,location_id,counted_quantity,book_quantity,difference_quantity,reason,approved_by,created_at",
            "limit": "1",
        },
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The stock adjustment was not found.")
    row = rows[0]
    transactions = rest_select(
        "stock_transactions",
        params={
            "stock_adjustment_id": f"eq.{adjustment_id}",
            "select": "id",
            "limit": "1",
        },
    )
    if not transactions:
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The adjustment has no linked stock ledger transaction.")
    material = _fetch_by_ids("materials", {str(row["material_id"])}, "id,canonical_unit_id").get(
        str(row["material_id"])
    )
    if not material:
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The adjustment's material could not be resolved.")
    return {
        "id": row["id"],
        "materialId": row["material_id"],
        "locationId": row["location_id"],
        "countedQuantity": _number(row["counted_quantity"]),
        "countedUnitId": counted_unit_id or material["canonical_unit_id"],
        "systemQuantityBefore": _number(row["book_quantity"]),
        "varianceQuantity": _number(row["difference_quantity"]),
        "adjustmentReason": row["reason"],
        "supervisorApprovedBy": row["approved_by"],
        "stockTransactionId": transactions[0]["id"],
        "createdAt": row["created_at"],
    }
