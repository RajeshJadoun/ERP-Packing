from __future__ import annotations

import httpx
import pytest
from flask import g

from app.errors import ApiError
from app.services.master_service import get_master_record, list_master_records, rest_select


def test_master_get_forwards_verified_user_jwt_and_public_key(app, monkeypatch):
    captured = {}

    def fake_get(url, **kwargs):
        captured["url"] = url
        captured.update(kwargs)
        return httpx.Response(
            200,
            json=[{"id": "cat-1", "code": "DYNAMIC_TEST", "name": "Dynamic Test"}],
            request=httpx.Request("GET", url),
        )

    monkeypatch.setattr("app.services.master_service.httpx.get", fake_get)
    with app.test_request_context("/api/v1/test"):
        g.auth_token = "verified-caller-jwt"
        rows = rest_select(
            "material_categories",
            params={"select": "id,code,name", "code": "eq.DYNAMIC_TEST", "limit": "10"},
        )

    assert rows[0]["code"] == "DYNAMIC_TEST"
    assert captured["url"] == "https://test-project.supabase.co/rest/v1/material_categories"
    assert captured["headers"]["Authorization"] == "Bearer verified-caller-jwt"
    assert captured["headers"]["apikey"] == "test-anon-key"


def test_master_service_rejects_non_allowlisted_table_before_network(app):
    with app.test_request_context("/api/v1/test"):
        g.auth_token = "verified-caller-jwt"
        with pytest.raises(ValueError):
            rest_select("profiles;delete", params={"select": "*"})


def test_get_master_record_uses_id_filter_and_fixed_select(app, monkeypatch):
    captured = {}

    def fake_select(table, *, params):
        captured["table"] = table
        captured["params"] = params
        return [{"id": "category-1", "code": "POLY_BAG", "name": "Poly Bags"}]

    monkeypatch.setattr("app.services.master_service.rest_select", fake_select)
    with app.test_request_context("/api/v1/test"):
        record = get_master_record("material_categories", "category-1", select="id,code,name")

    assert record["code"] == "POLY_BAG"
    assert captured["table"] == "material_categories"
    assert captured["params"]["id"] == "eq.category-1"


def test_catalog_limit_is_bounded(app):
    with app.test_request_context("/api/v1/test"):
        with pytest.raises(ValueError):
            list_master_records("vendors", select="id,vendor_code,name", limit=501)
