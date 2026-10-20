"""Machine-readable, correlation-friendly API error responses."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from flask import Flask, current_app, g, jsonify
from werkzeug.exceptions import HTTPException


class ApiError(Exception):
    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        extra: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.extra = extra or {}


def error_payload(code: str, message: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    error: dict[str, Any] = {
        "code": code,
        "message": message,
        "requestId": getattr(g, "request_id", "req_unavailable"),
        "timestamp": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
    }
    if extra:
        error.update(extra)
    return {"success": False, "error": error}


def expired_idempotency_error(resource_reference: dict[str, Any]) -> ApiError:
    """Create the documented 410 response without allowing operation re-execution."""
    return ApiError(
        410,
        "IDEMPOTENCY_RESPONSE_EXPIRED",
        "The operation completed previously, but its cached response has expired. Retrieve the resource using the reference.",
        extra={"resourceReference": resource_reference},
    )


def register_error_handlers(app: Flask) -> None:
    @app.errorhandler(ApiError)
    def handle_api_error(exc: ApiError):
        return jsonify(error_payload(exc.code, exc.message, exc.extra)), exc.status_code

    @app.errorhandler(HTTPException)
    def handle_http_error(exc: HTTPException):
        status = exc.code or 500
        codes = {
            400: ("BAD_REQUEST", "The request could not be understood."),
            404: ("NOT_FOUND", "The requested resource was not found."),
            405: ("METHOD_NOT_ALLOWED", "The HTTP method is not supported for this resource."),
        }
        code, message = codes.get(status, ("HTTP_ERROR", "The request could not be completed."))
        return jsonify(error_payload(code, message)), status

    @app.errorhandler(Exception)
    def handle_unexpected_error(exc: Exception):
        current_app.logger.exception("Unhandled API exception")
        return jsonify(error_payload("INTERNAL_SERVER_ERROR", "An unexpected server error occurred.")), 500
