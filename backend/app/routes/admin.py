"""Admin endpoints for user profile access and role management."""

from __future__ import annotations

from typing import Any
from uuid import UUID

from flask import Blueprint, jsonify
from pydantic import BaseModel, ConfigDict, Field, field_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.master_service import rest_select
from ..supabase_rpc import call_supabase_rpc
from ..validation import validate_json

admin_bp = Blueprint("admin", __name__)


class AdminUpdateProfileAccessInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    role: str
    is_active: bool = Field(alias="isActive")
    reason: str = Field(min_length=10, max_length=2000)

    @field_validator("role")
    @classmethod
    def validate_role(cls, value: str) -> str:
        normalized = value.strip().upper()
        if normalized not in {"ADMIN", "STOREKEEPER", "PLANNER", "OPERATOR", "VIEWER"}:
            raise ValueError("role must be one of ADMIN, STOREKEEPER, PLANNER, OPERATOR, VIEWER.")
        return normalized

    @field_validator("reason")
    @classmethod
    def validate_reason(cls, value: str) -> str:
        normalized = value.strip()
        if len(normalized) < 10:
            raise ValueError("reason must be at least 10 characters.")
        return normalized


def _validate_uuid(raw: str, param_name: str) -> str:
    try:
        return str(UUID(raw.strip()))
    except (ValueError, AttributeError) as exc:
        raise ApiError(400, "BAD_REQUEST", f"{param_name} must be a valid UUID.") from exc


@admin_bp.post("/admin/users/<target_id>/access")
@require_role("ADMIN")
def update_user_access_route(target_id: str):
    target_uuid = _validate_uuid(target_id, "targetId")
    model = validate_json(AdminUpdateProfileAccessInput)

    result = call_supabase_rpc(
        "admin_update_profile_access",
        {
            "target_id": target_uuid,
            "new_role": model.role,
            "new_is_active": model.is_active,
            "reason": model.reason,
        },
    )

    # Fetch updated profile for response envelope
    profile_rows = rest_select(
        "profiles",
        params={
            "id": f"eq.{target_uuid}",
            "select": "id,full_name,role,is_active,created_at,updated_at",
            "limit": "1",
        },
    )
    profile: dict[str, Any] = profile_rows[0] if profile_rows else {
        "id": target_uuid,
        "full_name": None,
        "role": model.role,
        "is_active": model.is_active,
        "created_at": None,
        "updated_at": None,
    }

    # Fetch the latest audit log entry for this target
    audit_rows = rest_select(
        "audit_logs",
        params={
            "target_entity_id": f"eq.{target_uuid}",
            "target_entity_type": "eq.PROFILE",
            "select": "id,created_at",
            "order": "created_at.desc",
            "limit": "1",
        },
    )
    audit_id = audit_rows[0]["id"] if audit_rows else str(result.get("audit_log_id") or target_uuid)

    response_payload = {
        "success": True,
        "profile": {
            "id": profile["id"],
            "fullName": profile.get("full_name"),
            "role": profile["role"],
            "isActive": profile["is_active"],
            "createdAt": profile.get("created_at"),
            "updatedAt": profile.get("updated_at"),
        },
        "auditLogId": audit_id,
    }
    return jsonify(response_payload), 200


@admin_bp.get("/admin/users/<target_id>")
@require_role("ADMIN")
def get_user_profile_route(target_id: str):
    target_uuid = _validate_uuid(target_id, "targetId")
    rows = rest_select(
        "profiles",
        params={
            "id": f"eq.{target_uuid}",
            "select": "id,full_name,role,is_active,created_at,updated_at",
            "limit": "1",
        },
    )
    if not rows:
        raise ApiError(404, "NOT_FOUND", "The requested user profile was not found.")

    profile = rows[0]
    return jsonify({
        "id": profile["id"],
        "fullName": profile.get("full_name"),
        "role": profile["role"],
        "isActive": profile["is_active"],
        "createdAt": profile.get("created_at"),
        "updatedAt": profile.get("updated_at"),
    }), 200
