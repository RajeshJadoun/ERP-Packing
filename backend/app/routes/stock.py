"""HTTP endpoints for the authoritative stock ledger and inventory movements."""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from flask import Blueprint, g, jsonify, request
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.stock_service import (
    dispose_scrap,
    get_stock_adjustment,
    get_stock_balances,
    get_stock_ledger,
    get_stock_transaction,
    get_worker_custody,
    issue_to_worker,
    post_stock_adjustment,
    quarantine_stock,
    return_from_worker,
    transfer_stock,
)
from ..validation import validate_json

stock_bp = Blueprint("stock", __name__)


class MeasurementMethod(StrEnum):
    SCALE_WEIGHED = "SCALE_WEIGHED"
    SEALED_BUNDLE = "SEALED_BUNDLE"
    MANUALLY_COUNTED = "MANUALLY_COUNTED"


class StockMovementBase(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    material_id: UUID = Field(alias="materialId")
    quantity: Decimal = Field(gt=0, allow_inf_nan=False)
    unit_id: UUID = Field(alias="unitId")


class IssueMaterialInput(StockMovementBase):
    worker_id: UUID = Field(alias="workerId")
    job_id: UUID = Field(alias="jobId")
    source_location_id: UUID = Field(alias="sourceLocationId")
    destination_location_id: UUID = Field(alias="destinationLocationId")
    measurement_method: MeasurementMethod = Field(alias="measurementMethod")
    measurement_evidence: str | None = Field(default=None, alias="measurementEvidence", max_length=500)

    @field_validator("measurement_evidence")
    @classmethod
    def normalize_evidence(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        return normalized or None

    @model_validator(mode="after")
    def require_bundle_evidence(self):
        if self.measurement_method in {MeasurementMethod.SEALED_BUNDLE, MeasurementMethod.MANUALLY_COUNTED}:
            if not self.measurement_evidence:
                raise ValueError("measurementEvidence is required for bundle or manual counts.")
        return self


class ReturnMaterialInput(StockMovementBase):
    worker_id: UUID = Field(alias="workerId")
    job_id: UUID = Field(alias="jobId")
    source_location_id: UUID = Field(alias="sourceLocationId")
    destination_location_id: UUID = Field(alias="destinationLocationId")
    measurement_method: MeasurementMethod = Field(alias="measurementMethod")
    measurement_evidence: str | None = Field(default=None, alias="measurementEvidence", max_length=500)

    @field_validator("measurement_evidence")
    @classmethod
    def normalize_evidence(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        return normalized or None

    @model_validator(mode="after")
    def require_bundle_evidence(self):
        if self.measurement_method in {MeasurementMethod.SEALED_BUNDLE, MeasurementMethod.MANUALLY_COUNTED}:
            if not self.measurement_evidence:
                raise ValueError("measurementEvidence is required for bundle or manual counts.")
        return self


class StockTransferInput(StockMovementBase):
    source_location_id: UUID = Field(alias="sourceLocationId")
    destination_location_id: UUID = Field(alias="destinationLocationId")
    reason: str = Field(min_length=1, max_length=500)

    @field_validator("reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("reason cannot be blank.")
        return normalized

    @model_validator(mode="after")
    def distinct_locations(self):
        if self.source_location_id == self.destination_location_id:
            raise ValueError("sourceLocationId and destinationLocationId must differ.")
        return self


class DamageQuarantineInput(StockMovementBase):
    source_location_id: UUID = Field(alias="sourceLocationId")
    destination_location_id: UUID = Field(alias="destinationLocationId")
    quarantine_reason: str = Field(alias="quarantineReason", min_length=1, max_length=500)

    @field_validator("quarantine_reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("quarantineReason cannot be blank.")
        return normalized

    @model_validator(mode="after")
    def distinct_locations(self):
        if self.source_location_id == self.destination_location_id:
            raise ValueError("sourceLocationId and destinationLocationId must differ.")
        return self


class ScrapDisposalInput(StockMovementBase):
    source_location_id: UUID = Field(alias="sourceLocationId")
    disposal_reason: str = Field(alias="disposalReason", min_length=1, max_length=500)

    @field_validator("disposal_reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("disposalReason cannot be blank.")
        return normalized


class StockAdjustmentInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    material_id: UUID = Field(alias="materialId")
    location_id: UUID = Field(alias="locationId")
    counted_quantity: Decimal = Field(alias="countedQuantity", ge=0, allow_inf_nan=False)
    counted_unit_id: UUID = Field(alias="countedUnitId")
    adjustment_reason: str = Field(alias="adjustmentReason", min_length=1, max_length=500)
    supervisor_approved_by: UUID = Field(alias="supervisorApprovedBy")

    @field_validator("adjustment_reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("adjustmentReason cannot be blank.")
        return normalized


def _idempotency_or_error():
    context = getattr(g, "idempotency", None)
    if context is None:
        raise ApiError(400, "IDEMPOTENCY_CONTEXT_MISSING", "A validated Idempotency-Key is required.")
    return context


def _query_uuid(name: str) -> str | None:
    value = request.args.get(name)
    if value is None or not value.strip():
        return None
    try:
        return str(UUID(value))
    except ValueError as exc:
        raise ApiError(400, "BAD_REQUEST", f"{name} must be a valid UUID.") from exc


def _query_date(name: str) -> date | None:
    value = request.args.get(name)
    if value is None or not value.strip():
        return None
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise ApiError(400, "BAD_REQUEST", f"{name} must use YYYY-MM-DD format.") from exc


def _query_int(name: str, default: int) -> int:
    value = request.args.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ApiError(400, "BAD_REQUEST", f"{name} must be an integer.") from exc


@stock_bp.get("/stock/balances")
def stock_balances_route():
    return jsonify(
        get_stock_balances(
            material_id=_query_uuid("materialId"),
            location_id=_query_uuid("locationId"),
        )
    ), 200


@stock_bp.get("/stock/ledger")
def stock_ledger_route():
    from_date = _query_date("fromDate")
    to_date = _query_date("toDate")
    if from_date and to_date and from_date > to_date:
        raise ApiError(400, "BAD_REQUEST", "fromDate cannot be later than toDate.")
    rows = get_stock_ledger(
        material_id=_query_uuid("materialId"),
        from_date=from_date.isoformat() if from_date else None,
        to_date=to_date.isoformat() if to_date else None,
        limit=_query_int("limit", 50),
        offset=_query_int("offset", 0),
    )
    return jsonify(rows), 200


@stock_bp.get("/stock/worker-custody")
def worker_custody_route():
    return jsonify(get_worker_custody(worker_id=_query_uuid("workerId"))), 200


@stock_bp.get("/stock/transactions/<transaction_id>")
def stock_transaction_route(transaction_id: str):
    return jsonify(get_stock_transaction(transaction_id)), 200


@stock_bp.get("/stock/adjustments/<adjustment_id>")
def stock_adjustment_route(adjustment_id: str):
    return jsonify(get_stock_adjustment(adjustment_id)), 200


@stock_bp.post("/stock/issue-to-worker")
@require_role("ADMIN", "STOREKEEPER", "PLANNER")
def issue_to_worker_route():
    model = validate_json(IssueMaterialInput)
    payload = {
        "worker_id": str(model.worker_id),
        "job_id": str(model.job_id),
        "material_id": str(model.material_id),
        "source_location_id": str(model.source_location_id),
        "destination_location_id": str(model.destination_location_id),
        "quantity": model.quantity,
        "unit_id": str(model.unit_id),
        "measurement_method": model.measurement_method.value,
        "measurement_evidence": model.measurement_evidence,
    }
    return jsonify(issue_to_worker(payload, idempotency=_idempotency_or_error())), 200


@stock_bp.post("/stock/return-from-worker")
@require_role("ADMIN", "STOREKEEPER", "OPERATOR")
def return_from_worker_route():
    model = validate_json(ReturnMaterialInput)
    payload = {
        "worker_id": str(model.worker_id),
        "job_id": str(model.job_id),
        "material_id": str(model.material_id),
        "source_location_id": str(model.source_location_id),
        "destination_location_id": str(model.destination_location_id),
        "quantity": model.quantity,
        "unit_id": str(model.unit_id),
        "measurement_method": model.measurement_method.value,
        "measurement_evidence": model.measurement_evidence,
    }
    return jsonify(return_from_worker(payload, idempotency=_idempotency_or_error())), 200


@stock_bp.post("/stock/transfer")
@require_role("ADMIN", "STOREKEEPER")
def transfer_stock_route():
    model = validate_json(StockTransferInput)
    payload = {
        "material_id": str(model.material_id),
        "quantity": model.quantity,
        "unit_id": str(model.unit_id),
        "source_location_id": str(model.source_location_id),
        "destination_location_id": str(model.destination_location_id),
        "reason": model.reason,
    }
    return jsonify(transfer_stock(payload, idempotency=_idempotency_or_error())), 200


@stock_bp.post("/stock/damage-quarantine")
@require_role("ADMIN", "STOREKEEPER")
def quarantine_stock_route():
    model = validate_json(DamageQuarantineInput)
    payload = {
        "material_id": str(model.material_id),
        "quantity": model.quantity,
        "unit_id": str(model.unit_id),
        "source_location_id": str(model.source_location_id),
        "destination_location_id": str(model.destination_location_id),
        "reason": model.quarantine_reason,
    }
    return jsonify(quarantine_stock(payload, idempotency=_idempotency_or_error())), 200


@stock_bp.post("/stock/scrap-disposal")
@require_role("ADMIN")
def dispose_scrap_route():
    model = validate_json(ScrapDisposalInput)
    payload = {
        "material_id": str(model.material_id),
        "quantity": model.quantity,
        "unit_id": str(model.unit_id),
        "source_location_id": str(model.source_location_id),
        "reason": model.disposal_reason,
    }
    return jsonify(dispose_scrap(payload, idempotency=_idempotency_or_error())), 200


@stock_bp.post("/stock/adjustments")
@require_role("ADMIN")
def stock_adjustment_post_route():
    model = validate_json(StockAdjustmentInput)
    if str(model.supervisor_approved_by) != g.user_id:
        raise ApiError(
            422,
            "VALIDATION_ERROR",
            "supervisorApprovedBy must be the authenticated administrator approving the adjustment.",
        )
    payload = {
        "material_id": str(model.material_id),
        "location_id": str(model.location_id),
        "counted_quantity": model.counted_quantity,
        "counted_unit_id": str(model.counted_unit_id),
        "reason": model.adjustment_reason,
    }
    return jsonify(post_stock_adjustment(payload, idempotency=_idempotency_or_error())), 200
