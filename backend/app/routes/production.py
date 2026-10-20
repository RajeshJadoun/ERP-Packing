"""HTTP contracts for production output and physical consumption verification."""

from __future__ import annotations

from decimal import Decimal
from typing import Literal
from uuid import UUID

from flask import Blueprint, g, jsonify
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.production_service import (
    get_production_completion,
    record_production_completion,
    verify_production_consumption,
)
from ..validation import validate_json

production_bp = Blueprint("production", __name__)


class ActualMaterialUsageInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    material_id: UUID = Field(alias="materialId")
    physically_confirmed_quantity: Decimal = Field(
        alias="physicallyConfirmedQuantity", ge=0, max_digits=18, decimal_places=8
    )
    unit_id: UUID = Field(alias="unitId")
    measurement_method: Literal["SCALE_WEIGHED", "SEALED_BUNDLE", "MANUALLY_COUNTED"] = Field(
        alias="measurementMethod"
    )
    measurement_evidence: str | None = Field(default=None, alias="measurementEvidence", max_length=500)

    @field_validator("measurement_evidence")
    @classmethod
    def normalize_evidence(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None


class RecordProductionCompletionInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    packing_job_id: UUID = Field(alias="packingJobId")
    completed_units: int = Field(alias="completedUnits", gt=0, le=2_000_000)
    worker_id: UUID = Field(alias="workerId")
    completion_policy: Literal["AUTO_BOM_THEORETICAL", "CONFIRMED_ACTUAL_ENTRY"] = Field(
        alias="completionPolicy"
    )
    actual_material_usage: list[ActualMaterialUsageInput] = Field(
        default_factory=list, alias="actualMaterialUsage", max_length=250
    )
    remarks: str | None = Field(default=None, max_length=2000)

    @field_validator("remarks")
    @classmethod
    def normalize_remarks(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None

    @model_validator(mode="after")
    def validate_policy_payload(self):
        if self.completion_policy == "AUTO_BOM_THEORETICAL" and self.actual_material_usage:
            raise ValueError("actualMaterialUsage is allowed only with CONFIRMED_ACTUAL_ENTRY.")
        if self.completion_policy == "CONFIRMED_ACTUAL_ENTRY" and not self.actual_material_usage:
            raise ValueError("CONFIRMED_ACTUAL_ENTRY requires actualMaterialUsage.")
        material_ids = [item.material_id for item in self.actual_material_usage]
        if len(set(material_ids)) != len(material_ids):
            raise ValueError("actualMaterialUsage cannot contain duplicate materialId values.")
        return self


class VerifyConsumptionInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    actual_material_usage: list[ActualMaterialUsageInput] = Field(
        alias="actualMaterialUsage", min_length=1, max_length=250
    )

    @model_validator(mode="after")
    def validate_unique_materials(self):
        ids = [item.material_id for item in self.actual_material_usage]
        if len(set(ids)) != len(ids):
            raise ValueError("actualMaterialUsage cannot contain duplicate materialId values.")
        return self


def _idempotency():
    context = getattr(g, "idempotency", None)
    if context is None:
        raise ApiError(400, "IDEMPOTENCY_CONTEXT_MISSING", "A validated Idempotency-Key is required.")
    return context


def _usage_payload(items: list[ActualMaterialUsageInput]) -> list[dict]:
    return [
        {
            "material_id": item.material_id,
            "physically_confirmed_quantity": item.physically_confirmed_quantity,
            "unit_id": item.unit_id,
            "measurement_method": item.measurement_method,
            "measurement_evidence": item.measurement_evidence,
        }
        for item in items
    ]


@production_bp.post("/production/completions")
@require_role("ADMIN", "OPERATOR", "PLANNER")
def record_production_completion_route():
    model = validate_json(RecordProductionCompletionInput)
    result = record_production_completion(
        {
            "packing_job_id": model.packing_job_id,
            "completed_units": model.completed_units,
            "worker_id": model.worker_id,
            "completion_policy": model.completion_policy,
            "actual_material_usage": _usage_payload(model.actual_material_usage),
            "remarks": model.remarks,
        },
        idempotency=_idempotency(),
    )
    return jsonify(result), 200


@production_bp.get("/production/completions/<completion_id>")
def get_production_completion_route(completion_id: str):
    return jsonify(get_production_completion(completion_id)), 200


@production_bp.post("/production/completions/<completion_id>/consumption/verify")
@require_role("ADMIN", "OPERATOR", "PLANNER")
def verify_production_consumption_route(completion_id: str):
    model = validate_json(VerifyConsumptionInput)
    result = verify_production_consumption(
        completion_id,
        actual_material_usage=_usage_payload(model.actual_material_usage),
        idempotency=_idempotency(),
    )
    return jsonify(result), 200
