from __future__ import annotations

from app.services.stock_service import get_stock_balances, get_stock_ledger

MATERIAL = "10000000-0000-0000-0000-000000000001"
UNIT = "20000000-0000-0000-0000-000000000001"
CATEGORY = "30000000-0000-0000-0000-000000000001"
SHELF = "40000000-0000-0000-0000-000000000001"
WORKER_LOCATION = "40000000-0000-0000-0000-000000000002"
QUARANTINE = "40000000-0000-0000-0000-000000000003"
PARENT = "40000000-0000-0000-0000-000000000004"
TX = "50000000-0000-0000-0000-000000000001"


def test_stock_balances_only_emit_active_leaf_projection_and_subtract_reservations(monkeypatch):
    balances = [
        {"material_id": MATERIAL, "location_id": SHELF, "on_hand_quantity": "100"},
        {"material_id": MATERIAL, "location_id": WORKER_LOCATION, "on_hand_quantity": "20"},
        {"material_id": MATERIAL, "location_id": QUARANTINE, "on_hand_quantity": "5"},
        {"material_id": MATERIAL, "location_id": PARENT, "on_hand_quantity": "200"},
    ]
    locations = [
        {"id": SHELF, "location_code": "SHELF-A", "name": "Shelf A", "location_type": "STORE_SHELF", "is_leaf": True, "is_active": True},
        {"id": WORKER_LOCATION, "location_code": "WRK-A", "name": "Worker A", "location_type": "WORKER_CUSTODY", "is_leaf": True, "is_active": True},
        {"id": QUARANTINE, "location_code": "QUAR-A", "name": "Quarantine A", "location_type": "DAMAGE_QUARANTINE", "is_leaf": True, "is_active": True},
        {"id": PARENT, "location_code": "PARENT", "name": "Building", "location_type": "STORE_SHELF", "is_leaf": False, "is_active": True},
    ]
    reservations = [
        {"material_id": MATERIAL, "location_id": SHELF, "reserved_quantity": "30", "status": "ACTIVE"},
        {"material_id": MATERIAL, "location_id": QUARANTINE, "reserved_quantity": "2", "status": "ACTIVE"},
    ]

    def fake_select(table, *, params):
        if table == "material_location_balances":
            return balances
        if table == "materials":
            return [{"id": MATERIAL, "material_code": "BAG-001", "name": "Poly Bag", "category_id": CATEGORY, "canonical_unit_id": UNIT, "is_active": True}]
        if table == "locations":
            return locations
        if table == "material_categories":
            return [{"id": CATEGORY, "code": "POLY_BAG", "name": "Poly Bags", "is_active": True}]
        if table == "units":
            return [{"id": UNIT, "code": "KG", "name": "Kilogram"}]
        if table == "stock_reservations":
            return reservations
        raise AssertionError(f"Unexpected read table: {table}")

    monkeypatch.setattr("app.services.stock_service.rest_select", fake_select)

    rows = get_stock_balances()

    assert len(rows) == 3
    by_location = {row["locationId"]: row for row in rows}
    assert PARENT not in by_location
    assert by_location[SHELF]["onHandQuantity"] == 100
    assert by_location[SHELF]["reservedQuantity"] == 30
    assert by_location[SHELF]["availableQuantity"] == 70
    assert by_location[WORKER_LOCATION]["availableQuantity"] == 20
    assert by_location[QUARANTINE]["onHandQuantity"] == 5
    assert by_location[QUARANTINE]["availableQuantity"] == 0
    assert by_location[SHELF]["canonicalUnitCode"] == "KG"


def test_stock_ledger_maps_canonical_quantity_and_preserves_entered_unit(monkeypatch):
    transaction = {
        "id": TX,
        "movement_type": "LOCATION_TRANSFER",
        "material_id": MATERIAL,
        "source_location_id": SHELF,
        "destination_location_id": WORKER_LOCATION,
        "worker_id": None,
        "quantity": "2.5",
        "unit_id": UNIT,
        "entered_quantity": "2500",
        "entered_unit_id": UNIT,
        "measurement_method": "MANUALLY_COUNTED",
        "measurement_evidence": "25 packs counted",
        "conversion_factor_applied": "0.001",
        "conversion_direction": "MULTIPLY",
        "conversion_type_used": "EXACT",
        "is_estimated": False,
        "movement_reason": "test move",
        "goods_receipt_id": None,
        "packing_job_id": None,
        "production_completion_id": None,
        "stock_adjustment_id": None,
        "created_at": "2026-10-20T07:30:00Z",
    }
    captured = {}

    def fake_select(table, *, params):
        captured.setdefault(table, []).append(params)
        if table == "stock_transactions":
            return [transaction]
        if table == "materials":
            return [{"id": MATERIAL, "canonical_unit_id": UNIT}]
        raise AssertionError(f"Unexpected read table: {table}")

    monkeypatch.setattr("app.services.stock_service.rest_select", fake_select)

    rows = get_stock_ledger(material_id=MATERIAL, from_date="2026-10-20", to_date="2026-10-20", limit=10, offset=0)

    assert len(rows) == 1
    assert rows[0]["canonicalQuantity"] == 2.5
    assert rows[0]["enteredQuantity"] == 2500
    assert rows[0]["canonicalUnitId"] == UNIT
    assert rows[0]["measurementEvidence"] == "25 packs counted"
    assert captured["stock_transactions"][0]["material_id"] == f"eq.{MATERIAL}"
    assert "and" in captured["stock_transactions"][0]


def test_get_stock_balances_returns_empty_without_extra_queries(monkeypatch):
    calls = []

    def fake_select(table, *, params):
        calls.append(table)
        return []

    monkeypatch.setattr("app.services.stock_service.rest_select", fake_select)
    assert get_stock_balances(material_id=MATERIAL) == []
    assert calls == ["material_location_balances"]
