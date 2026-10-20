from __future__ import annotations


def test_valid_bearer_token_is_accepted(client, token_factory):
    token = token_factory()
    response = client.get("/_test/protected", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 200
    assert response.get_json()["userId"] == "cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01"


def test_missing_bearer_token_returns_401(client):
    response = client.get("/_test/protected")
    assert response.status_code == 401
    assert response.get_json()["error"]["code"] == "UNAUTHORIZED"


def test_expired_token_is_rejected(client, token_factory):
    token = token_factory(expires_in=-120)
    response = client.get("/_test/protected", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


def test_tampered_token_is_rejected(client, token_factory):
    token = token_factory()
    header, payload, signature = token.split(".")
    changed = ("A" if signature[0] != "A" else "B") + signature[1:]
    tampered = f"{header}.{payload}.{changed}"
    response = client.get("/_test/protected", headers={"Authorization": f"Bearer {tampered}"})
    assert response.status_code == 401


def test_operator_cannot_access_admin_route(app, client, token_factory):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "OPERATOR",
        "is_active": True,
    }
    token = token_factory()
    response = client.get("/_test/admin", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 403
    assert response.get_json()["error"]["code"] == "FORBIDDEN"


def test_client_supplied_user_metadata_does_not_grant_admin(client, token_factory, app):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "OPERATOR",
        "is_active": True,
    }
    # The fixture JWT contains user_metadata.role=ADMIN, but RBAC comes from profiles.
    token = token_factory(role="authenticated")
    response = client.get("/_test/admin", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 403


def test_inactive_profile_is_rejected(app, client, token_factory):
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "ADMIN",
        "is_active": False,
    }
    token = token_factory()
    response = client.get("/_test/protected", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 403
