# CODEX MASTER PROMPT

You are the senior engineer implementing the Packing Material Inventory & BOM Management System in the CURRENT repository.

## First
Inspect the repository, existing code, package manager, tests, configuration and deployment. Do not overwrite working code blindly. Create and maintain `docs/PRD.md`, `docs/MRD.md`, `docs/SYSTEM_DESIGN.md`, `docs/UI_UX_WALKTHROUGH.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/TEST_PLAN.md`, `docs/REQUIREMENT_TRACEABILITY.md`, `docs/OPEN_DECISIONS.md`, `docs/ARCHITECTURE_DECISIONS.md`. Use the requirements in this prompt and companion documents.

## Stack
React + Vite + TypeScript frontend; Supabase PostgreSQL, Auth, RLS and Instant REST API; Python Flask REST API for critical business workflows; versioned SQL migrations. Frontend uses only Supabase publishable/anon key. Never expose service-role key. Vitest + React Testing Library for frontend testing; pytest for backend testing.

## Must implement
- Masters: parties, products, material variants, vendors, workers, locations, units and exact/estimated conversions.
- Purchase/inward: vendor, purchase date, received date, invoice/reference, quantity, weight, PCS, boxes and location. Only posted inward increases stock.
- Immutable stock ledger and stock by location.
- Issue to worker as custody transfer, not consumption; track measured issue, consumption, return and outstanding.
- Reusable/versioned BOM per finished product, optional party-specific BOM, job-specific snapshot/customization.
- Manual daily plan containing multiple jobs; same party/product can appear repeatedly with different packing materials/sizes/BOMs.
- Quantity revision with history/reason (520→450); cancellation with reconciliation of reservations, issue, custody, completed production and consumption.
- Partial production (1000 planned, 530 completed, 470 pending).
- Separate theoretical BOM usage from actual recorded consumption.
- Reservations affect available stock, not physical stock.
- Variance, daily closing, stock shortage, low stock, vendor/party/worker reports and audit trail.
- No direct stock balance editing; corrections are explicit audited movements.

## Database minimum
`profiles`, `parties`, `products`, `vendors`, `units`, `materials`, `material_conversions`, `locations`, `workers`, `boms`, `bom_lines`, `bom_revision_events`, `purchase_orders`, `purchase_order_lines`, `goods_receipts`, `goods_receipt_lines`, `daily_plans`, `packing_jobs`, `packing_job_bom_snapshots`, `packing_job_bom_snapshot_lines`, `packing_job_revisions`, `packing_job_events`, `stock_reservations`, `production_completions`, `stock_transactions`, `material_consumption_records`, `stock_adjustments`, `daily_closings`, `audit_logs`. UUIDs, foreign keys, numeric quantities, check constraints, indexes and RLS are mandatory.

## Critical invariants
Receipt increases stock once; issue/return/transfer change location/custody without changing total; consumption reduces total once; reservation only reduces available stock; damage/adjustment requires reason; no negative stock by default; KG and PCS are not interchangeable without material-specific conversion; historical jobs retain frozen BOM snapshots; cancellation never deletes history; all critical commands are transactional and idempotent.

## UI
Build login, dashboard, all master screens, purchasing/inward, current stock and ledger, worker issue/return/custody, BOM master/versioning, daily plan/jobs, production completion, variance, daily closing, reports and admin/roles. Responsive layout, search/filter/sort/pagination, explicit units, clear errors/empty/loading states, confirmation for irreversible actions, no dead buttons.

## API
Use `/api/v1`, typed validation, auth/permission checks, consistent JSON errors and request IDs. Implement master CRUD plus transactional commands for receipt posting, issue, return, transfer, damage, adjustment, BOM versioning, plan/job creation, revision/cancellation, reservation, completion, consumption, closing and reports. Supabase REST is for safe CRUD/read paths; Flask/database transactions for multi-row stock operations.

## Security/reliability
RLS default-deny, JWT verification in Flask, no client service-role key, server-side validation, numeric quantities, row locks/atomic SQL, idempotency keys, audit event in same transaction as stock movement, `.env.example`, structured logs and no secrets in logs.

## Tests
Test estimated conversions, BOM calculation, different BOMs for same party/product, 520→450 revision, cancellation before/after issue, partial completion, issue vs consumption vs return, concurrent issues, duplicate retry, negative stock prevention, immutable snapshots, RLS, daily close and clean migration. Run tests/lint/build; report actual results only.

## Phases
0 repository audit; 1 docs; 2 migrations/RLS; 3 Flask core/tests; 4 masters/purchase; 5 stock/custody; 6 BOM/planning; 7 production/consumption/closing; 8 React UI; 9 reports; 10 integration/security tests and walkthrough. After each phase report changed files, commands/tests actually run, results and unresolved risks. Do not stop at planning: continue implementing unless credentials or a truly blocking decision is missing. If credentials are absent, build the local setup and document what needs configuration.

## Deliverables
Working source code, migrations/RLS, Flask API/tests, React app, `.env.example`, README, docs and final walkthrough. Do not claim production-ready or tests passed unless verified.
