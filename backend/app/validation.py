"""Reusable Pydantic request-body validation for Flask routes."""

from __future__ import annotations

from typing import TypeVar

from flask import request
from pydantic import BaseModel, ValidationError

from .errors import ApiError

ModelT = TypeVar("ModelT", bound=BaseModel)


def validate_json(model: type[ModelT]) -> ModelT:
    if not request.is_json:
        raise ApiError(400, "BAD_REQUEST", "Content-Type must be application/json.")
    try:
        payload = request.get_json(silent=False)
        return model.model_validate(payload)
    except ValidationError as exc:
        raise ApiError(
            422,
            "VALIDATION_ERROR",
            "One or more request fields are invalid.",
            extra={"fields": [
                {"field": ".".join(str(part) for part in item["loc"]), "code": item["type"]}
                for item in exc.errors()
            ]},
        ) from exc
    except ApiError:
        raise
    except Exception as exc:
        raise ApiError(400, "BAD_REQUEST", "The request JSON body is invalid.") from exc
