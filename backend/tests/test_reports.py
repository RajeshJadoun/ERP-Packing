from __future__ import annotations

from datetime import date, timedelta
from uuid import uuid4


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_stock_report_uses_allowlisted_view_and_validated_pagination(client, token_factory, monkeypatch):
    calls = []

    def fake_select(table, *, params):
        calls.append((table, params))
        return [{"material_code": "MAT-001", "on_hand_quantity": "25"}]

    monkeypatch.setattr("app.services.reporting_service.rest_select", fake_select)
    material_id = str(uuid4())
    response = client.get(
        f"/api/v1/reports/stock?materialId={material_id}&limit=20&offset=10",
        headers=_auth(token_factory()),
    )

    assert response.status_code == 200
    assert response.get_json() == [{"material_code": "MAT-001", "on_hand_quantity": "25"}]
    assert calls == [(
        "vw_stock_by_location",
        {
            "select": "*",
            "order": "material_code.asc,location_code.asc",
            "limit": "20",
            "offset": "10",
            "material_id": f"eq.{material_id}",
        },
    )]


def test_consumption_report_applies_inclusive_date_shift_and_worker_filters(
    client, token_factory, monkeypatch
):
    calls = []

    def fake_select(table, *, params):
        calls.append((table, params))
        return []

    monkeypatch.setattr("app.services.reporting_service.rest_select", fake_select)
    start = date.today() - timedelta(days=7)
    end = date.today()
    material_id = str(uuid4())
    worker_id = str(uuid4())
    response = client.get(
        "/api/v1/reports/consumption-variance"
        f"?fromDate={start.isoformat()}&toDate={end.isoformat()}"
        f"&shiftCode=SHIFT_1&materialId={material_id}&workerId={worker_id}",
        headers=_auth(token_factory()),
    )

    assert response.status_code == 200
    table, params = calls[0]
    assert table == "vw_material_consumption_variance"
    assert params["and"] == (
        f"(completion_date.gte.{start.isoformat()},completion_date.lte.{end.isoformat()})"
    )
    assert params["shift_code"] == "eq.SHIFT_1"
    assert params["material_id"] == f"eq.{material_id}"
    assert params["worker_id"] == f"eq.{worker_id}"


def test_report_rejects_reversed_dates_and_bad_uuid_before_query(
    client, token_factory, monkeypatch
):
    called = {"value": False}

    def fake_select(*args, **kwargs):
        called["value"] = True
        return []

    monkeypatch.setattr("app.services.reporting_service.rest_select", fake_select)
    today = date.today()
    reversed_response = client.get(
        f"/api/v1/reports/vendor-purchase-history?fromDate={(today + timedelta(days=1)).isoformat()}"
        f"&toDate={today.isoformat()}",
        headers=_auth(token_factory()),
    )
    bad_uuid_response = client.get(
        "/api/v1/reports/worker-custody?workerId=not-a-uuid",
        headers=_auth(token_factory()),
    )

    assert reversed_response.status_code == 400
    assert bad_uuid_response.status_code == 400
    assert not called["value"]


def test_report_rejects_out_of_bounds_pagination_and_unauthenticated_access(client, token_factory):
    large_limit = client.get(
        "/api/v1/reports/stock?limit=1001",
        headers=_auth(token_factory()),
    )
    missing_auth = client.get("/api/v1/reports/stock")

    assert large_limit.status_code == 400
    assert missing_auth.status_code == 401
