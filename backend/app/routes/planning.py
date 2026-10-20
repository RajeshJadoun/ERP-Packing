"""Flask routes for daily plan scheduling, release and job lifecycle."""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from uuid import UUID

from flask import Blueprint, g, jsonify
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.planning_service import (
    cancel_packing_job,
    create_daily_plan,
    get_daily_plan,
    get_packing_job,
    release_daily_plan,
    revise_packing_job,
)
from ..validation import validate_json

planning_bp = Blueprint("planning", __name__)


class BomLineInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    material_id: UUID = Field(alias="materialId")
    quantity_per_unit: Decimal = Field(alias="quantityPerUnit", gt=0, max_digits=18, decimal_places=8)
    unit_id: UUID = Field(alias="unitId")
    is_optional: bool = Field(default=False, alias="isOptional")
    application_notes: str | None = Field(default=None, alias="applicationNotes", max_length=2000)

    @field_validator("application_notes")
    @classmethod
    def normalize_application_notes(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None


class MasterDerivedJobInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    party_id: UUID = Field(alias="partyId")
    product_id: UUID = Field(alias="productId")
    master_bom_id: UUID = Field(alias="masterBomId")
    planned_quantity: int = Field(alias="plannedQuantity", gt=0, le=2_000_000)


class CustomJobInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    party_id: UUID = Field(alias="partyId")
    product_id: UUID = Field(alias="productId")
    planned_quantity: int = Field(alias="plannedQuantity", gt=0, le=2_000_000)
    custom_bom_lines: list[BomLineInput] = Field(alias="customBomLines", min_length=1, max_length=250)
    customization_notes: str | None = Field(default=None, alias="customizationNotes", max_length=2000)

    @field_validator("customization_notes")
    @classmethod
    def normalize_customization_notes(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None


class CreateDailyPlanInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    plan_date: date = Field(alias="planDate")
    shift_code: str = Field(alias="shiftCode", min_length=1, max_length=30)
    notes: str | None = Field(default=None, max_length=2000)
    master_derived_jobs: list[MasterDerivedJobInput] = Field(
        default_factory=list, alias="masterDerivedJobs", max_length=100
    )
    custom_jobs: list[CustomJobInput] = Field(default_factory=list, alias="customJobs", max_length=100)

    @field_validator("shift_code")
    @classmethod
    def normalize_shift_code(cls, value: str) -> str:
        normalized = value.strip().upper()
        if not normalized or not all(char.isalnum() or char in "_-" for char in normalized):
            raise ValueError("shiftCode may contain only letters, digits, underscore and hyphen.")
        return normalized

    @field_validator("notes")
    @classmethod
    def normalize_notes(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None

    @model_validator(mode="after")
    def validate_job_count(self):
        total = len(self.master_derived_jobs) + len(self.custom_jobs)
        if total < 1 or total > 100:
            raise ValueError("A daily plan must contain between 1 and 100 jobs.")
        return self


class RevisePackingJobInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    revised_quantity: int = Field(alias="revisedQuantity", gt=0, le=2_000_000)
    reason: str = Field(min_length=3, max_length=2000)

    @field_validator("reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if len(normalized) < 3:
            raise ValueError("reason must contain at least 3 non-space characters.")
        return normalized


class CancelPackingJobInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    reason: str = Field(min_length=3, max_length=2000)

    @field_validator("reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if len(normalized) < 3:
            raise ValueError("reason must contain at least 3 non-space characters.")
        return normalized


def _idempotency():
    context = getattr(g, "idempotency", None)
    if context is None:
        raise ApiError(400, "IDEMPOTENCY_CONTEXT_MISSING", "A validated Idempotency-Key is required.")
    return context


def _line_payload(line: BomLineInput) -> dict:
    return {
        "material_id": line.material_id,
        "quantity_per_unit": line.quantity_per_unit,
        "unit_id": line.unit_id,
        "is_optional": line.is_optional,
        "application_notes": line.application_notes,
    }


@planning_bp.post("/daily-plans")
@require_role("ADMIN", "PLANNER")
def create_daily_plan_route():
    model = validate_json(CreateDailyPlanInput)
    result = create_daily_plan(
        {
            "plan_date": model.plan_date,
            "shift_code": model.shift_code,
            "notes": model.notes,
            "master_derived_jobs": [
                {
                    "party_id": job.party_id,
                    "product_id": job.product_id,
                    "master_bom_id": job.master_bom_id,
                    "planned_quantity": job.planned_quantity,
                }
                for job in model.master_derived_jobs
            ],
            "custom_jobs": [
                {
                    "party_id": job.party_id,
                    "product_id": job.product_id,
                    "planned_quantity": job.planned_quantity,
                    "customization_notes": job.customization_notes,
                    "custom_bom_lines": [_line_payload(line) for line in job.custom_bom_lines],
                }
                for job in model.custom_jobs
            ],
        },
        idempotency=_idempotency(),
    )
    return jsonify(result), 201


@planning_bp.get("/daily-plans/<plan_id>")
def get_daily_plan_route(plan_id: str):
    return jsonify(get_daily_plan(plan_id)), 200


@planning_bp.post("/daily-plans/<plan_id>/release")
@require_role("ADMIN", "PLANNER")
def release_daily_plan_route(plan_id: str):
    return jsonify(release_daily_plan(plan_id, idempotency=_idempotency())), 200


@planning_bp.post("/packing-jobs/<job_id>/revise-quantity")
@require_role("ADMIN", "PLANNER")
def revise_packing_job_route(job_id: str):
    model = validate_json(RevisePackingJobInput)
    return jsonify(
        revise_packing_job(
            job_id,
            revised_quantity=model.revised_quantity,
            reason=model.reason,
            idempotency=_idempotency(),
        )
    ), 200


@planning_bp.post("/packing-jobs/<job_id>/cancel")
@require_role("ADMIN", "PLANNER")
def cancel_packing_job_route(job_id: str):
    model = validate_json(CancelPackingJobInput)
    return jsonify(
        cancel_packing_job(
            job_id,
            reason=model.reason,
            idempotency=_idempotency(),
        )
    ), 200


@planning_bp.get("/packing-jobs/<job_id>")
def get_packing_job_route(job_id: str):
    return jsonify(get_packing_job(job_id)), 200
