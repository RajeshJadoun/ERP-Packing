"""HTTP contracts for closing and reopening a shift plan."""

from __future__ import annotations

from datetime import date
from typing import Literal
from uuid import UUID

from flask import Blueprint, g, jsonify
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.closing_service import close_daily_plan, get_daily_closing, reopen_daily_closing
from ..validation import validate_json

closing_bp = Blueprint("closing", __name__)


class PendingDispositionInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    packing_job_id: UUID = Field(alias="packingJobId")
    disposition: Literal["CARRY_FORWARD", "RESCHEDULE", "CANCEL"]
    reason: str | None = Field(default=None, max_length=2000)
    target_plan_date: date | None = Field(default=None, alias="targetPlanDate")
    target_shift_code: str | None = Field(default=None, alias="targetShiftCode", max_length=30)

    @field_validator("reason")
    @classmethod
    def normalize_reason(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None

    @field_validator("target_shift_code")
    @classmethod
    def normalize_target_shift(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().upper()
        if not normalized or not all(char.isalnum() or char in "_-" for char in normalized):
            raise ValueError("targetShiftCode may contain only letters, digits, underscore and hyphen.")
        return normalized

    @model_validator(mode="after")
    def validate_disposition(self):
        if self.disposition in {"CANCEL", "RESCHEDULE"} and len(self.reason or "") < 3:
            raise ValueError("CANCEL and RESCHEDULE require a reason of at least 3 non-space characters.")
        if self.disposition == "RESCHEDULE":
            if self.target_plan_date is None or self.target_shift_code is None:
                raise ValueError("RESCHEDULE requires targetPlanDate and targetShiftCode.")
        elif self.target_plan_date is not None or self.target_shift_code is not None:
            raise ValueError("targetPlanDate and targetShiftCode are allowed only for RESCHEDULE.")
        return self


class ExecuteDailyCloseInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    daily_plan_id: UUID = Field(alias="dailyPlanId")
    shift_code: str = Field(alias="shiftCode", min_length=1, max_length=30)
    allow_discrepancy_override: bool = Field(default=False, alias="allowDiscrepancyOverride")
    supervisor_override_reason: str | None = Field(default=None, alias="supervisorOverrideReason", max_length=2000)
    pending_dispositions: list[PendingDispositionInput] = Field(
        default_factory=list, alias="pendingDispositions", max_length=100
    )

    @field_validator("shift_code")
    @classmethod
    def normalize_shift_code(cls, value: str) -> str:
        normalized = value.strip().upper()
        if not normalized or not all(char.isalnum() or char in "_-" for char in normalized):
            raise ValueError("shiftCode may contain only letters, digits, underscore and hyphen.")
        return normalized

    @field_validator("supervisor_override_reason")
    @classmethod
    def normalize_override_reason(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None

    @model_validator(mode="after")
    def validate_override(self):
        if self.allow_discrepancy_override and len(self.supervisor_override_reason or "") < 3:
            raise ValueError("An override requires a meaningful supervisorOverrideReason.")
        return self


class ReopenDailyClosingInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    reopen_reason: str = Field(alias="reopenReason", min_length=3, max_length=2000)

    @field_validator("reopen_reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if len(normalized) < 3:
            raise ValueError("reopenReason must contain at least 3 non-space characters.")
        return normalized


def _idempotency():
    context = getattr(g, "idempotency", None)
    if context is None:
        raise ApiError(400, "IDEMPOTENCY_CONTEXT_MISSING", "A validated Idempotency-Key is required.")
    return context


@closing_bp.post("/closings")
@require_role("ADMIN", "STOREKEEPER")
def close_daily_plan_route():
    model = validate_json(ExecuteDailyCloseInput)
    result = close_daily_plan(
        {
            "daily_plan_id": model.daily_plan_id,
            "shift_code": model.shift_code,
            "allow_discrepancy_override": model.allow_discrepancy_override,
            "supervisor_override_reason": model.supervisor_override_reason,
            "pending_dispositions": [
                {
                    "packing_job_id": item.packing_job_id,
                    "disposition": item.disposition,
                    "reason": item.reason,
                    "target_plan_date": item.target_plan_date,
                    "target_shift_code": item.target_shift_code,
                }
                for item in model.pending_dispositions
            ],
        },
        idempotency=_idempotency(),
    )
    return jsonify(result), 200


@closing_bp.get("/closings/<closing_id>")
def get_daily_closing_route(closing_id: str):
    return jsonify(get_daily_closing(closing_id)), 200


@closing_bp.post("/closings/<closing_id>/reopen")
@require_role("ADMIN")
def reopen_daily_closing_route(closing_id: str):
    model = validate_json(ReopenDailyClosingInput)
    result = reopen_daily_closing(closing_id, reason=model.reopen_reason, idempotency=_idempotency())
    return jsonify(result), 200
