"""Application services for BOM versioning; writes stay inside PostgreSQL RPCs."""

from __future__ import annotations  # noqa: I001

from decimal import Decimal
from typing import Any
from uuid import UUID

from flask import current_app

from ..errors import ApiError
from ..supabase_rpc import call_supabase_rpc
from .master_service import rest_select


_BOM_SELECT = (
    "id,bom_code,product_id,party_id,packing_variant_name,version_number,status,notes,"
    "bom_lines(material_id,quantity_per_unit,unit_id,is_optional,notes)"
)


def _required_uuid(value: str, field: str) -> str:
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError(400, "BAD_REQUEST", f"{field} must be a valid UUID.") from exc


def _bom_line_payload(line: dict[str, Any]) -> dict[str, Any]:
    quantity = line.get("quantity_per_unit")
    if isinstance(quantity, Decimal):
        quantity = str(quantity)
    return {
        "materialId": str(line["material_id"]),
        "quantityPerUnit": str(quantity),
        "unitId": str(line["unit_id"]),
        "isOptional": bool(line.get("is_optional", False)),
        "applicationNotes": line.get("application_notes"),
    }


def _bom_response(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "bomCode": row.get("bom_code"),
        "productId": row["product_id"],
        "partyId": row.get("party_id"),
        "packingVariantName": row["packing_variant_name"],
        "versionNumber": row["version_number"],
        "status": row["status"],
        "versionNotes": row.get("notes"),
        "lines": [
            {
                "materialId": line["material_id"],
                "quantityPerUnit": line["quantity_per_unit"],
                "unitId": line["unit_id"],
                "isOptional": line.get("is_optional", False),
                "applicationNotes": line.get("notes"),
            }
            for line in row.get("bom_lines", [])
        ],
    }


def _require_rpc_result(result: Any, *, operation: str) -> dict[str, Any]:
    if not isinstance(result, dict) or not result.get("id"):
        current_app.logger.error("%s RPC returned an invalid success payload.", operation)
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", f"The {operation} operation could not be confirmed.")
    return result


def create_bom(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_create_bom",
        {
            "p_product_id": str(payload["product_id"]),
            "p_party_id": str(payload["party_id"]) if payload.get("party_id") else None,
            "p_packing_variant_name": payload["packing_variant_name"],
            "p_version_notes": payload.get("version_notes"),
            "p_lines": [_bom_line_payload(line) for line in payload["lines"]],
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_rpc_result(result, operation="BOM creation")


def create_bom_version(bom_id: str, payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_create_bom_version",
        {
            "p_source_bom_id": _required_uuid(bom_id, "BOM ID"),
            "p_revision_reason": payload["revision_reason"],
            "p_lines": [_bom_line_payload(line) for line in payload["lines"]],
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_rpc_result(result, operation="BOM version creation")


def activate_bom_version(bom_id: str, *, idempotency: Any) -> dict[str, Any]:
    result = call_supabase_rpc(
        "rpc_activate_bom_version",
        {
            "p_bom_id": _required_uuid(bom_id, "BOM ID"),
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    return _require_rpc_result(result, operation="BOM activation")


def get_bom(bom_id: str) -> dict[str, Any]:
    normalized_id = _required_uuid(bom_id, "BOM ID")
    rows = rest_select(
        "boms",
        params={"id": f"eq.{normalized_id}", "select": _BOM_SELECT, "limit": "1"},
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The BOM version was not found.")
    return _bom_response(rows[0])
