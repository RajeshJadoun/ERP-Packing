"""Application services for vendor purchasing and inward goods receipts."""

from __future__ import annotations

from typing import Any
from uuid import UUID

from flask import current_app

from ..errors import ApiError
from ..supabase_rpc import call_supabase_rpc
from .master_service import rest_select

_PURCHASE_ORDER_SELECT = (
    "id,po_number,vendor_id,order_date,expected_delivery_date,status,remarks,"
    "purchase_order_lines(id,material_id,ordered_quantity,received_quantity,unit_id,unit_price)"
)
_GOODS_RECEIPT_SELECT = (
    "id,grn_number,vendor_id,po_id,invoice_number,invoice_date,received_date,"
    "destination_location_id,status,remarks,posted_by,posted_at,created_at,"
    "goods_receipt_lines(id,purchase_order_line_id,material_id,entered_qty,entered_unit_id,"
    "rejected_qty,rejected_unit_id,accepted_qty,canonical_quantity,canonical_unit_id,"
    "box_count,weight_kg,pcs_count,conversion_rule_id,conversion_factor_used,"
    "conversion_direction,conversion_type_used,is_estimated_conversion,"
    "rejection_conversion_rule_id,rejection_conversion_factor_used,"
    "rejection_conversion_direction,rejection_conversion_type_used,batch_lot_number)"
)


def _required_uuid(value: str, field: str) -> str:
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError(400, "BAD_REQUEST", f"{field} must be a valid UUID.") from exc


def _po_line(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "materialId": row["material_id"],
        "orderedQuantity": row["ordered_quantity"],
        "receivedQuantity": row["received_quantity"],
        "unitId": row["unit_id"],
        "unitPrice": row.get("unit_price", 0),
    }


def _purchase_order(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "poNumber": row["po_number"],
        "vendorId": row["vendor_id"],
        "status": row["status"],
        "orderDate": row["order_date"],
        "expectedDeliveryDate": row.get("expected_delivery_date"),
        "notes": row.get("remarks"),
        "lines": [_po_line(line) for line in row.get("purchase_order_lines", [])],
    }


def create_purchase_order(payload: dict[str, Any], *, idempotency: Any) -> dict[str, Any]:
    """Create header and lines atomically through the transactional database RPC."""
    lines = [
        {
            "materialId": str(line["material_id"]),
            "orderedQuantity": str(line["ordered_quantity"]),
            "unitId": str(line["unit_id"]),
            "unitPrice": str(line["unit_price"]),
        }
        for line in payload["lines"]
    ]
    result = call_supabase_rpc(
        "rpc_create_purchase_order",
        {
            "p_po_number": payload["po_number"],
            "p_vendor_id": str(payload["vendor_id"]),
            "p_order_date": payload["order_date"].isoformat(),
            "p_expected_delivery_date": payload["expected_delivery_date"].isoformat(),
            "p_remarks": payload.get("notes"),
            "p_lines": lines,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    if not isinstance(result, dict) or not result.get("id"):
        current_app.logger.error("Purchase-order RPC returned an invalid success payload.")
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The purchase order could not be confirmed.")
    return result


def get_purchase_order(purchase_order_id: str) -> dict[str, Any]:
    purchase_order_id = _required_uuid(purchase_order_id, "Purchase order ID")
    rows = rest_select(
        "purchase_orders",
        params={
            "id": f"eq.{purchase_order_id}",
            "select": _PURCHASE_ORDER_SELECT,
            "limit": "1",
        },
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The purchase order was not found.")
    return _purchase_order(rows[0])


def _goods_receipt_line(row: dict[str, Any], transaction_by_line: dict[str, str]) -> dict[str, Any]:
    return {
        "lineId": row["id"],
        "materialId": row["material_id"],
        "acceptedQuantity": row.get("accepted_qty"),
        "acceptedUnitId": row.get("entered_unit_id"),
        "canonicalQuantity": row.get("canonical_quantity"),
        "canonicalUnitId": row.get("canonical_unit_id"),
        "conversionRuleId": row.get("conversion_rule_id"),
        "conversionFactorApplied": row.get("conversion_factor_used", 1),
        "conversionDirection": row.get("conversion_direction", "NONE"),
        "conversionClassification": row.get("conversion_type_used", "EXACT"),
        "estimatedSecondaryQuantity": row.get("pcs_count"),
        "estimatedSecondaryUnitId": None,
        "stockTransactionId": transaction_by_line.get(row["id"]),
    }


def get_goods_receipt(goods_receipt_id: str) -> dict[str, Any]:
    goods_receipt_id = _required_uuid(goods_receipt_id, "Goods receipt ID")
    rows = rest_select(
        "goods_receipts",
        params={
            "id": f"eq.{goods_receipt_id}",
            "select": _GOODS_RECEIPT_SELECT,
            "limit": "1",
        },
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The goods receipt was not found.")

    row = rows[0]
    transaction_rows = rest_select(
        "stock_transactions",
        params={
            "goods_receipt_id": f"eq.{goods_receipt_id}",
            "select": "id,goods_receipt_line_id",
            "limit": "1000",
            "order": "created_at.asc",
        },
    )
    transaction_by_line = {
        tx["goods_receipt_line_id"]: tx["id"]
        for tx in transaction_rows
        if tx.get("goods_receipt_line_id")
    }

    return {
        "goodsReceiptId": row["id"],
        "grnNumber": row["grn_number"],
        "vendorId": row["vendor_id"],
        "purchaseOrderId": row.get("po_id"),
        "invoiceNumber": row["invoice_number"],
        "invoiceDate": row["invoice_date"],
        "receivedDate": row["received_date"],
        "destinationLocationId": row["destination_location_id"],
        "status": row["status"],
        "postedAt": row.get("posted_at"),
        "lines": [
            _goods_receipt_line(line, transaction_by_line)
            for line in row.get("goods_receipt_lines", [])
        ],
    }


def post_goods_receipt(goods_receipt_id: str, *, idempotency: Any) -> dict[str, Any]:
    """Post a draft GRN atomically, then return authoritative persisted calculations."""
    goods_receipt_id = _required_uuid(goods_receipt_id, "Goods receipt ID")
    result = call_supabase_rpc(
        "rpc_post_goods_receipt",
        {
            "p_grn_id": goods_receipt_id,
            "p_idempotency_key": idempotency.key,
            "p_request_hash": idempotency.request_hash,
        },
    )
    if not isinstance(result, dict):
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The goods receipt could not be confirmed.")

    detail = get_goods_receipt(goods_receipt_id)
    if detail["status"] != "POSTED" or not detail.get("postedAt"):
        raise ApiError(502, "GOODS_RECEIPT_POST_UNCONFIRMED", "The goods receipt posting could not be confirmed.")
    return {
        "goodsReceiptId": detail["goodsReceiptId"],
        "status": detail["status"],
        "postedAt": detail["postedAt"],
        "lines": detail["lines"],
    }
