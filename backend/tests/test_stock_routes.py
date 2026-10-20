from __future__ import annotations

from datetime import date, timedelta
from uuid import uuid4


def _headers(token: str, key: str = "req_phase5_stock_api_000001") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Idempotency-Key": key}


def test_stock_balance_rejects_invalid_material_filter(client, token_factory):
    response = client.get(
        "/api/v1/stock/balances?materialId=not-a-uuid",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 400
    assert response.get_json()["error"]["code"] == "BAD_REQUEST"


def test_stock_ledger_rejects_reversed_date_range(client, token_factory):
    today = date.today()
    response = client.get(
        f"/api/v1/stock/ledger?fromDate={(today + timedelta(days=1)).isoformat()}&toDate={today.isoformat()}",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 400


def test_stock_ledger_rejects_bad_limit(client, token_factory):
    response = client.get(
        "/api/v1/stock/ledger?limit=999",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 400


def test_transfer_requires_idempotency_key(client, token_factory):
    response = client.post(
        "/api/v1/stock/transfer",
        json={
            "materialId": str(uuid4()),
            "quantity": 5,
            "unitId": str(uuid4()),
            "sourceLocationId": str(uuid4()),
            "destinationLocationId": str(uuid4()),
            "reason": "Relocate stock",
        },
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 400
    assert response.get_json()["error"]["code"] == "INVALID_IDEMPOTENCY_KEY"


def test_transfer_rejects_identical_source_and_destination(client, token_factory):
    location_id = str(uuid4())
    response = client.post(
        "/api/v1/stock/transfer",
        json={
            "materialId": str(uuid4()),
            "quantity": 5,
            "unitId": str(uuid4()),
            "sourceLocationId": location_id,
            "destinationLocationId": location_id,
            "reason": "Relocate stock",
        },
        headers=_headers(token_factory()),
    )
    assert response.status_code == 422
    assert response.get_json()["error"]["code"] == "VALIDATION_ERROR"


def test_manual_issue_requires_measurement_evidence(client, token_factory):
    response = client.post(
        "/api/v1/stock/issue-to-worker",
        json={
            "workerId": str(uuid4()),
            "jobId": str(uuid4()),
            "materialId": str(uuid4()),
            "quantity": 5,
            "unitId": str(uuid4()),
            "sourceLocationId": str(uuid4()),
            "destinationLocationId": str(uuid4()),
            "measurementMethod": "MANUALLY_COUNTED",
        },
        headers=_headers(token_factory()),
    )
    assert response.status_code == 422
    assert response.get_json()["error"]["code"] == "VALIDATION_ERROR"


def test_adjustment_requires_authenticated_supervisor_attribution(app, client, token_factory, monkeypatch):
    called = {"value": False}

    def fail_if_called(*args, **kwargs):
        called["value"] = True
        raise AssertionError("Stock adjustment must reject forged supervisor attribution before RPC.")

    monkeypatch.setattr("app.routes.stock.post_stock_adjustment", fail_if_called)
    response = client.post(
        "/api/v1/stock/adjustments",
        json={
            "materialId": str(uuid4()),
            "locationId": str(uuid4()),
            "countedQuantity": 10,
            "countedUnitId": str(uuid4()),
            "adjustmentReason": "Cycle count correction",
            "supervisorApprovedBy": str(uuid4()),
        },
        headers=_headers(token_factory()),
    )
    assert response.status_code == 422
    assert called["value"] is False


def test_only_admin_can_dispose_scrap(app, client, token_factory):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "STOREKEEPER",
        "is_active": True,
    }
    response = client.post(
        "/api/v1/stock/scrap-disposal",
        json={},
        headers=_headers(token_factory()),
    )
    assert response.status_code == 403
    assert response.get_json()["error"]["code"] == "FORBIDDEN"
