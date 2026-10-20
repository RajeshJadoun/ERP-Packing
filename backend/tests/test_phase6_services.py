from __future__ import annotations

from datetime import date
from decimal import Decimal
from uuid import uuid4

import pytest
from flask import g

from app.errors import ApiError
from app.idempotency import IdempotencyContext
from app.services.bom_service import activate_bom_version, create_bom, create_bom_version
from app.services.planning_service import create_daily_plan, release_daily_plan


@pytest.fixture
def idem():
    return IdempotencyContext(
        key="req_phase6_service_test_0001",
        owner_id="cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01",
        operation_scope="POST:/api/v1/example",
        request_hash="a" * 64,
    )


def test_create_bom_calls_phase6_rpc(app, monkeypatch, idem):
    captured = {}
    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"id": str(uuid4()), "status": "DRAFT", "lines": []}

    monkeypatch.setattr("app.services.bom_service.call_supabase_rpc", fake_rpc)
    product_id, material_id, unit_id = uuid4(), uuid4(), uuid4()
    with app.test_request_context("/api/v1/boms"):
        g.auth_token = "verified-caller-jwt"
        result = create_bom(
            {
                "product_id": product_id,
                "party_id": None,
                "packing_variant_name": "Domestic",
                "version_notes": None,
                "lines": [{
                    "material_id": material_id,
                    "quantity_per_unit": Decimal("4.25"),
                    "unit_id": unit_id,
                    "is_optional": False,
                    "application_notes": None,
                }],
            },
            idempotency=idem,
        )

    assert result["status"] == "DRAFT"
    assert captured["name"] == "rpc_create_bom"
    assert captured["params"]["p_product_id"] == str(product_id)
    assert captured["params"]["p_party_id"] is None
    assert captured["params"]["p_lines"][0]["quantityPerUnit"] == "4.25"
    assert captured["params"]["p_idempotency_key"] == idem.key


def test_bom_version_and_activation_rpc_names(app, monkeypatch, idem):
    names = []
    monkeypatch.setattr(
        "app.services.bom_service.call_supabase_rpc",
        lambda name, params: (names.append((name, params)) or {
            "id": str(uuid4()), "status": "DRAFT", "lines": []
        }),
    )
    bom_id = str(uuid4())
    with app.test_request_context("/api/v1/boms"):
        g.auth_token = "verified-caller-jwt"
        create_bom_version(bom_id, {"revision_reason": "changed spec", "lines": []}, idempotency=idem)
        activate_bom_version(bom_id, idempotency=idem)
    assert names[0][0] == "rpc_create_bom_version"
    assert names[1][0] == "rpc_activate_bom_version"


def test_create_daily_plan_calls_single_atomic_rpc(app, monkeypatch, idem):
    captured = {}
    def fake_rpc(name, params):
        captured["name"] = name
        captured["params"] = params
        return {"id": str(uuid4()), "status": "DRAFT", "jobs": []}

    monkeypatch.setattr("app.services.planning_service.call_supabase_rpc", fake_rpc)
    party_id, product_id, bom_id = uuid4(), uuid4(), uuid4()
    with app.test_request_context("/api/v1/daily-plans"):
        g.auth_token = "verified-caller-jwt"
        result = create_daily_plan(
            {
                "plan_date": date(2026, 10, 21),
                "shift_code": "SHIFT_1",
                "notes": None,
                "master_derived_jobs": [{
                    "party_id": party_id, "product_id": product_id, "master_bom_id": bom_id,
                    "planned_quantity": 520,
                }],
                "custom_jobs": [],
            },
            idempotency=idem,
        )
    assert result["status"] == "DRAFT"
    assert captured["name"] == "rpc_create_daily_plan"
    assert captured["params"]["p_master_derived_jobs"][0]["masterBomId"] == str(bom_id)
    assert captured["params"]["p_custom_jobs"] == []


def test_plan_release_calls_atomic_rpc(app, monkeypatch, idem):
    plan_id = str(uuid4())
    monkeypatch.setattr(
        "app.services.planning_service.call_supabase_rpc",
        lambda name, params: {"id": params["p_daily_plan_id"], "status": "RELEASED", "jobs": []},
    )
    with app.test_request_context("/api/v1/daily-plans/example/release"):
        g.auth_token = "verified-caller-jwt"
        result = release_daily_plan(plan_id, idempotency=idem)
    assert result["id"] == plan_id


def test_services_reject_invalid_ids(app):
    with app.test_request_context("/api/v1/boms"):
        with pytest.raises(ApiError):
            activate_bom_version("not-a-uuid", idempotency=None)


def test_daily_plan_read_handles_one_to_one_snapshot_object(app, monkeypatch):
    from app.services.planning_service import get_packing_job

    plan_id, job_id, snapshot_id = str(uuid4()), str(uuid4()), str(uuid4())
    monkeypatch.setattr(
        "app.services.planning_service.rest_select",
        lambda table, *, params: [{
            "id": job_id,
            "job_code": "JOB-PHASE6-TEST",
            "daily_plan_id": plan_id,
            "party_id": str(uuid4()),
            "product_id": str(uuid4()),
            "master_bom_id": None,
            "status": "DRAFT",
            "priority": 1,
            "original_planned_quantity": 20,
            "current_revised_quantity": 20,
            "completed_quantity": 0,
            "pending_quantity": 20,
            "cancelled_quantity": 0,
            "packing_job_bom_snapshots": {
                "id": snapshot_id,
                "source_bom_id": None,
                "bom_version": None,
                "is_customized": True,
                "customization_notes": "Custom wrap",
                "frozen_at": "2026-10-20T00:00:00Z",
                "packing_job_bom_snapshot_lines": [{
                    "material_id": str(uuid4()),
                    "quantity_per_unit": 2,
                    "unit_id": str(uuid4()),
                    "canonical_qty_per_unit": 2,
                    "canonical_unit_id": str(uuid4()),
                    "conversion_rule_id": None,
                    "conversion_factor_frozen": 1,
                    "conversion_direction": "NONE",
                    "conversion_type": "EXACT",
                    "is_optional": False,
                    "notes": "Protect corners",
                }],
            },
        }],
    )
    with app.test_request_context("/api/v1/packing-jobs/example"):
        g.auth_token = "verified-caller-jwt"
        result = get_packing_job(job_id)

    assert result["snapshot"]["id"] == snapshot_id
    assert result["snapshot"]["isCustomized"] is True
    assert result["snapshot"]["lines"][0]["applicationNotes"] == "Protect corners"
