"""Correlation IDs for logs and standardized API errors."""

from __future__ import annotations

import re
import uuid

from flask import Flask, g, request

_REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{8,128}$")


def install_request_context(app: Flask) -> None:
    @app.before_request
    def set_request_id() -> None:
        supplied = request.headers.get("X-Request-ID", "")
        g.request_id = supplied if _REQUEST_ID_PATTERN.fullmatch(supplied) else f"req_{uuid.uuid4().hex[:24]}"

    @app.after_request
    def add_request_id_header(response):
        response.headers["X-Request-ID"] = getattr(g, "request_id", f"req_{uuid.uuid4().hex[:24]}")
        response.headers["Cache-Control"] = "no-store" if request.path.startswith("/api/") else response.headers.get("Cache-Control", "")
        return response
