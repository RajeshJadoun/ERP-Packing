"""Flask application factory for ERP Packing."""

from __future__ import annotations

import logging
from datetime import UTC, datetime

import httpx
import psycopg
from flask import Blueprint, Flask, current_app, g, jsonify, request
from flask_cors import CORS

from .auth import JWTVerifier, authenticate_request, resolve_profile_from_supabase
from .config import Settings
from .errors import register_error_handlers
from .idempotency import build_idempotency_context
from .request_context import install_request_context
from .routes.admin import admin_bp
from .routes.boms import boms_bp
from .routes.closing import closing_bp
from .routes.planning import planning_bp
from .routes.production import production_bp
from .routes.purchasing import purchasing_bp
from .routes.reports import reports_bp
from .routes.stock import stock_bp


def _secret_value(value) -> str | None:
    if value is None:
        return None
    getter = getattr(value, "get_secret_value", None)
    return getter() if callable(getter) else str(value)


def _database_status(app: Flask) -> str:
    """Check PostgreSQL connectivity without exposing credentials in responses."""
    injected = app.extensions.get("database_health_check")
    if injected is not None:
        try:
            return "CONNECTED" if injected() else "UNAVAILABLE"
        except Exception:
            app.logger.exception("Injected database health check failed")
            return "UNAVAILABLE"

    database_url = app.config.get("DATABASE_URL")
    if database_url:
        try:
            with psycopg.connect(
                database_url,
                connect_timeout=app.config["HEALTHCHECK_TIMEOUT_SECONDS"],
            ) as conn:
                conn.execute("SELECT 1")
            return "CONNECTED"
        except Exception:
            app.logger.warning("PostgreSQL health check failed", exc_info=True)
            return "UNAVAILABLE"

    supabase_url = app.config.get("SUPABASE_URL")
    anon_key = app.config.get("SUPABASE_ANON_KEY")
    if supabase_url and anon_key:
        try:
            response = httpx.get(
                f"{supabase_url.rstrip('/')}/rest/v1/material_categories?select=id&limit=1",
                headers={"apikey": anon_key, "Authorization": f"Bearer {anon_key}"},
                timeout=app.config["HEALTHCHECK_TIMEOUT_SECONDS"],
            )
            response.raise_for_status()
            return "CONNECTED"
        except Exception:
            app.logger.warning("Supabase REST health check failed", exc_info=True)
            return "UNAVAILABLE"

    return "NOT_CONFIGURED"


def create_app(config_overrides: dict | None = None) -> Flask:
    """Build an app instance. Configuration can be overridden for unit tests."""
    settings = Settings()
    app = Flask(__name__)
    app.config.from_mapping(
        APP_ENV=settings.app_env,
        APP_HOST=settings.app_host,
        APP_PORT=settings.app_port,
        LOG_LEVEL=settings.log_level,
        CORS_ALLOWED_ORIGINS=settings.cors_allowed_origins,
        HEALTHCHECK_TIMEOUT_SECONDS=settings.healthcheck_timeout_seconds,
        SUPABASE_RPC_TIMEOUT_SECONDS=settings.supabase_rpc_timeout_seconds,
        SUPABASE_URL=settings.supabase_url,
        SUPABASE_ANON_KEY=_secret_value(settings.supabase_anon_key),
        SUPABASE_JWT_SECRET=_secret_value(settings.supabase_jwt_secret),
        SUPABASE_JWKS_URL=settings.resolved_jwks_url,
        SUPABASE_JWT_ISSUER=settings.resolved_jwt_issuer,
        SUPABASE_JWT_AUDIENCE=settings.supabase_jwt_audience,
        JWT_LEEWAY_SECONDS=settings.jwt_leeway_seconds,
        DATABASE_URL=_secret_value(settings.database_url),
    )
    if config_overrides:
        app.config.update(config_overrides)

    logging.basicConfig(level=getattr(logging, app.config["LOG_LEVEL"].upper(), logging.INFO))
    app.extensions["profile_resolver"] = resolve_profile_from_supabase
    app.extensions["jwt_verifier"] = JWTVerifier(
        secret=app.config.get("SUPABASE_JWT_SECRET") or None,
        jwks_url=app.config.get("SUPABASE_JWKS_URL") or None,
        issuer=app.config.get("SUPABASE_JWT_ISSUER") or None,
        audience=app.config["SUPABASE_JWT_AUDIENCE"],
        leeway_seconds=app.config["JWT_LEEWAY_SECONDS"],
    )

    api = Blueprint("api", __name__, url_prefix="/api/v1")

    @api.before_request
    def enforce_api_security() -> None:
        # Health is the one explicitly unauthenticated API operation.
        if request.endpoint == "api.health" or request.method == "OPTIONS":
            return None

        authenticate_request()

        # Every state-changing API command must have a bounded idempotency key.
        # The authoritative lock/replay/expiry decision remains inside the
        # transaction RPC; this layer only validates and canonicalizes inputs.
        if request.method == "POST":
            g.idempotency = build_idempotency_context(request, g.user_id)

        return None

    @api.get("/health")
    def health():
        database = _database_status(current_app)
        healthy = database == "CONNECTED"
        payload = {
            "status": "HEALTHY" if healthy else "UNHEALTHY",
            "database": database,
            "timestamp": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        }
        return jsonify(payload), (200 if healthy else 503)

    api.register_blueprint(boms_bp)
    api.register_blueprint(planning_bp)
    api.register_blueprint(purchasing_bp)
    api.register_blueprint(stock_bp)
    api.register_blueprint(production_bp)
    api.register_blueprint(reports_bp)
    api.register_blueprint(closing_bp)
    api.register_blueprint(admin_bp)
    app.register_blueprint(api)
    allowed_origins = [
        origin.strip()
        for origin in str(app.config.get("CORS_ALLOWED_ORIGINS", "")).split(",")
        if origin.strip()
    ]
    if "*" in allowed_origins:
        raise ValueError("CORS_ALLOWED_ORIGINS must use an explicit origin allow-list.")
    if allowed_origins:
        CORS(
            app,
            resources={r"/api/v1/.*": {"origins": allowed_origins}},
            supports_credentials=False,
            allow_headers=["Authorization", "Content-Type", "Idempotency-Key", "X-Request-ID"],
            expose_headers=["X-Request-ID"],
            methods=["GET", "POST", "OPTIONS"],
        )
    install_request_context(app)
    register_error_handlers(app)
    return app
