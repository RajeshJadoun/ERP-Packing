from __future__ import annotations


def test_health_is_unauthenticated_and_reports_database(client):
    response = client.get("/api/v1/health")

    assert response.status_code == 200
    payload = response.get_json()
    assert payload["status"] == "HEALTHY"
    assert payload["database"] == "CONNECTED"
    assert payload["timestamp"].endswith("Z")
    assert response.headers["X-Request-ID"]


def test_health_is_unhealthy_when_database_is_unconfigured(app, client):
    app.extensions.pop("database_health_check")
    app.config.update(SUPABASE_URL="", SUPABASE_ANON_KEY=None, DATABASE_URL=None)

    response = client.get("/api/v1/health")

    assert response.status_code == 503
    payload = response.get_json()
    assert payload["status"] == "UNHEALTHY"
    assert payload["database"] == "NOT_CONFIGURED"


def test_health_does_not_need_authorization(client):
    response = client.get("/api/v1/health")
    assert response.status_code == 200
