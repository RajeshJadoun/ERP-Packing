# Phase 9 — Operational Reports & Analytics Implementation Report

**Date:** 2026-10-20  
**Status:** Core implementation committed; CI and environment-backed verification are tracked separately.

## Delivered

### PostgreSQL reporting layer

Migration `supabase/migrations/20261020150000_phase_9_reporting_views.sql` creates six reporting views:

- `vw_stock_by_location`: material/location balances, active reservations, available-to-promise quantity, canonical unit and a usable / worker-custody / quarantine segment.
- `vw_worker_custody_balance`: outstanding balances joined to the worker assigned to each custody location.
- `vw_material_consumption_variance`: theoretical and posted-ledger usage against physical verification, preserving missing measurements as NULL / UNVERIFIED.
- `vw_vendor_purchase_history`: GRN/PO history, rejected-line rate, order-to-receipt lead time and variance against the expected delivery date.
- `vw_production_shift_summary`: job counts and original, authorized, completed, pending and cancelled quantities by daily plan and shift.
- `vw_worker_production_output`: completion batches, completed jobs and output by worker, plan and shift.

The views are created with `security_invoker=true`, SELECT is granted to `authenticated`, and privileges are revoked from `PUBLIC` and `anon`. SQL verification against the linked Supabase project confirmed that the six views exist, are configured with invoker privileges, deny SELECT to `anon` and grant SELECT to `authenticated`. Underlying table RLS remains the access-control boundary.

The migration also adds indexes for common date, shift, receipt-line, completion and active-reservation access patterns.

### Flask reporting API

All endpoints are registered below `/api/v1`. The application factory's existing global authentication middleware requires a verified Supabase JWT for every report request. Backend reporting is read-only and uses the signed-in caller token for PostgREST; it does not use a service-role credential.

| Endpoint | Purpose |
| --- | --- |
| `GET /reports/stock` | Inventory by material and location |
| `GET /reports/worker-custody` | Materials outstanding with workers |
| `GET /reports/consumption-variance` | Theoretical / ledger / physical usage and variance state |
| `GET /reports/production-shifts` | Plan/shift planned-to-completed quantities |
| `GET /reports/worker-output` | Output by worker and shift |
| `GET /reports/vendor-purchase-history` | Receipt, rejected-line and delivery timing history |

Queries accept bounded `limit` / `offset` pagination. Date filters validate ISO dates and reject reversed ranges. Shift codes, UUID identifiers and pagination bounds are validated before a database query. Date ranges are inclusive and handled as a single PostgREST logical conjunction.

### React analytics workspace

The `/reports` screen now includes:

- Live read-only reports for inventory, consumption variance, production shifts, worker output, vendor history and worker custody.
- Server-side date, shift, material, worker and vendor filters where they apply, plus quick search over returned rows.
- Inventory-segment and shift-completion bar summaries.
- CSV export of the currently displayed, search-filtered report rows.
- Browser print support for printing or saving the report as PDF.
- Explicit separation of current inventory snapshots from time-filtered transactional reports; missing physical consumption is never interpreted as zero.

The CSV output contains the row fields returned by the reporting view, with standard CSV quoting handled by the shared CSV helper.

## Validation

- Frontend CI: [run 39443676394](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39443676394) succeeded after TypeScript compilation, Vitest and the production build.
- Flask backend CI: [run 39443769015](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39443769015) succeeded, including the backend tests and Ruff lint.
- Automated coverage added:
  - `backend/tests/test_reports.py` validates allow-listed views, filters, date ranges, UUID validation, pagination and authentication.
  - `frontend/src/pages/reports/ReportsAnalytics.test.tsx` checks report rendering, search and CSV export arguments.
  - `supabase/tests/phase_9_reporting_views.test.sql` checks view existence, invoker security, key output columns and role-level SELECT grants.
- Live SQL inspection confirmed all six views exist and have `security_invoker=true`, `anon_can_select=false` and `authenticated_can_select=true`.

## Environment limits / remaining verification

The linked Supabase project currently has zero Auth users and no operational rows in the core inventory, purchase, plan, production and consumption tables. The migration and access configuration can be verified, but a real signed-in user's report payloads cannot be validated against representative production data until user provisioning and seed/operational data are available. Query latency targets also need a populated-data benchmark. Phase 8's public frontend/API deployment and end-to-end JWT/RLS smoke test remain separate release gates.

## Files

- `supabase/migrations/20261020150000_phase_9_reporting_views.sql`
- `supabase/tests/phase_9_reporting_views.test.sql`
- `backend/app/services/reporting_service.py`
- `backend/app/routes/reports.py`
- `backend/tests/test_reports.py`
- `frontend/src/pages/reports/ReportsAnalytics.tsx`
- `frontend/src/pages/reports/reports.css`
- `frontend/src/pages/reports/ReportsAnalytics.test.tsx`
- `docs/API_CONTRACT.yaml`
- `docs/IMPLEMENTATION_PLAN.md`
