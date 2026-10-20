"""Supabase RPC transport that preserves the verified caller identity.

Business writes must call transactional PostgreSQL RPCs using the original
user JWT; this module deliberately does not accept or store a service-role key.
"""

from __future__ import annotations

import json
import re
from typing import Any

import httpx
from flask import current_app, g

from .errors import ApiError, expired_idempotency_error

_FUNCTION_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,62}$")
_EXPIRED_PATTERN = re.compile(r"IDEMPOTENCY_RESPONSE_EXPIRED:\s*(\{.*?\})", re.DOTALL)


def _parse_expired_reference(message: str) -> dict[str, Any] | None:
    match = _EXPIRED_PATTERN.search(message)
    if not match:
        return None
    try:
        payload = json.loads(match.group(1))
    except (json.JSONDecodeError, TypeError):
        return None

    reference = {
        "resourceType": payload.get("resource_type"),
        "resourceId": payload.get("resource_id"),
        "operationCompletedAt": payload.get("operation_completed_at"),
    }
    if not all(reference.values()):
        return None
    return reference


def _raise_rpc_error(response: httpx.Response) -> None:
    """Translate database/PostgREST failures without leaking SQL or cached payloads."""
    message = ""
    try:
        payload = response.json()
        if isinstance(payload, dict):
            message = " ".join(
                str(payload.get(field, ""))
                for field in ("message", "details", "hint")
                if payload.get(field)
            )
    except (ValueError, TypeError):
        payload = {}

    if "IDEMPOTENCY_RESPONSE_EXPIRED" in message:
        reference = _parse_expired_reference(message)
        if reference:
            raise expired_idempotency_error(reference)
        raise ApiError(
            410,
            "IDEMPOTENCY_RESPONSE_EXPIRED",
            "The operation completed previously, but its cached response has expired. Retrieve the resource.",
        )

    if "IDEMPOTENCY_KEY_REUSED" in message or "IDEMPOTENCY_IN_PROGRESS" in message:
        raise ApiError(
            409,
            "IDEMPOTENCY_KEY_REUSED" if "IDEMPOTENCY_KEY_REUSED" in message else "IDEMPOTENCY_IN_PROGRESS",
            "The idempotency key conflicts with another request or operation in progress.",
        )

    status_map = {
        400: ("BAD_REQUEST", "The database rejected the request format."),
        401: ("UNAUTHORIZED", "Authentication must be refreshed before retrying this request."),
        403: ("FORBIDDEN", "Your application role does not permit this operation."),
        404: ("NOT_FOUND", "The requested resource was not found."),
        409: ("CONFLICT", "The request conflicts with the current resource state."),
        422: ("VALIDATION_ERROR", "The request violates a business rule."),
    }
    code, safe_message = status_map.get(
        response.status_code,
        ("DATABASE_OPERATION_FAILED", "The database operation could not be completed."),
    )
    status = response.status_code if response.status_code in status_map else 502
    raise ApiError(status, code, safe_message)


def call_supabase_rpc(function_name: str, params: dict[str, Any]) -> Any:
    """Call one allow-listed-name RPC with the current request's verified user JWT."""
    if not _FUNCTION_PATTERN.fullmatch(function_name):
        raise ValueError("Supabase RPC function name is invalid.")

    token = getattr(g, "auth_token", None)
    if not token:
        raise ApiError(401, "UNAUTHORIZED", "A verified user token is required for database operations.")

    base_url = current_app.config.get("SUPABASE_URL", "").rstrip("/")
    anon_key = current_app.config.get("SUPABASE_ANON_KEY")
    if not base_url or not anon_key:
        raise ApiError(503, "SUPABASE_NOT_CONFIGURED", "Database operations are not configured.")

    try:
        response = httpx.post(
            f"{base_url}/rest/v1/rpc/{function_name}",
            json=params,
            headers={
                "apikey": anon_key,
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            timeout=current_app.config.get("SUPABASE_RPC_TIMEOUT_SECONDS", 10.0),
        )
    except httpx.TimeoutException as exc:
        raise ApiError(504, "SUPABASE_TIMEOUT", "The database did not respond in time.") from exc
    except httpx.HTTPError as exc:
        current_app.logger.warning("Supabase RPC transport failed", exc_info=True)
        raise ApiError(503, "SUPABASE_UNAVAILABLE", "The database service is temporarily unavailable.") from exc

    if response.status_code >= 400:
        _raise_rpc_error(response)
    if response.status_code == 204 or not response.content:
        return None
    try:
        return response.json()
    except ValueError as exc:
        current_app.logger.error("Supabase RPC returned invalid JSON for %s", function_name)
        raise ApiError(502, "INVALID_DATABASE_RESPONSE", "The database returned an invalid response.") from exc
