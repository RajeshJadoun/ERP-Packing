# PRD — Packing Inventory & BOM Management System
## Goal
Manage vendor purchasing/inward, packing material stock, locations, worker custody, reusable BOMs, party-specific packing jobs, production completion, material consumption, returns, variances and daily closing.

## Stack
- React + Vite + TypeScript frontend.
- Supabase PostgreSQL database and Instant REST API for permitted CRUD/read operations.
- Flask REST API for critical business workflows.
- Supabase Auth + RLS; SQL migrations; pytest and frontend tests.

## Users
Admin; Storekeeper; Planner/Production Coordinator; Production Operator; Viewer/Manager. Permissions must be checked server-side and in RLS.

## Requirements
1. Master data: parties, products, material variants, vendors, workers, units/conversions and hierarchical locations.
2. Materials include carton, poly bag, foam, bubble bag, screws and admin-added future items. Track thickness, height, width, length, size/specification.
3. Vendor history stores purchase date separately from actual received date. Track invoice/reference, received quantity, weight, PCS, boxes, accepted/rejected quantity and location.
4. Only posted inward receipts increase stock; purchase orders do not.
5. Stock ledger is authoritative. Never directly edit current stock balances.
6. Worker issue is custody/location transfer, not consumption. Track issue, measured/actual consumption, return, damage and outstanding balance.
7. BOM is reusable material-per-finished-unit definition, versioned and optionally party-specific. Same product/party may have multiple jobs with different BOMs and screw sizes.
8. Daily packing plan is entered from a manually supplied list and can contain many jobs. Same product may appear multiple times.
9. Job quantity revisions (e.g. 520 to 450) require reason and audit history. Cancellation reconciles reservations, issued stock, worker custody, production and consumption.
10. Partial completion supported (plan 1000, pack 530, pending 470). Pending must be carried forward, rescheduled or cancelled explicitly.
11. BOM theoretical consumption must be distinguishable from measured actual consumption.
12. Reservation reduces available stock, not physical stock.
13. Daily close summarizes planned/completed/pending/cancelled, expected/actual usage, variance and worker outstanding.
14. Reports: current stock by location, ledger, vendor purchases/receipts, party packing, shortages, worker custody, variance, low stock and audit log.
15. All critical operations are atomic, idempotent, auditable and protected from negative stock by default.

## UX
Dashboard with today's jobs, completion, shortages, low stock, worker outstanding and variance alerts. Sidebar for Masters, Purchasing, Inventory, BOM, Daily Packing, Production, Closing, Reports and Admin. Tables need search, filters, sorting, pagination and clear loading/empty/error states. Confirmation and reason required for cancellation, revision, adjustment and closing exceptions.
