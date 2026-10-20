from __future__ import annotations

from flask import Blueprint

from app.errors import ApiError


def test_errors_include_code_request_id_and_timestamp(app, client):
    test_bp = Blueprint("error_test", __name__, url_prefix="/_errors")

    @test_bp.get("/bad")
    def bad():
        raise ApiError(409, "CONFLICT", "Request cannot be completed.")

    app.register_blueprint(test_bp)
    response = client.get("/_errors/bad", headers={"X-Request-ID": "request-12345"})

    assert response.status_code == 409
    payload = response.get_json()
    assert payload["success"] is False
    assert payload["error"]["code"] == "CONFLICT"
    assert payload["error"]["requestId"] == "request-12345"
    assert payload["error"]["timestamp"].endswith("Z")
    assert response.headers["X-Request-ID"] == "request-12345"


def test_expired_idempotency_response_has_resource_reference(app, client):
    test_bp = Blueprint("expired_test", __name__, url_prefix="/_errors")

    @test_bp.get("/expired")
    def expired():
        raise ApiError(
            410,
            "IDEMPOTENCY_RESPONSE_EXPIRED",
            "Operation completed previously.",
            extra={
                "resourceReference": {
                    "resourceType": "GOODS_RECEIPT",
                    "resourceId": "00000000-0000-0000-0000-000000000001",
                    "operationCompletedAt": "2026-10-20T00:00:00Z",
                }
            },
        )

    app.register_blueprint(test_bp)
    response = client.get("/_errors/expired")
    assert response.status_code == 410
    assert response.get_json()["error"]["resourceReference"]["resourceType"] == "GOODS_RECEIPT"
