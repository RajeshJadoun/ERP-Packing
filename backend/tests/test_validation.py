from __future__ import annotations

from flask import Blueprint, jsonify
from pydantic import BaseModel, Field

from app.validation import validate_json


class QuantityPayload(BaseModel):
    quantity: int = Field(gt=0)


def test_valid_json_payload_is_parsed(app, client):
    test_bp = Blueprint("validation_test", __name__, url_prefix="/_validation")

    @test_bp.post("/quantity")
    def quantity():
        parsed = validate_json(QuantityPayload)
        return jsonify({"quantity": parsed.quantity})

    app.register_blueprint(test_bp)
    response = client.post("/_validation/quantity", json={"quantity": 3})
    assert response.status_code == 200
    assert response.get_json() == {"quantity": 3}


def test_invalid_payload_returns_422_with_safe_field_details(app, client):
    test_bp = Blueprint("validation_test_422", __name__, url_prefix="/_validation")

    @test_bp.post("/quantity")
    def quantity():
        parsed = validate_json(QuantityPayload)
        return jsonify({"quantity": parsed.quantity})

    app.register_blueprint(test_bp)
    response = client.post("/_validation/quantity", json={"quantity": 0})
    assert response.status_code == 422
    assert response.get_json()["error"]["code"] == "VALIDATION_ERROR"
    assert response.get_json()["error"]["fields"][0]["field"] == "quantity"
