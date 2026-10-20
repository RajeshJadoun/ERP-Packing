from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

import pytest
from flask import g

from app.errors import ApiError
from app.idempotency import IdempotencyContext
from app.routes.production import RecordProductionCompletionInput
from app.services.production_service import (
    get_production_completion,
    record_production_completion,
    verify_production_consumption,
)

TEST_USER_ID = "cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01"


@pytest.fixture
def idem():
    return IdempotencyContext(
        key="req_phase7_production_test_01",
        owner_id=TEST_USER_ID,
        operation_scope="POST:/api/v1/production/completions",
        request_hash="b" * 64,
    )


def test_record_completion_calls_one_atomic_rpc(app, monkeypatch, idem):
    captured = {}

    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"id": str(uuid4()), "completionId": str(uuid4())}

    monkeypatch.setattr("app.services.production_service.call_supabase_rpc", fake_rpc)
    job_id, worker_id, material_id, unit_id = uuid4(), uuid4(), uuid4(), uuid4()
    payload = {
        "packing_job_id": job_id,
        "completed_units": 530,
        "worker_id": worker_id,
        "remarks": "Line A",
        "completion_policy": "CONFIRMED_ACTUAL_ENTRY",
        "actual_material_usage": [{
            "material_id": material_id,
            "physically_confirmed_quantity": Decimal("532.125"),
            "unit_id": unit_id,
            "measurement_method": "SCALE_WEIGHED",
            "measurement_evidence": "Scale slip #18",
        }],
    }

    with app.test_request_context("/api/v1/production/completions"):
        g.auth_token = "verified-caller-jwt"
        result = record_production_completion(payload, idempotency=idem)

    assert result["id"]
    assert captured["name"] == "rpc_complete_production"
    params = captured["params"]
    assert params["p_packing_job_id"] == str(job_id)
    assert params["p_completed_units"] == 530
    assert params["p_worker_id"] == str(worker_id)
    assert params["p_completion_policy"] == "CONFIRMED_ACTUAL_ENTRY"
    assert params["p_actual_material_usage"][0]["materialId"] == str(material_id)
    assert params["p_actual_material_usage"][0]["physicallyConfirmedQuantity"] == "532.125"
    assert params["p_actual_material_usage"][0]["unitId"] == str(unit_id)
    assert params["p_idempotency_key"] == idem.key


def test_auto_theoretical_completion_sends_empty_actual_usage(app, monkeypatch, idem):
    captured = {}
    monkeypatch.setattr(
        "app.services.production_service.call_supabase_rpc",
        lambda name, params: (captured.update(name=name, params=params) or {"id": str(uuid4())}),
    )
    with app.test_request_context("/api/v1/production/completions"):
        g.auth_token = "verified-caller-jwt"
        record_production_completion(
            {
                "packing_job_id": uuid4(),
                "completed_units": 530,
                "worker_id": uuid4(),
                "completion_policy": "AUTO_BOM_THEORETICAL",
                "actual_material_usage": [],
                "remarks": None,
            },
            idempotency=idem,
        )

    assert captured["params"]["p_actual_material_usage"] == []
    assert captured["params"]["p_completion_policy"] == "AUTO_BOM_THEORETICAL"


def test_verify_consumption_calls_dedicated_rpc(app, monkeypatch, idem):
    captured = {}
    monkeypatch.setattr(
        "app.services.production_service.call_supabase_rpc",
        lambda name, params: (captured.update(name=name, params=params) or {"id": params["p_completion_id"]}),
    )
    completion_id, material_id, unit_id = uuid4(), uuid4(), uuid4()
    with app.test_request_context(f"/api/v1/production/completions/{completion_id}/consumption/verify"):
        g.auth_token = "verified-caller-jwt"
        result = verify_production_consumption(
            str(completion_id),
            actual_material_usage=[{
                "material_id": material_id,
                "physically_confirmed_quantity": Decimal("0"),
                "unit_id": unit_id,
                "measurement_method": "MANUALLY_COUNTED",
                "measurement_evidence": None,
            }],
            idempotency=idem,
        )

    assert result["id"] == str(completion_id)
    assert captured["name"] == "rpc_verify_production_consumption"
    assert captured["params"]["p_actual_material_usage"][0]["physicallyConfirmedQuantity"] == "0"


def test_get_production_completion_maps_consumption_and_ledger(app, monkeypatch):
    completion_id = str(uuid4())
    transaction_id = str(uuid4())
    material_id = str(uuid4())
    unit_id = str(uuid4())
    now = datetime.now(UTC).isoformat()

    def fake_select(table, *, params):
        if table == "production_completions":
            return [{
                "id": completion_id,
                "packing_job_id": str(uuid4()),
                "completion_number": "COMP-20261020-AB12CD34",
                "completed_units": 530,
                "completed_by_worker_id": str(uuid4()),
                "completion_timestamp": now,
                "created_at": now,
                "remarks": None,
                "completion_policy": "AUTO_BOM_THEORETICAL",
            }]
        if table == "material_consumption_records":
            return [{
                "id": str(uuid4()),
                "material_id": material_id,
                "theoretical_quantity": "530.0000",
                "posted_ledger_quantity": "530.0000",
                "physically_confirmed_quantity": None,
                "physically_confirmed_unit_id": None,
                "variance_quantity": None,
                "variance_status": "UNVERIFIED",
                "physical_measurement_method": None,
                "physical_measurement_evidence": None,
                "stock_transaction_id": transaction_id,
            }]
        if table == "stock_transactions":
            return [{
                "id": transaction_id,
                "unit_id": unit_id,
                "is_estimated": True,
                "measurement_method": "AUTO_BOM_BACKFLUSH",
            }]
        raise AssertionError(f"Unexpected table {table}")

    monkeypatch.setattr("app.services.production_service.rest_select", fake_select)
    with app.test_request_context(f"/api/v1/production/completions/{completion_id}"):
        g.auth_token = "verified-caller-jwt"
        result = get_production_completion(completion_id)

    assert result["id"] == completion_id
    assert result["completedUnits"] == 530
    assert result["completionPolicy"] == "AUTO_BOM_THEORETICAL"
    assert result["consumptions"][0]["theoreticalQuantity"] == 530.0
    assert result["consumptions"][0]["varianceStatus"] == "UNVERIFIED"
    assert result["consumptions"][0]["ledgerQuantityEstimated"] is True


def test_completion_request_rejects_actual_usage_with_theoretical_policy():
    with pytest.raises(Exception):
        RecordProductionCompletionInput.model_validate({
            "packingJobId": str(uuid4()),
            "completedUnits": 530,
            "workerId": str(uuid4()),
            "completionPolicy": "AUTO_BOM_THEORETICAL",
            "actualMaterialUsage": [{
                "materialId": str(uuid4()),
                "physicallyConfirmedQuantity": 2,
                "unitId": str(uuid4()),
                "measurementMethod": "SCALE_WEIGHED",
            }],
        })


def test_invalid_completion_id_is_rejected_before_database_access(app):
    with app.test_request_context("/api/v1/production/completions/not-a-uuid"):
        with pytest.raises(ApiError) as exc:
            get_production_completion("not-a-uuid")
    assert exc.value.status_code == 400
