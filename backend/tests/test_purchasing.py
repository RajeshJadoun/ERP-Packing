from __future__ import annotations

from datetime import date, timedelta
from uuid import uuid4

import pytest
from flask import g

from app.errors import ApiError


def _headers(token: str, key: str = "req_phase4_api_test_000001") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Idempotency-Key": key}


def _po_payload() -> dict:
    today = date.today()
    return {
        "poNumber": "PO-API-TEST-1001",
        "vendorId": str(uuid4()),
        "orderDate": today.isoformat(),
        "expectedDeliveryDate": (today + timedelta(days=7)).isoformat(),
        "notes": "  Urgent packaging materials  ",
        "lines": [
            {
                "materialId": str(uuid4()),
                "orderedQuantity": 25,
                "unitId": str(uuid4()),
                "unitPrice": 12.5,
            }
        ],
    }


def test_create_purchase_order_uses_transactional_rpc(client, token_factory, monkeypatch):
    token = token_factory()
    captured = {}

    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {
            "success": True,
            "id": str(uuid4()),
            "poNumber": "PO-API-TEST-1001",
            "vendorId": params["p_vendor_id"],
            "status": "DRAFT",
            "orderDate": params["p_order_date"],
            "expectedDeliveryDate": params["p_expected_delivery_date"],
            "notes": params["p_remarks"],
            "lines": [{"id": str(uuid4()), "unitPrice": 12.5}],
        }

    monkeypatch.setattr("app.services.purchasing_service.call_supabase_rpc", fake_rpc)
    payload = _po_payload()
    response = client.post(
        "/api/v1/purchase-orders",
        json=payload,
        headers=_headers(token),
    )

    assert response.status_code == 201
    assert response.get_json()["status"] == "DRAFT"
    assert captured["name"] == "rpc_create_purchase_order"
    assert captured["params"]["p_po_number"] == payload["poNumber"]
    assert captured["params"]["p_lines"][0]["unitPrice"] == "12.5"
    assert captured["params"]["p_remarks"] == "Urgent packaging materials"
    assert captured["params"]["p_idempotency_key"] == "req_phase4_api_test_000001"
    assert len(captured["params"]["p_request_hash"]) == 64


def test_create_purchase_order_requires_idempotency_key(client, token_factory):
    response = client.post(
        "/api/v1/purchase-orders",
        json=_po_payload(),
        headers={"Authorization": f"Bearer {token_factory()}},
    )
    assert response.status_code == 400
    assert response.get_json()["error"]["code"] == "INVALID_IDEMPOTENCY_KEY"


def test_create_purchase_order_rejects_bad_delivery_date(client, token_factory):
    today = date.today()
    payload = _po_payload()
    payload["orderDate"] = today.isoformat()
    payload["expectedDeliveryDate"] = (today - timedelta(days=1)).isoformat()
    response = client.post(
        "/api/v1/purchase-orders",
        json=payload,
        headers=_headers(token_factory()),
    )
    assert response.status_code == 422
    assert response.get_json()["error"]["code"] == "VALIDATION_ERROR"


def test_operator_cannot_create_purchase_order(app, client, token_factory):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "OPERATOR",
        "is_active": True,
    }
    response = client.post(
        "/api/v1/purchase-orders",
        json=_po_payload(),
        headers=_headers(token_factory()),
    )
    assert response.status_code == 403
    assert response.get_json()["error"]["code"] == "FORBIDDEN"


def test_get_purchase_order_reads_using_caller_scoped_postgrest(client, token_factory, monkeypatch):
    po_id = str(uuid4())
    line_id = str(uuid4())
    vendor_id = str(uuid4())
    material_id = str(uuid4())
    unit_id = str(uuid4())
    captured = {}

    def fake_select(table, *, params):
        captured["table"] = table
        captured["params"] = params
        return [{
            "id": po_id,
            "po_number": "PO-API-GET-01",
            "vendor_id": vendor_id,
            "order_date": "2026-10-20",
            "expected_delivery_date": "2026-10-27",
            "status": "DRAFT",
            "remarks": "test PO",
            "purchase_order_lines": [{
                "id": line_id,
                "material_id": material_id,
                "ordered_quantity": 25,
                "received_quantity": 0,
                "unit_id": unit_id,
                "unit_price": 12.5,
            }],
        }]

    monkeypatch.setattr("app.services.purchasing_service.rest_select", fake_select)
    response = client.get(
        f"/api/v1/purchase-orders/{po_id}",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )

    assert response.status_code == 200
    payload = response.get_json()
    assert payload["poNumber"] == "PO-API-GET-01"
    assert payload["lines"][0]["unitPrice"] == 12.5
    assert captured["table"] == "purchase_orders"
    assert captured["params"]["id"] == f"eq.{po_id}"
    assert "Authorization" not in captured["params"]


def test_get_purchase_order_rejects_invalid_uuid(client, token_factory):
    response = client.get(
        "/api/v1/purchase-orders/not-a-uuid",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 400
    assert response.get_json()["error"]["code"] == "BAD_REQUEST"


def test_post_goods_receipt_calls_rpc_and_returns_authoritative_detail(
    client, token_factory, monkeypatch
):
    grn_id = str(uuid4())
    captured = {}

    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"success": True, "grnId": grn_id, "status": "POSTED"}

    detail = {
        "goodsReceiptId": grn_id,
        "status": "POSTED",
        "postedAt": "2026-10-20T07:00:00Z",
        "lines": [{
            "lineId": str(uuid4()),
            "materialId": str(uuid4()),
            "acceptedQuantity": 5000,
            "acceptedUnitId": str(uuid4()),
            "canonicalQuantity": 25,
            "canonicalUnitId": str(uuid4()),
            "conversionClassification": "EXACT",
            "stockTransactionId": str(uuid4()),
        }],
    }
    monkeypatch.setattr("app.services.purchasing_service.call_supabase_rpc", fake_rpc)
    monkeypatch.setattr("app.services.purchasing_service.get_goods_receipt", lambda _id: detail)

    response = client.post(
        "/api/v1/goods-receipts/post",
        json={"goodsReceiptId": grn_id},
        headers=_headers(token_factory(), "req_phase4_grn_post_00001"),
    )

    assert response.status_code == 200
    assert response.get_json()["lines"][0]["canonicalQuantity"] == 25
    assert captured["name"] == "rpc_post_goods_receipt"
    assert captured["params"]["p_grn_id"] == grn_id
    assert captured["params"]["p_idempotency_key"] == "req_phase4_grn_post_00001"


def test_get_goods_receipt_not_found(client, token_factory, monkeypatch):
    def fake_select(table, *, params):
        if table == "goods_receipts":
            return []
        raise AssertionError("No child query should be made without a GRN header.")

    monkeypatch.setattr("app.services.purchasing_service.rest_select", fake_select)
    response = client.get(
        f"/api/v1/goods-receipts/{uuid4()}",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 404
    assert response.get_json()["error"]["code"] == "NOT_FOUND"
