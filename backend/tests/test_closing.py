from __future__ import annotations

from datetime import date
from uuid import uuid4

import pytest
from flask import g

from app.errors import ApiError
from app.idempotency import IdempotencyContext
from app.routes.closing import ExecuteDailyCloseInput, PendingDispositionInput
from app.services.closing_service import close_daily_plan, get_daily_closing, reopen_daily_closing

TEST_USER_ID = "cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01"


@pytest.fixture
def idem():
    return IdempotencyContext(
        key="req_phase7_daily_closing_test_01",
        owner_id=TEST_USER_ID,
        operation_scope="POST:/api/v1/closings",
        request_hash="c" * 64,
    )


def test_close_daily_plan_calls_atomic_rpc_with_pending_disposition(app, monkeypatch, idem):
    captured = {}
    monkeypatch.setattr(
        "app.services.closing_service.call_supabase_rpc",
        lambda name, params: (captured.update(name=name, params=params) or {"id": str(uuid4())}),
    )
    plan_id, job_id = uuid4(), uuid4()
    with app.test_request_context("/api/v1/closings"):
        g.auth_token = "verified-caller-jwt"
        result = close_daily_plan(
            {
                "daily_plan_id": plan_id,
                "shift_code": "shift_a",
                "allow_discrepancy_override": True,
                "supervisor_override_reason": "Approved by plant admin",
                "pending_dispositions": [{
                    "packing_job_id": job_id,
                    "disposition": "RESCHEDULE",
                    "reason": "Machine downtime",
                    "target_plan_date": date(2026, 10, 22),
                    "target_shift_code": "SHIFT_B",
                }],
            },
            idempotency=idem,
        )

    assert result["id"]
    assert captured["name"] == "rpc_close_daily_plan"
    params = captured["params"]
    assert params["p_daily_plan_id"] == str(plan_id)
    assert params["p_shift_code"] == "SHIFT_A"
    assert params["p_allow_discrepancy_override"] is True
    assert params["p_pending_dispositions"][0]["packingJobId"] == str(job_id)
    assert params["p_pending_dispositions"][0]["targetPlanDate"] == "2026-10-22"
    assert params["p_idempotency_key"] == idem.key


def test_closing_read_maps_totals_and_checklist(app, monkeypatch):
    closing_id, plan_id = str(uuid4()), str(uuid4())
    now = "2026-10-20T13:00:00Z"

    def fake_select(table, *, params):
        if table == "daily_closings":
            return [{
                "id": closing_id,
                "daily_plan_id": plan_id,
                "shift_code": "SHIFT_A",
                "closing_date": "2026-10-20",
                "total_planned_units": 1000,
                "total_completed_units": 530,
                "total_pending_units": 470,
                "total_cancelled_units": 0,
                "unresolved_discrepancies_count": 1,
                "override_reason": "Approved variance review",
                "closed_at": now,
                "is_reopened": False,
                "reopen_reason": None,
                "pending_dispositions": [{"packingJobId": str(uuid4()), "disposition": "CARRY_FORWARD"}],
                "discrepancy_details": [{"type": "UNVERIFIED_CONSUMPTION"}],
            }]
        if table == "packing_jobs":
            return [{"id": str(uuid4())}, {"id": str(uuid4())}]
        raise AssertionError(f"Unexpected table {table}")

    monkeypatch.setattr("app.services.closing_service.rest_select", fake_select)
    with app.test_request_context(f"/api/v1/closings/{closing_id}"):
        g.auth_token = "verified-caller-jwt"
        result = get_daily_closing(closing_id)

    assert result["id"] == closing_id
    assert result["totalPlannedUnits"] == 1000
    assert result["totalUnitsPacked"] == 530
    assert result["totalPendingUnits"] == 470
    assert result["totalJobsPlanned"] == 2
    assert result["unresolvedDiscrepanciesCount"] == 1
    assert result["discrepancyDetails"][0]["type"] == "UNVERIFIED_CONSUMPTION"


def test_reopen_closing_calls_dedicated_admin_rpc(app, monkeypatch, idem):
    captured = {}
    monkeypatch.setattr(
        "app.services.closing_service.call_supabase_rpc",
        lambda name, params: (captured.update(name=name, params=params) or {"id": params["p_daily_closing_id"]}),
    )
    closing_id = str(uuid4())
    with app.test_request_context(f"/api/v1/closings/{closing_id}/reopen"):
        g.auth_token = "verified-caller-jwt"
        result = reopen_daily_closing(
            closing_id, reason="Correcting late material return", idempotency=idem
        )

    assert result["id"] == closing_id
    assert captured["name"] == "rpc_reopen_daily_closing"
    assert captured["params"]["p_reopen_reason"] == "Correcting late material return"


def test_reschedule_requires_target_date_and_shift():
    with pytest.raises(Exception):
        PendingDispositionInput.model_validate({
            "packingJobId": str(uuid4()),
            "disposition": "RESCHEDULE",
            "reason": "Machine downtime",
        })


def test_close_override_requires_reason():
    with pytest.raises(Exception):
        ExecuteDailyCloseInput.model_validate({
            "dailyPlanId": str(uuid4()),
            "shiftCode": "shift_a",
            "allowDiscrepancyOverride": True,
        })


def test_invalid_closing_id_is_rejected_before_database_access(app):
    with app.test_request_context("/api/v1/closings/not-a-uuid"):
        with pytest.raises(ApiError) as exc:
            get_daily_closing("not-a-uuid")
    assert exc.value.status_code == 400
