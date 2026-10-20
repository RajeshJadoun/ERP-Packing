"""Caller-scoped read-only reporting queries over secured PostgreSQL views."""

from __future__ import annotations

from typing import Any

from ..services.master_service import rest_select

_REPORT_VIEWS = {
    "stock": ("vw_stock_by_location", "material_code.asc,location_code.asc"),
    "worker-custody": ("vw_worker_custody_balance", "worker_name.asc,material_code.asc"),
    "consumption-variance": ("vw_material_consumption_variance", "completion_timestamp.desc,material_code.asc"),
    "production-shifts": ("vw_production_shift_summary", "plan_date.desc,shift_code.asc"),
    "worker-output": ("vw_worker_production_output", "plan_date.desc,completed_units.desc"),
    "vendor-purchase-history": ("vw_vendor_purchase_history", "received_date.desc,grn_number.desc"),
}


def list_report_rows(report: str, filters: dict[str, str], *, limit: int, offset: int) -> list[dict[str, Any]]:
    """Read one allow-listed view; the signed-in caller JWT and Postgres RLS scope rows."""
    try:
        view_name, ordering = _REPORT_VIEWS[report]
    except KeyError as exc:
        raise ValueError("Reporting view is not allow-listed.") from exc

    params = {
        "select": "*",
        "order": ordering,
        "limit": str(limit),
        "offset": str(offset),
        **filters,
    }
    return rest_select(view_name, params=params)
