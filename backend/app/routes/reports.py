"""Authenticated, validated HTTP endpoints for operational reporting."""

from __future__ import annotations

import re
from datetime import date
from uuid import UUID

from flask import Blueprint, jsonify, request

from ..errors import ApiError
from ..services.reporting_service import list_report_rows

reports_bp = Blueprint("reports", __name__)

_DATE_FIELDS = ("fromDate", "toDate")
_MAX_LIMIT = 1000
_MAX_OFFSET = 100_000


def _date_value(name: str) -> date | None:
    value = request.args.get(name)
    if value is None or not value.strip():
        return None
    try:
        return date.fromisoformat(value.strip())
    except ValueError as exc:
        raise ApiError(400, "BAD_REQUEST", f"{name} must use YYYY-MM-DD format.") from exc


def _uuid_filter(argument: str, column: str, filters: dict[str, str]) -> None:
    raw = request.args.get(argument)
    if raw is None or not raw.strip():
        return
    try:
        normalized = str(UUID(raw.strip()))
    except ValueError as exc:
        raise ApiError(400, "BAD_REQUEST", f"{argument} must be a valid UUID.") from exc
    filters[column] = f"eq.{normalized}"


def _date_filters(date_column: str | None, filters: dict[str, str]) -> None:
    start = _date_value("fromDate")
    end = _date_value("toDate")
    if start and end and start > end:
        raise ApiError(400, "BAD_REQUEST", "fromDate cannot be later than toDate.")
    if date_column and start:
        filters[date_column] = f"gte.{start.isoformat()}"
    if date_column and end:
        filters[f"{date_column}"] = (
            f"gte.{start.isoformat()}" if start and start == end else filters.get(date_column, "")
        )
        if start and start == end:
            filters[date_column] = f"eq.{start.isoformat()}"
        else:
            filters.pop(date_column, None) if start and end else None
            if start:
                filters[f"{date_column}"] = f"gte.{start.isoformat()}"
            if end:
                filters[f"{date_column}"] = f"lte.{end.isoformat()}"
    # PostgREST accepts only one filter per column. Use the explicit range
    # syntax for inclusive boundaries when both dates are supplied.
    if date_column and start and end and start != end:
        filters[f"{date_column}"] = f"gte.{start.isoformat()}"
        filters[f"{date_column}__upper"] = f"lte.{end.isoformat()}"


def _range_filters(date_column: str | None, filters: dict[str, str]) -> None:
    start = _date_value("fromDate")
    end = _date_value("toDate")
    if start and end and start > end:
        raise ApiError(400, "BAD_REQUEST", "fromDate cannot be later than toDate.")
    if date_column:
        if start and end and start == end:
            filters[date_column] = f"eq.{start.isoformat()}"
        else:
            if start:
                filters[date_column] = f"gte.{start.isoformat()}"
            if end:
                filters[f"{date_column}__lte"] = f"lte.{end.isoformat()}"


def _pagination() -> tuple[int, int]:
    try:
        limit = int(request.args.get("limit", "500"))
        offset = int(request.args.get("offset", "0"))
    except ValueError as exc:
        raise ApiError(400, "BAD_REQUEST", "limit and offset must be integers.") from exc
    if not 1 <= limit <= _MAX_LIMIT:
        raise ApiError(400, "BAD_REQUEST", f"limit must be between 1 and {_MAX_LIMIT}.")
    if not 0 <= offset <= _MAX_OFFSET:
        raise ApiError(400, "BAD_REQUEST", f"offset must be between 0 and {_MAX_OFFSET}.")
    return limit, offset


def _shift_filter(filters: dict[str, str]) -> None:
    raw = request.args.get("shiftCode")
    if raw is None or not raw.strip():
        return
    value = raw.strip().upper()
    if len(value) > 30 or not re.fullmatch(r"[A-Z0-9_-]+", value):
        raise ApiError(400, "BAD_REQUEST", "shiftCode may contain only letters, digits, underscores and hyphens.")
    filters["shift_code"] = f"eq.{value}"


def _list(report: str, *, date_column: str | None = None, material: bool = False,
          worker: bool = False, vendor: bool = False, shift: bool = False):
    filters: dict[str, str] = {}
    start = _date_value("fromDate")
    end = _date_value("toDate")
    if start and end and start > end:
        raise ApiError(400, "BAD_REQUEST", "fromDate cannot be later than toDate.")
    if date_column:
        if start and end and start != end:
            filters["and"] = f"({date_column}.gte.{start.isoformat()},{date_column}.lte.{end.isoformat()})"
        elif start and end:
            filters[date_column] = f"eq.{start.isoformat()}"
        elif start:
            filters[date_column] = f"gte.{start.isoformat()}"
        elif end:
            filters[date_column] = f"lte.{end.isoformat()}"
    if material:
        _uuid_filter("materialId", "material_id", filters)
    if worker:
        _uuid_filter("workerId", "worker_id", filters)
    if vendor:
        _uuid_filter("vendorId", "vendor_id", filters)
    if shift:
        _shift_filter(filters)

    limit, offset = _pagination()
    rows = list_report_rows(report, filters, limit=limit, offset=offset)
    return jsonify(rows), 200

@reports_bp.get("/reports/stock")
def report_stock():
    return _list("stock", material=True)


@reports_bp.get("/reports/worker-custody")
def report_worker_custody():
    return _list("worker-custody", material=True, worker=True)


@reports_bp.get("/reports/consumption-variance")
def report_consumption_variance():
    return _list("consumption-variance", date_column="completion_date", material=True, worker=True, shift=True)


@reports_bp.get("/reports/production-shifts")
def report_production_shifts():
    return _list("production-shifts", date_column="plan_date", shift=True)


@reports_bp.get("/reports/worker-output")
def report_worker_output():
    return _list("worker-output", date_column="plan_date", worker=True, shift=True)


@reports_bp.get("/reports/vendor-purchase-history")
def report_vendor_purchase_history():
    return _list("vendor-purchase-history", date_column="received_date", vendor=True)
