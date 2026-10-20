"""Flask routes for master BOM creation, versioning and activation."""

from __future__ import annotations

from decimal import Decimal
from uuid import UUID

from flask import Blueprint, g, jsonify
from pydantic import BaseModel, ConfigDict, Field, field_validator

from ..auth import require_role
from ..errors import ApiError
from ..services.bom_service import (
    activate_bom_version,
    create_bom,
    create_bom_version,
    get_bom,
)
from ..validation import validate_json

boms_bp = Blueprint("boms", __name__)


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


class CreateBomInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    product_id: UUID = Field(alias="productId")
    party_id: UUID | None = Field(default=None, alias="partyId")
    packing_variant_name: str = Field(alias="packingVariantName", min_length=1, max_length=120)
    version_notes: str | None = Field(default=None, alias="versionNotes", max_length=2000)
    lines: list[BomLineInput] = Field(min_length=1, max_length=250)

    @field_validator("packing_variant_name")
    @classmethod
    def normalize_variant_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("packingVariantName must not be blank.")
        return normalized

    @field_validator("version_notes")
    @classmethod
    def normalize_notes(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None


class CreateBomVersionInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    revision_reason: str = Field(alias="revisionReason", min_length=3, max_length=2000)
    lines: list[BomLineInput] = Field(min_length=1, max_length=250)

    @field_validator("revision_reason")
    @classmethod
    def normalize_reason(cls, value: str) -> str:
        normalized = value.strip()
        if len(normalized) < 3:
            raise ValueError("revisionReason must contain at least 3 non-space characters.")
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


@boms_bp.post("/boms")
@require_role("ADMIN", "PLANNER")
def create_bom_route():
    model = validate_json(CreateBomInput)
    result = create_bom(
        {
            "product_id": model.product_id,
            "party_id": model.party_id,
            "packing_variant_name": model.packing_variant_name,
            "version_notes": model.version_notes,
            "lines": [_line_payload(line) for line in model.lines],
        },
        idempotency=_idempotency(),
    )
    return jsonify(result), 201


@boms_bp.post("/boms/<bom_id>/new-version")
@require_role("ADMIN", "PLANNER")
def create_bom_version_route(bom_id: str):
    model = validate_json(CreateBomVersionInput)
    result = create_bom_version(
        bom_id,
        {
            "revision_reason": model.revision_reason,
            "lines": [_line_payload(line) for line in model.lines],
        },
        idempotency=_idempotency(),
    )
    return jsonify(result), 201


@boms_bp.post("/boms/<bom_id>/activate")
@require_role("ADMIN", "PLANNER")
def activate_bom_version_route(bom_id: str):
    return jsonify(activate_bom_version(bom_id, idempotency=_idempotency())), 200


@boms_bp.get("/boms/<bom_id>")
def get_bom_route(bom_id: str):
    return jsonify(get_bom(bom_id)), 200
