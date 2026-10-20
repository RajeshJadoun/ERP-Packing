from __future__ import annotations

from datetime import date, timedelta
from uuid import uuid4


def _headers(token: str, key: str = "req_phase6_plan_api_test_0001") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Idempotency-Key": key}


def test_create_daily_plan_sends_repeated_master_jobs_and_custom_recipe(client, token_factory, monkeypatch):
    party_id, product_id, bom_id = str(uuid4()), str(uuid4()), str(uuid4())
    material_id, unit_id = str(uuid4()), str(uuid4())
    payload = {
        "planDate": (date.today() + timedelta(days=1)).isoformat(),
        "shiftCode": " shift_1 ",
        "notes": "  Main line ",
        "masterDerivedJobs": [
            {"partyId": party_id, "productId": product_id, "masterBomId": bom_id, "plannedQuantity": 520},
            {"partyId": party_id, "productId": product_id, "masterBomId": bom_id, "plannedQuantity": 300},
        ],
        "customJobs": [
            {
                "partyId": party_id,
                "productId": product_id,
                "plannedQuantity": 250,
                "customizationNotes": "special tape",
                "customBomLines": [{
                    "materialId": material_id, "quantityPerUnit": "2.5", "unitId": unit_id
                }],
            }
        ],
    }
    captured = {}

    def fake_create(data, *, idempotency):
        captured["data"] = data
        captured["key"] = idempotency.key
        captured["scope"] = idempotency.operation_scope
        return {
            "id": str(uuid4()),
            "planDate": data["plan_date"].isoformat(),
            "shiftCode": data["shift_code"],
            "status": "DRAFT",
            "jobs": [
                {"id": str(uuid4()), "partyId": party_id, "productId": product_id},
                {"id": str(uuid4()), "partyId": party_id, "productId": product_id},
                {"id": str(uuid4()), "partyId": party_id, "productId": product_id, "isCustomized": True},
            ],
        }

    monkeypatch.setattr("app.routes.planning.create_daily_plan", fake_create)
    response = client.post(
        "/api/v1/daily-plans",
        json=payload,
        headers=_headers(token_factory()),
    )

    assert response.status_code == 201
    assert len(response.get_json()["jobs"]) == 3
    assert captured["data"]["shift_code"] == "SHIFT_1"
    assert captured["data"]["notes"] == "Main line"
    assert len(captured["data"]["master_derived_jobs"]) == 2
    assert captured["data"]["custom_jobs"][0]["custom_bom_lines"][0]["quantity_per_unit"] == 2.5
    assert captured["scope"] == "POST:/api/v1/daily-plans"


def test_create_daily_plan_requires_at_least_one_job(client, token_factory):
    payload = {
        "planDate": (date.today() + timedelta(days=1)).isoformat(),
        "shiftCode": "SHIFT_1",
    }
    response = client.post("/api/v1/daily-plans", json=payload, headers=_headers(token_factory()))
    assert response.status_code == 422
    assert response.get_json()["error"]["code"] == "VALIDATION_ERROR"


def test_operator_cannot_create_daily_plan(app, client, token_factory):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"], "role": "OPERATOR", "is_active": True
    }
    payload = {
        "planDate": (date.today() + timedelta(days=1)).isoformat(),
        "shiftCode": "SHIFT_1",
        "masterDerivedJobs": [{
            "partyId": str(uuid4()), "productId": str(uuid4()),
            "masterBomId": str(uuid4()), "plannedQuantity": 25
        }]
    }
    response = client.post("/api/v1/daily-plans", json=payload, headers=_headers(token_factory()))
    assert response.status_code == 403


def test_release_daily_plan_uses_transactional_rpc(client, token_factory, monkeypatch):
    plan_id = str(uuid4())
    captured = {}

    def fake_release(record_id, *, idempotency):
        captured["id"] = record_id
        captured["key"] = idempotency.key
        return {"id": record_id, "status": "RELEASED", "jobs": []}

    monkeypatch.setattr("app.routes.planning.release_daily_plan", fake_release)
    response = client.post(
        f"/api/v1/daily-plans/{plan_id}/release",
        headers=_headers(token_factory(), "req_phase6_plan_release_0001"),
    )
    assert response.status_code == 200
    assert response.get_json()["status"] == "RELEASED"
    assert captured == {"id": plan_id, "key": "req_phase6_plan_release_0001"}


def test_revision_endpoint_requires_reason(client, token_factory):
    response = client.post(
        f"/api/v1/packing-jobs/{uuid4()}/revise-quantity",
        json={"revisedQuantity": 450, "reason": "   "},
        headers=_headers(token_factory(), "req_phase6_job_revision_0001"),
    )
    assert response.status_code == 422


def test_revision_endpoint_passes_quantity_and_reason_to_service(client, token_factory, monkeypatch):
    job_id = str(uuid4())
    captured = {}

    def fake_revise(record_id, *, revised_quantity, reason, idempotency):
        captured.update({
            "id": record_id, "quantity": revised_quantity, "reason": reason,
            "key": idempotency.key,
        })
        return {"id": record_id, "status": "IN_PROGRESS", "quantityStatus": {
            "originalPlannedQuantity": 520, "currentRevisedQuantity": 450,
            "completedQuantity": 100, "pendingQuantity": 350, "cancelledQuantity": 0
        }}

    monkeypatch.setattr("app.routes.planning.revise_packing_job", fake_revise)
    response = client.post(
        f"/api/v1/packing-jobs/{job_id}/revise-quantity",
        json={"revisedQuantity": 450, "reason": "Customer order reduced"},
        headers=_headers(token_factory(), "req_phase6_job_revision_0002"),
    )
    assert response.status_code == 200
    assert captured == {
        "id": job_id, "quantity": 450, "reason": "Customer order reduced",
        "key": "req_phase6_job_revision_0002"
    }
    assert response.get_json()["quantityStatus"]["pendingQuantity"] == 350


def test_cancel_job_preserves_completed_quantity(client, token_factory, monkeypatch):
    job_id = str(uuid4())
    monkeypatch.setattr(
        "app.routes.planning.cancel_packing_job",
        lambda record_id, *, reason, idempotency: {
            "id": record_id, "status": "CANCELLED",
            "quantityStatus": {
                "originalPlannedQuantity": 520, "currentRevisedQuantity": 520,
                "completedQuantity": 100, "pendingQuantity": 0, "cancelledQuantity": 420
            }
        },
    )
    response = client.post(
        f"/api/v1/packing-jobs/{job_id}/cancel",
        json={"reason": "Shift cancelled after urgent machine fault"},
        headers=_headers(token_factory(), "req_phase6_job_cancel_0001"),
    )
    assert response.status_code == 200
    status = response.get_json()["quantityStatus"]
    assert status["completedQuantity"] == 100
    assert status["pendingQuantity"] == 0
    assert status["cancelledQuantity"] == 420


def test_get_daily_plan_and_packing_job(client, token_factory, monkeypatch):
    plan_id, job_id = str(uuid4()), str(uuid4())
    monkeypatch.setattr(
        "app.routes.planning.get_daily_plan",
        lambda record_id: {"id": record_id, "planDate": "2026-10-21", "shiftCode": "SHIFT_1", "status": "DRAFT", "jobs": []},
    )
    monkeypatch.setattr(
        "app.routes.planning.get_packing_job",
        lambda record_id: {"id": record_id, "jobCode": "JOB-TEST", "quantityStatus": {}},
    )
    headers = {"Authorization": f"Bearer {token_factory()}"}
    assert client.get(f"/api/v1/daily-plans/{plan_id}", headers=headers).status_code == 200
    assert client.get(f"/api/v1/packing-jobs/{job_id}", headers=headers).status_code == 200
