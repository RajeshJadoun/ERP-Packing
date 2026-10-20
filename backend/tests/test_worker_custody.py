from __future__ import annotations

from app.services.stock_service import get_worker_custody

WORKER = "60000000-0000-0000-0000-000000000001"
LOCATION = "40000000-0000-0000-0000-000000000002"


def test_worker_custody_groups_leaf_balance_by_assigned_worker(monkeypatch):
    monkeypatch.setattr(
        "app.services.stock_service._paged_rows",
        lambda table, params: [
            {
                "id": WORKER,
                "worker_code": "WRK-01",
                "name": "Worker One",
                "assigned_location_id": LOCATION,
                "is_active": True,
            }
        ] if table == "workers" else [],
    )
    monkeypatch.setattr(
        "app.services.stock_service.get_stock_balances",
        lambda: [
            {
                "materialId": "10000000-0000-0000-0000-000000000001",
                "materialCode": "BAG-01",
                "materialName": "Poly Bag",
                "locationId": LOCATION,
                "locationType": "WORKER_CUSTODY",
                "onHandQuantity": 25,
                "reservedQuantity": 5,
                "availableQuantity": 20,
                "canonicalUnitCode": "PCS",
            },
            {
                "materialId": "10000000-0000-0000-0000-000000000002",
                "materialCode": "BOX-01",
                "materialName": "Carton",
                "locationId": "40000000-0000-0000-0000-000000000001",
                "locationType": "STORE_SHELF",
                "onHandQuantity": 100,
                "reservedQuantity": 0,
                "availableQuantity": 100,
                "canonicalUnitCode": "PCS",
            },
        ],
    )

    result = get_worker_custody()

    assert len(result) == 1
    assert result[0]["workerId"] == WORKER
    assert result[0]["workerCode"] == "WRK-01"
    assert result[0]["materialCode"] == "BAG-01"
    assert result[0]["onHandQuantity"] == 25
    assert result[0]["availableQuantity"] == 20
