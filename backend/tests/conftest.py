"""Common test fixtures. Tokens are signed only with an isolated test secret."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import jwt
import pytest
from flask import Blueprint, jsonify

from app import create_app
from app.auth import authenticate_request, require_role

TEST_SECRET = "unit-test-only-secret-that-is-never-used-outside-tests"
TEST_ISSUER = "https://test-project.supabase.co/auth/v1"
TEST_USER_ID = "cd79a45a-2b9a-47a9-9e4f-7f6b25e9ec01"


@pytest.fixture
def app():
    app = create_app(
        {
            "TESTING": True,
            "SUPABASE_URL": "https://test-project.supabase.co",
            "SUPABASE_ANON_KEY": "test-anon-key",
            "SUPABASE_JWT_SECRET": TEST_SECRET,
            "SUPABASE_JWKS_URL": "",
            "SUPABASE_JWT_ISSUER": TEST_ISSUER,
            "SUPABASE_JWT_AUDIENCE": "authenticated",
            "JWT_LEEWAY_SECONDS": 0,
            "DATABASE_URL": None,
        }
    )
    app.extensions["database_health_check"] = lambda: True
    app.extensions["profile_resolver"] = lambda claims, token: {
        "id": claims["sub"],
        "role": "ADMIN",
        "is_active": True,
    }

    # A private test-only blueprint exercises the same authentication and RBAC
    # decorators without adding routes outside the published API contract.
    test_bp = Blueprint("test_api", __name__, url_prefix="/_test")

    @test_bp.before_request
    def protect_test_api():
        authenticate_request()

    @test_bp.get("/protected")
    def protected():
        return jsonify({"success": True, "userId": __import__("flask").g.user_id})

    @test_bp.get("/admin")
    @require_role("ADMIN")
    def admin():
        return jsonify({"success": True, "role": __import__("flask").g.user_role})

    app.register_blueprint(test_bp)
    yield app


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def token_factory():
    def make_token(
        *,
        subject: str = TEST_USER_ID,
        role: str = "authenticated",
        expires_in: int = 300,
        secret: str = TEST_SECRET,
    ) -> str:
        now = datetime.now(timezone.utc)
        claims = {
            "sub": subject,
            "role": role,
            "aud": "authenticated",
            "iss": TEST_ISSUER,
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(seconds=expires_in)).timestamp()),
            # user_metadata is user-editable and must never be treated as RBAC.
            "user_metadata": {"role": "ADMIN"},
        }
        return jwt.encode(claims, secret, algorithm="HS256")

    return make_token
