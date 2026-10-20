from __future__ import annotations

from uuid import uuid4


def _headers(token: str, key: str = "req_phase6_bom_api_test_0001") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Idempotency-Key": key}


def _bom_payload() -> dict:
    return {
        "productId": str(uuid4()),
        "partyId": str(uuid4()),
        "packingVariantName": " Domestic Standard ",
        "versionNotes": " Initial recipe ",
        "lines": [
            {
                "materialId": str(uuid4()),
                "quantityPerUnit": "4.25",
                "unitId": str(uuid4()),
                "isOptional": False,
                "applicationNotes": " Apply to the top flaps ",
            }
        ],
    }


def test_create_bom_calls_atomic_rpc_with_normalized_fields(client, token_factory, monkeypatch):
    payload = _bom_payload()
    captured = {}

    def fake_create_bom(data, *, idempotency):
        captured["data"] = data
        captured["key"] = idempotency.key
        captured["scope"] = idempotency.operation_scope
        captured["hash"] = idempotency.request_hash
        return {
            "id": str(uuid4()),
            "productId": str(data["product_id"]),
            "partyId": str(data["party_id"]),
            "packingVariantName": data["packing_variant_name"],
            "versionNumber": 1,
            "status": "DRAFT",
            "lines": [{"quantityPerUnit": "4.25"}],
        }

    monkeypatch.setattr("app.routes.boms.create_bom", fake_create_bom)
    response = client.post("/api/v1/boms", json=payload, headers=_headers(token_factory()))

    assert response.status_code == 201
    assert response.get_json()["status"] == "DRAFT"
    assert captured["data"]["packing_variant_name"] == "Domestic Standard"
    assert captured["data"]["version_notes"] == "Initial recipe"
    assert captured["data"]["lines"][0]["application_notes"] == "Apply to the top flaps"
    assert captured["key"] == "req_phase6_bom_api_test_0001"
    assert captured["scope"] == "POST:/api/v1/boms"
    assert len(captured["hash"]) == 64


def test_create_bom_requires_idempotency_key(client, token_factory):
    response = client.post("/api/v1/boms", json=_bom_payload(), headers={
        "Authorization": f"Bearer {token_factory()}"
    })
    assert response.status_code == 400
    assert response.get_json()["error"]["code"] == "INVALID_IDEMPOTENCY_KEY"


def test_create_bom_rejects_non_positive_recipe_quantity(client, token_factory):
    payload = _bom_payload()
    payload["lines"][0]["quantityPerUnit"] = 0
    response = client.post("/api/v1/boms", json=payload, headers=_headers(token_factory()))
    assert response.status_code == 422
    assert response.get_json()["error"]["code"] == "VALIDATION_ERROR"


def test_operator_cannot_create_bom(app, client, token_factory):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"], "role": "OPERATOR", "is_active": True
    }
    response = client.post("/api/v1/boms", json=_bom_payload(), headers=_headers(token_factory()))
    assert response.status_code == 403


def test_create_bom_version_uses_selected_source_and_idempotency(client, token_factory, monkeypatch):
    bom_id = str(uuid4())
    payload = {"revisionReason": "Update carton tape specification", "lines": _bom_payload()["lines"]}
    captured = {}

    def fake_create(source_id, data, *, idempotency):
        captured["source_id"] = source_id
        captured["data"] = data
        captured["key"] = idempotency.key
        return {
            "id": str(uuid4()), "productId": str(uuid4()), "packingVariantName": "Domestic",
            "versionNumber": 2, "status": "DRAFT", "lines": data["lines"]
        }

    monkeypatch.setattr("app.routes.boms.create_bom_version", fake_create)
    response = client.post(
        f"/api/v1/boms/{bom_id}/new-version",
        json=payload,
        headers=_headers(token_factory(), "req_phase6_bom_version_0001"),
    )
    assert response.status_code == 201
    assert captured["source_id"] == bom_id
    assert captured["data"]["revision_reason"] == "Update carton tape specification"
    assert captured["key"] == "req_phase6_bom_version_0001"


def test_activate_bom_version_uses_transactional_rpc(client, token_factory, monkeypatch):
    bom_id = str(uuid4())
    captured = {}

    def fake_activate(source_id, *, idempotency):
        captured["id"] = source_id
        captured["key"] = idempotency.key
        return {"id": source_id, "versionNumber": 2, "status": "ACTIVE", "lines": []}

    monkeypatch.setattr("app.routes.boms.activate_bom_version", fake_activate)
    response = client.post(
        f"/api/v1/boms/{bom_id}/activate",
        headers=_headers(token_factory(), "req_phase6_bom_activate_0001"),
    )
    assert response.status_code == 200
    assert response.get_json()["status"] == "ACTIVE"
    assert captured == {"id": bom_id, "key": "req_phase6_bom_activate_0001"}


def test_get_bom_returns_authorized_detail(client, token_factory, monkeypatch):
    bom_id = str(uuid4())
    monkeypatch.setattr(
        "app.routes.boms.get_bom",
        lambda record_id: {"id": record_id, "status": "ACTIVE", "versionNumber": 1, "lines": []},
    )
    response = client.get(
        f"/api/v1/boms/{bom_id}",
        headers={"Authorization": f"Bearer {token_factory()}"},
    )
    assert response.status_code == 200
    assert response.get_json()["id"] == bom_id
