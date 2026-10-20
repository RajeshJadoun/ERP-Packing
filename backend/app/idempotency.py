"""Idempotency request normalization.

This module prepares a deterministic operation scope and hash. The database RPC
continues to own the critical transaction, lock, replay cache, expiry handling,
and rollback semantics; this middleware must never create a standalone key row.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qsl

from flask import Request

from .errors import ApiError

_KEY_PATTERN = re.compile(r"^[A-Za-z0-9_\-\.:]{16,128}$")


@dataclass(frozen=True)
class IdempotencyContext:
    key: str
    owner_id: str
    operation_scope: str
    request_hash: str


def canonical_payload(request: Request) -> dict[str, Any]:
    """Return stable JSON-compatible data for the exact route request."""
    raw = request.get_data(cache=True)
    if request.is_json:
        try:
            body = request.get_json(silent=False)
        except Exception as exc:
            raise ApiError(400, "BAD_REQUEST", "The request JSON body is invalid.") from exc
    else:
        # Preserve the exact byte sequence if a client sends a non-JSON payload.
        body = {"rawBodySha256": hashlib.sha256(raw).hexdigest()}

    query = sorted(parse_qsl(request.query_string.decode("utf-8", errors="strict"), keep_blank_values=True))
    return {
        "body": body,
        "pathParameters": request.view_args or {},
        "query": query,
    }


def canonical_request_hash(request: Request) -> str:
    try:
        normalized = json.dumps(
            canonical_payload(request),
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
    except (TypeError, ValueError, UnicodeDecodeError) as exc:
        raise ApiError(400, "BAD_REQUEST", "The request payload cannot be canonicalized.") from exc
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def build_idempotency_context(request: Request, owner_id: str) -> IdempotencyContext:
    key = request.headers.get("Idempotency-Key", "")
    if not _KEY_PATTERN.fullmatch(key):
        raise ApiError(
            400,
            "INVALID_IDEMPOTENCY_KEY",
            "Idempotency-Key must be 16–128 ASCII characters matching [A-Za-z0-9_.:-].",
        )
    route = request.url_rule.rule if request.url_rule else request.path
    scope = f"{request.method.upper()}:{route}"
    return IdempotencyContext(
        key=key,
        owner_id=owner_id,
        operation_scope=scope,
        request_hash=canonical_request_hash(request),
    )
