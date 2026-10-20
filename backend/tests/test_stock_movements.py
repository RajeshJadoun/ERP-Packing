from __future__ import annotations

from types import SimpleNamespace

import pytest

from app.errors import ApiError
from app.services.stock_service import issue_to_worker, return_from_worker, transfer_stock

TX = "50000000-0000-0000-0000-000000000001"
MATERIAL = "10000000-0000-0000-0000-000000000001"
UNIT = "20000000-0000-0000-0000-000000000001"
WORKER = "60000000-0000-0000-0000-000000000001"
JOB = "70000000-0000-0000-0000-000000000001"
SHELF = "40000000-0000-0000-0000-000000000001"
WORKER_LOCATION = "40000000-0000-0000-0000-000000000002"
BUFFER = "40000000-0000-0000-0000-000000000003"


@pytest.fixture
def idempotency():
    return SimpleNamespace(key="req_phase5_stock_move_000001", request_hash="a" * 64)


def _detail(source=SHELF, destination=BUFFER):
    return {
        "id": TX,
        "movementType": "LOCATION_TRANSFER",
        "materialId": MATERIAL,
        "sourceLocationId": source,
        "destinationLocationId": destination,
        "canonicalQuantity": 2.5,
        "canonicalUnitId": UNIT,
        "createdAt": "2026-10-20T08:00:00Z",
    }


def test_transfer_calls_authoritative_rpc_and_reads_persisted_ledger(monkeypatch, idempotency):
    captured = {}

    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"success": True, "stockTransactionId": TX, "quantity": 2.5}

    monkeypatch.setattr("app.services.stock_service.call_supabase_rpc", fake_rpc)
    monkeypatch.setattr("app.services.stock_service.get_stock_transaction", lambda _id: _detail())

    result = transfer_stock(
        {
            "material_id": MATERIAL,
            "quantity": "2500",
            "unit_id": UNIT,
            "source_location_id": SHELF,
            "destination_location_id": BUFFER,
            "reason": "move stock",
        },
        idempotency=idempotency,
    )

    assert captured["name"] == "rpc_transfer_stock"
    assert captured["params"]["p_quantity"] == "2500"
    assert captured["params"]["p_idempotency_key"] == idempotency.key
    assert result["canonicalQuantity"] == 2.5
    assert result["stockTransactionId"] == TX


def test_issue_checks_worker_custody_location_and_forwards_evidence(monkeypatch, idempotency):
    captured = {}

    def fake_worker(_table, _worker_id, *, select):
        return {"id": WORKER, "assigned_location_id": WORKER_LOCATION, "is_active": True}

    monkeypatch.setattr("app.services.master_service.get_master_record", fake_worker)

    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"success": True, "stockTransactionId": TX}

    monkeypatch.setattr("app.services.stock_service.call_supabase_rpc", fake_rpc)
    monkeypatch.setattr("app.services.stock_service.get_stock_transaction", lambda _id: _detail(SHELF, WORKER_LOCATION))

    result = issue_to_worker(
        {
            "worker_id": WORKER,
            "job_id": JOB,
            "material_id": MATERIAL,
            "source_location_id": SHELF,
            "destination_location_id": WORKER_LOCATION,
            "quantity": "12",
            "unit_id": UNIT,
            "measurement_method": "MANUALLY_COUNTED",
            "measurement_evidence": "12 pieces checked",
        },
        idempotency=idempotency,
    )

    assert captured["name"] == "rpc_issue_to_worker"
    assert captured["params"]["p_measurement_method"] == "MANUALLY_COUNTED"
    assert captured["params"]["p_measurement_evidence"] == "12 pieces checked"
    assert result["destinationLocationId"] == WORKER_LOCATION


def test_issue_rejects_forged_destination_location(monkeypatch, idempotency):
    monkeypatch.setattr(
        "app.services.master_service.get_master_record",
        lambda *_args, **_kwargs: {"id": WORKER, "assigned_location_id": WORKER_LOCATION, "is_active": True},
    )
    with pytest.raises(ApiError) as caught:
        issue_to_worker(
            {
                "worker_id": WORKER,
                "job_id": JOB,
                "material_id": MATERIAL,
                "source_location_id": SHELF,
                "destination_location_id": BUFFER,
                "quantity": "12",
                "unit_id": UNIT,
                "measurement_method": "SCALE_WEIGHED",
                "measurement_evidence": None,
            },
            idempotency=idempotency,
        )
    assert caught.value.status_code == 422


def test_return_checks_worker_source_location_and_uses_rpc_overload(monkeypatch, idempotency):
    captured = {}
    monkeypatch.setattr(
        "app.services.master_service.get_master_record",
        lambda *_args, **_kwargs: {"id": WORKER, "assigned_location_id": WORKER_LOCATION, "is_active": True},
    )

    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"success": True, "stockTransactionId": TX}

    monkeypatch.setattr("app.services.stock_service.call_supabase_rpc", fake_rpc)
    monkeypatch.setattr("app.services.stock_service.get_stock_transaction", lambda _id: _detail(WORKER_LOCATION, SHELF))

    result = return_from_worker(
        {
            "worker_id": WORKER,
            "job_id": JOB,
            "material_id": MATERIAL,
            "source_location_id": WORKER_LOCATION,
            "destination_location_id": SHELF,
            "quantity": "5",
            "unit_id": UNIT,
            "measurement_method": "SEALED_BUNDLE",
            "measurement_evidence": "1 sealed bundle, 5 pcs",
        },
        idempotency=idempotency,
    )

    assert captured["name"] == "rpc_return_from_worker"
    assert captured["params"]["p_measurement_method"] == "SEALED_BUNDLE"
    assert result["sourceLocationId"] == WORKER_LOCATION
