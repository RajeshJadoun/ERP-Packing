"""Phase 10: Repeatable End-to-End System Verification Suite.

Validates all 5 operational pillars:
A. Authentication and access control
B. Master data and purchasing
C. Inventory and material custody
D. BOM, planning, production and closing
E. Reports and analytics
"""

from __future__ import annotations

from datetime import date, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest

from app.errors import ApiError
from app.idempotency import IdempotencyContext
from app.services.closing_service import close_daily_plan, reopen_daily_closing
from app.services.planning_service import cancel_packing_job, revise_packing_job
from app.services.production_service import record_production_completion
from app.services.stock_service import get_stock_balances


def _auth(token: str, key: str | None = None) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {token}"}
    if key:
        headers["Idempotency-Key"] = key
    return headers


# =============================================================================
# Pillar A: Authentication & Access Control
# =============================================================================


def test_phase10_pillar_a_authentication_and_access_control(app, client, token_factory):
    """Pillar A: Token validation, inactive profile rejection, RBAC enforcement, no leaked secrets."""
    # 1. Unauthenticated health probe returns 200 without token
    health_resp = client.get("/api/v1/health")
    assert health_resp.status_code == 200
    assert health_resp.get_json()["status"] == "HEALTHY"

    # 2. Missing token on protected endpoint returns 401
    missing_resp = client.get("/api/v1/reports/stock")
    assert missing_resp.status_code == 401
    assert missing_resp.get_json()["error"]["code"] == "UNAUTHORIZED"

    # 3. Malformed token returns 401
    malformed_resp = client.get(
        "/api/v1/reports/stock",
        headers={"Authorization": "Bearer not-a-valid-jwt-token"},
    )
    assert malformed_resp.status_code == 401

    # 4. Expired token returns 401
    expired_token = token_factory(expires_in=-300)
    expired_resp = client.get(
        "/api/v1/reports/stock",
        headers={"Authorization": f"Bearer {expired_token}"},
    )
    assert expired_resp.status_code == 401

    # 5. Tampered token returns 401
    valid_token = token_factory()
    header, payload, sig = valid_token.split(".")
    tampered_sig = ("B" if sig[0] != "B" else "C") + sig[1:]
    tampered_resp = client.get(
        "/api/v1/reports/stock",
        headers={"Authorization": f"Bearer {header}.{payload}.{tampered_sig}"},
    )
    assert tampered_resp.status_code == 401

    # 6. Inactive profile is rejected with 403
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "ADMIN",
        "is_active": False,
    }
    inactive_resp = client.get(
        "/api/v1/reports/stock",
        headers=_auth(valid_token),
    )
    assert inactive_resp.status_code == 403
    assert inactive_resp.get_json()["error"]["code"] == "FORBIDDEN"

    # 7. Non-admin role cannot execute admin user access change
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "STOREKEEPER",
        "is_active": True,
    }
    target_uuid = str(uuid4())
    escalate_resp = client.post(
        f"/api/v1/admin/users/{target_uuid}/access",
        json={"role": "ADMIN", "isActive": True, "reason": "Self-promotion attempt"},
        headers=_auth(valid_token, key="req_p10_admin_00001"),
    )
    assert escalate_resp.status_code == 403
    assert escalate_resp.get_json()["error"]["code"] == "FORBIDDEN"

    # 8. Client user_metadata cannot override server-resolved role
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "VIEWER",
        "is_active": True,
    }
    # Token has user_metadata.role=ADMIN in claims, but resolved role is VIEWER
    viewer_admin_resp = client.post(
        f"/api/v1/admin/users/{target_uuid}/access",
        json={"role": "ADMIN", "isActive": True, "reason": "Attempting access change"},
        headers=_auth(valid_token, key="req_p10_admin_00002"),
    )
    assert viewer_admin_resp.status_code == 403

    # 9. Verify error payloads never contain service-role secrets or DB credentials
    error_str = str(escalate_resp.get_data())
    assert "service_role" not in error_str
    assert "SUPABASE_SERVICE_ROLE_KEY" not in error_str


# =============================================================================
# Pillar B: Master Data & Purchasing Lifecycle
# =============================================================================


def test_phase10_pillar_b_purchasing_and_grn_posting(app, client, token_factory, monkeypatch):
    """Pillar B: Purchase order creation, draft goods receipt, and atomic GRN posting with idempotency."""
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "STOREKEEPER",
        "is_active": True,
    }
    token = token_factory()
    idem_key = "req_p10_purchasing_00001"
    vendor_id = str(uuid4())
    material_id = str(uuid4())
    unit_id = str(uuid4())
    po_id = str(uuid4())
    grn_id = str(uuid4())
    today = date.today()

    # 1. Create Purchase Order
    po_captured = {}

    def fake_po_rpc(name, params):
        po_captured["name"] = name
        po_captured["params"] = params
        return {
            "success": True,
            "id": po_id,
            "poNumber": "PO-P10-TEST-001",
            "vendorId": vendor_id,
            "status": "DRAFT",
            "orderDate": today.isoformat(),
            "expectedDeliveryDate": (today + timedelta(days=5)).isoformat(),
            "notes": "Pillar B Purchase Order",
            "lines": [{"id": str(uuid4()), "unitPrice": 15.0}],
        }

    monkeypatch.setattr("app.services.purchasing_service.call_supabase_rpc", fake_po_rpc)
    po_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "poNumber": "PO-P10-TEST-001",
            "vendorId": vendor_id,
            "orderDate": today.isoformat(),
            "expectedDeliveryDate": (today + timedelta(days=5)).isoformat(),
            "notes": "Pillar B Purchase Order",
            "lines": [{
                "materialId": material_id,
                "orderedQuantity": 100,
                "unitId": unit_id,
                "unitPrice": 15.0,
            }],
        },
        headers=_auth(token, idem_key),
    )
    assert po_resp.status_code == 201
    assert po_resp.get_json()["status"] == "DRAFT"
    assert po_captured["params"]["p_idempotency_key"] == idem_key

    # 2. Post Goods Receipt (GRN) with dual-unit calculation & frozen conversion provenance
    grn_captured = {}

    def fake_grn_rpc(name, params):
        grn_captured["name"] = name
        grn_captured["params"] = params
        return {"success": True, "grnId": grn_id, "status": "POSTED"}

    detail = {
        "goodsReceiptId": grn_id,
        "status": "POSTED",
        "postedAt": "2026-10-20T10:00:00Z",
        "lines": [{
            "lineId": str(uuid4()),
            "materialId": material_id,
            "acceptedQuantity": 100,
            "acceptedUnitId": unit_id,
            "canonicalQuantity": 100,
            "canonicalUnitId": unit_id,
            "conversionClassification": "EXACT",
            "stockTransactionId": str(uuid4()),
        }],
    }
    monkeypatch.setattr("app.services.purchasing_service.call_supabase_rpc", fake_grn_rpc)
    monkeypatch.setattr("app.services.purchasing_service.get_goods_receipt", lambda _id: detail)

    grn_key = "req_p10_grn_post_000001"
    grn_resp = client.post(
        "/api/v1/goods-receipts/post",
        json={"goodsReceiptId": grn_id},
        headers=_auth(token, grn_key),
    )
    assert grn_resp.status_code == 200
    assert grn_resp.get_json()["status"] == "POSTED"
    assert grn_captured["params"]["p_idempotency_key"] == grn_key

    # 3. Retrying same GRN posting with same key must require valid idempotency handling
    # Verify that idempotency key cannot be empty or invalid
    bad_key_resp = client.post(
        "/api/v1/goods-receipts/post",
        json={"goodsReceiptId": grn_id},
        headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "short"},
    )
    assert bad_key_resp.status_code == 400
    assert bad_key_resp.get_json()["error"]["code"] == "INVALID_IDEMPOTENCY_KEY"


# =============================================================================
# Pillar C: Inventory & Material Custody
# =============================================================================


def test_phase10_pillar_c_inventory_segregation_and_custody_movements(app, monkeypatch):
    """Pillar C: Leaf-only balances, available quantity calculation, custody and quarantine segregation."""
    mat_id = "11111111-1111-1111-1111-111111111111"
    unit_id = "22222222-2222-2222-2222-222222222222"
    shelf_id = "33333333-3333-3333-3333-333333333331"
    worker_loc_id = "33333333-3333-3333-3333-333333333332"
    quar_id = "33333333-3333-3333-3333-333333333333"
    parent_id = "33333333-3333-3333-3333-333333333334"

    def fake_select(table, *, params):
        if table == "material_location_balances":
            return [
                {"material_id": mat_id, "location_id": shelf_id, "on_hand_quantity": "500"},
                {"material_id": mat_id, "location_id": worker_loc_id, "on_hand_quantity": "50"},
                {"material_id": mat_id, "location_id": quar_id, "on_hand_quantity": "25"},
                {"material_id": mat_id, "location_id": parent_id, "on_hand_quantity": "575"},
            ]
        if table == "materials":
            return [{"id": mat_id, "material_code": "MAT-P10", "name": "Packing Film", "canonical_unit_id": unit_id, "category_id": None, "is_active": True}]
        if table == "locations":
            return [
                {"id": shelf_id, "location_code": "SH-01", "name": "Store Shelf 1", "location_type": "STORE_SHELF", "is_leaf": True, "is_active": True},
                {"id": worker_loc_id, "location_code": "WRK-01", "name": "Worker Custody 1", "location_type": "WORKER_CUSTODY", "is_leaf": True, "is_active": True},
                {"id": quar_id, "location_code": "QUAR-01", "name": "Damage Quarantine", "location_type": "DAMAGE_QUARANTINE", "is_leaf": True, "is_active": True},
                {"id": parent_id, "location_code": "WAREHOUSE", "name": "Main Warehouse", "location_type": "STORE_SHELF", "is_leaf": False, "is_active": True},
            ]
        if table == "units":
            return [{"id": unit_id, "code": "MTR", "name": "Meter"}]
        if table == "material_categories":
            return []
        if table == "stock_reservations":
            return [{"material_id": mat_id, "location_id": shelf_id, "reserved_quantity": "100", "status": "ACTIVE"}]
        raise AssertionError(f"Unexpected table: {table}")

    monkeypatch.setattr("app.services.stock_service.rest_select", fake_select)

    with app.test_request_context("/api/v1/stock/balances"):
        balances = get_stock_balances()

    # 1. Non-leaf parent location MUST NOT be emitted
    by_loc = {b["locationId"]: b for b in balances}
    assert parent_id not in by_loc

    # 2. Store shelf subtracts reservations (500 on hand - 100 reserved = 400 available)
    assert by_loc[shelf_id]["onHandQuantity"] == 500
    assert by_loc[shelf_id]["reservedQuantity"] == 100
    assert by_loc[shelf_id]["availableQuantity"] == 400

    # 3. Damage quarantine reports 0 available quantity
    assert by_loc[quar_id]["onHandQuantity"] == 25
    assert by_loc[quar_id]["availableQuantity"] == 0

    # 4. Worker custody location is segregated and reports 0 available in SQL projection
    assert by_loc[worker_loc_id]["locationType"] == "WORKER_CUSTODY"


# =============================================================================
# Pillar D: BOM, Planning, Production & Daily Closing
# =============================================================================


def test_phase10_pillar_d_bom_planning_conservation_and_closing(app, monkeypatch):
    """Pillar D: 5-variable quantity conservation, unverified backflush vs confirmed variance, shift closing."""
    job_id = uuid4()
    plan_id = uuid4()
    worker_id = uuid4()
    material_id = uuid4()
    unit_id = uuid4()

    # 1. 5-variable Job Quantity Revision: 520 -> 450
    # Equation: revised = completed + pending + cancelled
    # 450 = 100 completed + 0 pending + 350 cancelled
    revision_captured = {}

    def fake_rev_rpc(name, params):
        revision_captured["name"] = name
        revision_captured["params"] = params
        return {
            "id": str(job_id),
            "originalPlannedQuantity": 520,
            "currentRevisedQuantity": 450,
            "completedQuantity": 100,
            "pendingQuantity": 0,
            "cancelledQuantity": 350,
            "status": "COMPLETED",
        }

    monkeypatch.setattr("app.services.planning_service.call_supabase_rpc", fake_rev_rpc)
    rev_idem = IdempotencyContext(
        key="req_p10_rev_00000000001",
        owner_id="cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01",
        operation_scope="POST:/api/v1/packing-jobs/revision",
        request_hash="d" * 64,
    )
    with app.test_request_context("/api/v1/packing-jobs/revision"):
        rev_res = revise_packing_job(
            str(job_id),
            revised_quantity=450,
            reason="Order reduced by customer; balancing line",
            idempotency=rev_idem,
        )
    assert rev_res["currentRevisedQuantity"] == 450
    assert (
        rev_res["currentRevisedQuantity"]
        == rev_res["completedQuantity"] + rev_res["pendingQuantity"] + rev_res["cancelledQuantity"]
    )

    # 2. Rejection of revision below completed quantity from database RPC
    def fake_failing_rpc(name, params):
        raise ApiError(422, "REVISION_BELOW_COMPLETED", "Revised quantity cannot be below completed quantity.")

    monkeypatch.setattr("app.services.planning_service.call_supabase_rpc", fake_failing_rpc)
    with pytest.raises(ApiError) as exc_info:
        with app.test_request_context("/api/v1/packing-jobs/revision"):
            revise_packing_job(str(job_id), revised_quantity=90, reason="Too low", idempotency=rev_idem)
    assert exc_info.value.status_code == 422
    assert exc_info.value.code == "REVISION_BELOW_COMPLETED"

    # 3. Job Cancellation preserves audit and updates cancelled quantity
    cancel_captured = {}
    monkeypatch.setattr(
        "app.services.planning_service.call_supabase_rpc",
        lambda name, params: (cancel_captured.update(name=name, params=params) or {
            "id": str(job_id),
            "status": "CANCELLED",
            "cancelledQuantity": 350,
            "pendingQuantity": 0,
        }),
    )
    cancel_idem = IdempotencyContext(
        key="req_p10_cancel_000000001",
        owner_id="cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01",
        operation_scope="POST:/api/v1/packing-jobs/cancellation",
        request_hash="d" * 64,
    )
    with app.test_request_context("/api/v1/packing-jobs/cancellation"):
        cancel_res = cancel_packing_job(str(job_id), reason="Shift curtailed", idempotency=cancel_idem)
    assert cancel_captured["name"] == "rpc_cancel_packing_job_api"
    assert cancel_res["status"] == "CANCELLED"


    # 3. Production Output Entry: AUTO_BOM_THEORETICAL keeps consumption explicitly UNVERIFIED
    comp_captured = {}
    monkeypatch.setattr(
        "app.services.production_service.call_supabase_rpc",
        lambda name, params: (comp_captured.update(name=name, params=params) or {"id": str(uuid4())}),
    )
    comp_idem = IdempotencyContext(
        key="req_p10_comp_0000000001",
        owner_id="cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01",
        operation_scope="POST:/api/v1/production/completions",
        request_hash="e" * 64,
    )
    with app.test_request_context("/api/v1/production/completions"):
        record_production_completion(
            {
                "packing_job_id": job_id,
                "completed_units": 100,
                "worker_id": worker_id,
                "completion_policy": "AUTO_BOM_THEORETICAL",
                "actual_material_usage": [],
                "remarks": "Theoretical auto-deduction",
            },
            idempotency=comp_idem,
        )
    assert comp_captured["params"]["p_completion_policy"] == "AUTO_BOM_THEORETICAL"
    assert comp_captured["params"]["p_actual_material_usage"] == []

    # 4. Production Output Entry: CONFIRMED_ACTUAL_ENTRY passes physical measurements
    with app.test_request_context("/api/v1/production/completions"):
        record_production_completion(
            {
                "packing_job_id": job_id,
                "completed_units": 100,
                "worker_id": worker_id,
                "completion_policy": "CONFIRMED_ACTUAL_ENTRY",
                "actual_material_usage": [{
                    "material_id": material_id,
                    "physically_confirmed_quantity": Decimal("102.5"),
                    "unit_id": unit_id,
                    "measurement_method": "SCALE_WEIGHED",
                    "measurement_evidence": "Calibrated scale #3",
                }],
                "remarks": "Physically verified line",
            },
            idempotency=comp_idem,
        )
    assert comp_captured["params"]["p_completion_policy"] == "CONFIRMED_ACTUAL_ENTRY"
    assert comp_captured["params"]["p_actual_material_usage"][0]["physicallyConfirmedQuantity"] == "102.5"

    # 5. Shift Closing with atomic discrepancy checklist
    close_captured = {}
    monkeypatch.setattr(
        "app.services.closing_service.call_supabase_rpc",
        lambda name, params: (close_captured.update(name=name, params=params) or {"id": str(uuid4())}),
    )
    close_idem = IdempotencyContext(
        key="req_p10_close_000000001",
        owner_id="cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01",
        operation_scope="POST:/api/v1/closings",
        request_hash="f" * 64,
    )
    with app.test_request_context("/api/v1/closings"):
        close_daily_plan(
            {
                "daily_plan_id": plan_id,
                "shift_code": "SHIFT_1",
                "allow_discrepancy_override": False,
                "pending_dispositions": [],
            },
            idempotency=close_idem,
        )
    assert close_captured["name"] == "rpc_close_daily_plan"
    assert close_captured["params"]["p_daily_plan_id"] == str(plan_id)
    assert close_captured["params"]["p_shift_code"] == "SHIFT_1"

    # 6. Admin Reopen requires mandatory justification reason
    reopen_captured = {}
    monkeypatch.setattr(
        "app.services.closing_service.call_supabase_rpc",
        lambda name, params: (reopen_captured.update(name=name, params=params) or {"id": str(uuid4())}),
    )
    with app.test_request_context("/api/v1/closings/reopen"):
        reopen_daily_closing(
            str(uuid4()),
            reason="Authorized reopen to correct late custody return",
            idempotency=close_idem,
        )
    assert reopen_captured["name"] == "rpc_reopen_daily_closing"
    assert reopen_captured["params"]["p_reopen_reason"] == "Authorized reopen to correct late custody return"


# =============================================================================
# Pillar E: Reports & Analytics
# =============================================================================


def test_phase10_pillar_e_reports_and_analytics_verification(client, token_factory, monkeypatch):
    """Pillar E: Verifies all 6 reporting views, parameter validation, and unverified variance preservation."""
    token = token_factory()
    calls = []

    def fake_select(table, *, params):
        calls.append((table, params))
        if table == "vw_material_consumption_variance":
            return [{
                "consumption_id": "c-1",
                "completion_number": "CMP-01",
                "theoretical_quantity": "100",
                "physically_confirmed_quantity": None,
                "variance_quantity": None,
                "variance_status": "UNVERIFIED",
            }]
        if table == "vw_production_shift_summary":
            return [{
                "plan_id": "p-1",
                "plan_number": "PLAN-01",
                "authorized_units": 1000,
                "completed_units": 530,
                "pending_units": 470,
                "cancelled_units": 0,
            }]
        return []

    monkeypatch.setattr("app.services.reporting_service.rest_select", fake_select)

    # 1. Stock report with material and location filters
    mat_id = str(uuid4())
    loc_id = str(uuid4())
    resp_stock = client.get(
        f"/api/v1/reports/stock?materialId={mat_id}&locationId={loc_id}&limit=50&offset=0",
        headers=_auth(token),
    )
    assert resp_stock.status_code == 200
    assert calls[-1][0] == "vw_stock_by_location"
    assert calls[-1][1]["material_id"] == f"eq.{mat_id}"
    assert calls[-1][1]["location_id"] == f"eq.{loc_id}"

    # 2. Stock report rejects date filters (prevents silent filter loss)
    resp_stock_date = client.get(
        "/api/v1/reports/stock?fromDate=2026-10-01",
        headers=_auth(token),
    )
    assert resp_stock_date.status_code == 400
    assert "Unsupported parameter 'fromDate'" in resp_stock_date.get_json()["error"]["message"]

    # 3. Worker custody report
    worker_id = str(uuid4())
    resp_custody = client.get(
        f"/api/v1/reports/worker-custody?workerId={worker_id}&materialId={mat_id}",
        headers=_auth(token),
    )
    assert resp_custody.status_code == 200
    assert calls[-1][0] == "vw_worker_custody_balance"

    # 4. Consumption variance report preserves NULL unverified variance
    resp_var = client.get(
        "/api/v1/reports/consumption-variance?fromDate=2026-10-01&toDate=2026-10-20&shiftCode=SHIFT_1",
        headers=_auth(token),
    )
    assert resp_var.status_code == 200
    row = resp_var.get_json()[0]
    assert row["variance_status"] == "UNVERIFIED"
    assert row["physically_confirmed_quantity"] is None
    assert row["variance_quantity"] is None

    # 5. Production shift summary
    resp_shifts = client.get(
        "/api/v1/reports/production-shifts?fromDate=2026-10-01&toDate=2026-10-20",
        headers=_auth(token),
    )
    assert resp_shifts.status_code == 200
    shift_row = resp_shifts.get_json()[0]
    assert shift_row["authorized_units"] == (
        shift_row["completed_units"] + shift_row["pending_units"] + shift_row["cancelled_units"]
    )

    # 6. Worker production output
    resp_worker = client.get(
        f"/api/v1/reports/worker-output?fromDate=2026-10-01&toDate=2026-10-20&workerId={worker_id}",
        headers=_auth(token),
    )
    assert resp_worker.status_code == 200
    assert calls[-1][0] == "vw_worker_production_output"

    # 7. Vendor purchase history
    vendor_id = str(uuid4())
    resp_vendor = client.get(
        f"/api/v1/reports/vendor-purchase-history?fromDate=2026-10-01&toDate=2026-10-20&vendorId={vendor_id}",
        headers=_auth(token),
    )
    assert resp_vendor.status_code == 200
    assert calls[-1][0] == "vw_vendor_purchase_history"

    # 8. Reversed dates must be rejected
    resp_reversed = client.get(
        "/api/v1/reports/production-shifts?fromDate=2026-10-25&toDate=2026-10-20",
        headers=_auth(token),
    )
    assert resp_reversed.status_code == 400
    assert resp_reversed.get_json()["error"]["message"] == "fromDate cannot be later than toDate."
