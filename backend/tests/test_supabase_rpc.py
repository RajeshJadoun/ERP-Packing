from __future__ import annotations

import httpx
import pytest
from flask import g

from app.errors import ApiError
from app.supabase_rpc import call_supabase_rpc


def test_rpc_forwards_verified_user_jwt_and_never_uses_service_role(app, monkeypatch):
    captured = {}

    def fake_post(url, **kwargs):
        captured["url"] = url
        captured.update(kwargs)
        return httpx.Response(
            200,
            json={"success": True, "receiptId": "00000000-0000-0000-0000-000000000001"},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr("app.supabase_rpc.httpx.post", fake_post)
    with app.test_request_context("/api/v1/goods-receipts/post"):
        g.auth_token = "verified-user-jwt"
        result = call_supabase_rpc("rpc_post_goods_receipt", {"p_grn_id": "example"})

    assert result["success"] is True
    assert captured["url"] == "https://test-project.supabase.co/rest/v1/rpc/rpc_post_goods_receipt"
    assert captured["headers"]["Authorization"] == "Bearer verified-user-jwt"
    assert captured["headers"]["apikey"] == "test-anon-key"
    assert "service_role" not in captured["headers"]["apikey"]


def test_rpc_function_name_is_validated_before_network_access(app):
    with app.test_request_context("/api/v1/test"):
        g.auth_token = "verified-user-jwt"
        with pytest.raises(ValueError):
            call_supabase_rpc("rpc_name;drop table profiles", {})


def test_idempotency_reuse_error_is_generic(app, monkeypatch):
    def fake_post(url, **kwargs):
        return httpx.Response(
            409,
            json={"message": "IDEMPOTENCY_KEY_REUSED: PRIVATE_CACHED_BODY", "details": "sensitive"},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr("app.supabase_rpc.httpx.post", fake_post)
    with app.test_request_context("/api/v1/test"):
        g.auth_token = "verified-user-jwt"
        with pytest.raises(ApiError) as caught:
            call_supabase_rpc("rpc_example", {})

    assert caught.value.status_code == 409
    assert caught.value.code == "IDEMPOTENCY_KEY_REUSED"
    assert "PRIVATE_CACHED_BODY" not in caught.value.message
    assert "sensitive" not in caught.value.message


def test_expired_idempotency_response_maps_to_410_with_camel_case_reference(app, monkeypatch):
    reference = (
        '{"action":"EXPIRED","resource_type":"GOODS_RECEIPT",'
        '"resource_id":"00000000-0000-0000-0000-000000000001",'
        '"operation_completed_at":"2026-10-20T00:00:00Z"}'
    )

    def fake_post(url, **kwargs):
        return httpx.Response(
            400,
            json={"message": f"IDEMPOTENCY_RESPONSE_EXPIRED: {reference}"},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr("app.supabase_rpc.httpx.post", fake_post)
    with app.test_request_context("/api/v1/test"):
        g.auth_token = "verified-user-jwt"
        with pytest.raises(ApiError) as caught:
            call_supabase_rpc("rpc_example", {})

    assert caught.value.status_code == 410
    assert caught.value.code == "IDEMPOTENCY_RESPONSE_EXPIRED"
    assert caught.value.extra["resourceReference"] == {
        "resourceType": "GOODS_RECEIPT",
        "resourceId": "00000000-0000-0000-0000-000000000001",
        "operationCompletedAt": "2026-10-20T00:00:00Z",
    }


def test_rpc_requires_verified_user_context(app):
    with app.test_request_context("/api/v1/test"):
        with pytest.raises(ApiError) as caught:
            call_supabase_rpc("rpc_example", {})
    assert caught.value.status_code == 401
