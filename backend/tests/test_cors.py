from __future__ import annotations


def test_api_cors_preflight_allows_configured_frontend_origin(client):
    response = client.options(
        "/api/v1/health",
        headers={
            "Origin": "http://localhost:5173",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type,idempotency-key",
        },
    )

    assert response.status_code == 200
    assert response.headers["Access-Control-Allow-Origin"] == "http://localhost:5173"
    assert "idempotency-key" in response.headers["Access-Control-Allow-Headers"].lower()


def test_api_cors_does_not_reflect_unlisted_origin(client):
    response = client.get("/api/v1/health", headers={"Origin": "https://untrusted.example"})

    assert response.status_code == 200
    assert "Access-Control-Allow-Origin" not in response.headers
