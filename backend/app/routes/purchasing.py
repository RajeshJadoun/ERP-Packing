"""Flask routes for vendor purchasing and inward goods receipts."""

from __future__ import annotations

from datetime import date
from uuid import UUID
from decimal import Decimal

from flask import Blueprint, g, jsonify
from pydantic import BaseModel, ConfigDict, Field, field_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.purchasing_service import (
    create_purchase_order,
    get_goods_receipt,
    get_purchase_order,
    post_goods_receipt,
)
from ..validation import validate_json

purchasing_bp = Blueprint("purchasing", __name__)


class PurchaseOrderLineInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    material_id: UUID = Field(alias="materialId")
    ordered_quantity: Decimal = Field(alias="orderedQuantity", gt=0)
    unit_id: UUID = Field(alias="unitId")
    unit_price: Decimal = Field(alias="unitPrice", ge=0)


class CreatePurchaseOrderInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    po_number: str = Field(alias="poNumber", min_length=3, max_length=80)
    vendor_id: UUID = Field(alias="vendorId")
    order_date: date = Field(alias="orderDate")
    expected_delivery_date: date = Field(alias="expectedDeliveryDate")
    notes: str | None = Field(default=None, max_length=2000)
    lines: list[PurchaseOrderLineInput] = Field(min_length=1, max_length=250)

    @field_validator("po_number")
    @classmethod
    def normalize_po_number(cls, value: str) -> str:
        normalized = value.strip()
        if len(normalized) < 3:
            raise ValueError("PO number must contain at least 3 non-space characters.")
        return normalized

    @field_validator("expected_delivery_date")
    @classmethod
    def delivery_not_before_order(cls, value: date, info):
        order_date = info.data.get("order_date")
        if order_date and value < order_date:
            raise ValueError("Expected delivery date cannot be earlier than the order date.")
        return value

    @field_validator("notes")
    @classmethod
    def normalize_notes(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        return normalized or None


class PostGoodsReceiptInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    goods_receipt_id: UUID = Field(alias="goodsReceiptId")


@purchasing_bp.post("/purchase-orders")
@require_role("ADMIN", "STOREKEEPER")
def create_purchase_order_route():
    request_model = validate_json(CreatePurchaseOrderInput)
    idempotency = getattr(g, "idempotency", None)
    if idempotency is None:
        raise ApiError(400, "IDEMPOTENCY_CONTEXT_MISSING", "A validated Idempotency-Key is required.")

    result = create_purchase_order(
        {
            "po_number": request_model.po_number,
            "vendor_id": request_model.vendor_id,
            "order_date": request_model.order_date,
            "expected_delivery_date": request_model.expected_delivery_date,
            "notes": request_model.notes,
            "lines": [
                {
                    "material_id": line.material_id,
                    "ordered_quantity": line.ordered_quantity,
                    "unit_id": line.unit_id,
                    "unit_price": line.unit_price,
                }
                for line in request_model.lines
            ],
        },
        idempotency=idempotency,
    )
    return jsonify(result), 201


@purchasing_bp.get("/purchase-orders/<purchase_order_id>")
def get_purchase_order_route(purchase_order_id: str):
    return jsonify(get_purchase_order(purchase_order_id)), 200


@purchasing_bp.post("/goods-receipts/post")
@require_role("ADMIN", "STOREKEEPER")
def post_goods_receipt_route():
    request_model = validate_json(PostGoodsReceiptInput)
    idempotency = getattr(g, "idempotency", None)
    if idempotency is None:
        raise ApiError(400, "IDEMPOTENCY_CONTEXT_MISSING", "A validated Idempotency-Key is required.")

    result = post_goods_receipt(str(request_model.goods_receipt_id), idempotency=idempotency)
    return jsonify(result), 200


@purchasing_bp.get("/goods-receipts/<goods_receipt_id>")
def get_goods_receipt_route(goods_receipt_id: str):
    return jsonify(get_goods_receipt(goods_receipt_id)), 200
