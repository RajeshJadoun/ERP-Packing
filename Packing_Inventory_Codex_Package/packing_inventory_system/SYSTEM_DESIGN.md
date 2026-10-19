# System Design
## Architecture
React + Vite + TypeScript → Supabase Auth and Instant REST API for safe permitted CRUD/read → Flask `/api/v1` for critical commands → Supabase PostgreSQL transactions. Never expose service-role key to browser. Use versioned SQL migrations.

## Tables
- Identity: `profiles` (references `auth.users`, role, active).
- Masters: `parties`, `products`, `vendors`, `units`, `materials`, `material_conversions`, `locations` (parent self-FK), `workers`.
- BOM: `boms`, `bom_lines`, `bom_revision_events`.
- Purchase: `purchase_orders`, `purchase_order_lines`, `goods_receipts`, `goods_receipt_lines`.
- Planning: `daily_plans`, `packing_jobs`, `packing_job_bom_snapshots`, `packing_job_bom_snapshot_lines`, `packing_job_revisions`, `packing_job_events`.
- Inventory: `stock_reservations`, `production_completions`, `stock_transactions`, `material_consumption_records`, `stock_adjustments`, `daily_closings`, `audit_logs`.

Use UUID primary keys, real foreign keys, `numeric` quantities, `timestamptz`, check constraints and indexes. Deactivate referenced master records instead of deleting history.

## Relationships
- Vendor 1:N purchase orders and goods receipts.
- Purchase order 1:N order lines; goods receipt 1:N receipt lines.
- Product 1:N BOMs and packing jobs; Party 1:N party BOMs and jobs.
- BOM 1:N BOM lines; packing job references a frozen BOM snapshot.
- Daily plan 1:N packing jobs.
- Material 1:N receipt lines, BOM lines, reservations, consumption records and stock transactions.
- Locations are hierarchical; worker custody is represented as a location/custody movement.
- Packing job 1:N revisions, events, completions, reservations, consumption and linked stock movements.

## Stock invariants
- Receipt: stock increases only when posted.
- Issue to worker: store stock decreases, worker custody increases; total physical stock unchanged.
- Return: custody decreases, store increases; total unchanged.
- Consumption: total stock decreases exactly once.
- Transfer: location changes; total unchanged.
- Reservation: available-to-promise decreases; physical stock unchanged.
- Damage/write-off: stock decreases with reason/permission.
- Adjustment: explicit audited transaction.
- Never sum KG and PCS without valid material-specific conversion.
- Store positive movement magnitude and derive direction from movement type/location, consistently; do not mix sign conventions.
- Post movement and audit event in the same transaction.

## API commands
`GET /health`; CRUD masters; `POST /api/v1/boms/{id}/new-version`; `POST /api/v1/goods-receipts`; `GET /api/v1/stock/balances`; `GET /api/v1/stock/ledger`; `POST /api/v1/stock/issue-to-worker`; `POST /api/v1/stock/return-from-worker`; `POST /api/v1/stock/transfer`; `POST /api/v1/stock/damage`; `POST /api/v1/stock/adjustments`; create daily plans/jobs; revise/cancel jobs; reserve materials; record production completion/consumption; close/reopen plan; reports for material requirements, worker custody and variance.

## Security and reliability
- Supabase Auth; verify tokens in Flask.
- RLS enabled, default-deny policies.
- Frontend uses publishable/anon key only.
- Critical stock commands use DB transactions, row locks/atomic functions and idempotency keys.
- Never read balance in React and write back a new balance.
- Server validates permissions, units, status transitions, quantities and references.
- Structured logs, request IDs, no secrets in logs, `.env.example`.
- Test concurrent issues, retries, cancellation, historical snapshots, RLS and migrations.

## Acceptance tests
1. Estimated kg-to-PCS conversion is labelled estimated.
2. Plan 1000, complete 530 gives expected 530 bags, 530 foam, 2120 screws.
3. Same party/product supports different BOMs/screw sizes.
4. Revision 520→450 retains history and updates reservation.
5. Cancellation reconciles custody/production.
6. Issue/return/transfer preserve total stock; consumption reduces it exactly once.
7. Concurrent issue cannot overspend stock; same idempotency key cannot duplicate movement.
8. Historical BOM snapshot is unchanged after master revision.
9. Unauthorized RLS/API operations are blocked.
10. Daily close handles variance and outstanding custody explicitly.
