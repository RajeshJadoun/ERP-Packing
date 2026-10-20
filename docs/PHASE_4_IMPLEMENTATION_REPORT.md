# Phase 4 Implementation Report — Purchasing Foundation

**Status:** Phase 4 purchasing slice implemented on the feature branch; CI passes.  
**Validation:** Flask backend: 41 pytest tests + Ruff lint passed. Database suite: 200 pgTAP assertions passed.

- Repository: [RajeshJadoun/ERP-Packing](https://github.com/RajeshJadoun/ERP-Packing)
- Phase 4 pull request: [PR #3](https://github.com/RajeshJadoun/ERP-Packing/pull/3)
- Backend validation run: [Flask Backend Tests](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39377783758)
- Database validation run: [Supabase Database Tests](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39377783764)
- Feature branch: `phase-4/master-data-purchasing`

## Delivered

### Purchase orders

- Added `purchase_order_lines.unit_price`, matching the existing OpenAPI `unitPrice` field.
- Added atomic `rpc_create_purchase_order` which creates the PO header and lines in one transaction.
- The RPC checks the caller's actual JWT-backed application role, validates the active vendor, material, units, quantities, date range, and duplicate material lines, then persists the price.
- Purchase orders start in `DRAFT`; creating a PO does not alter stock.
- A repeated matching idempotency key returns the original response; a conflicting hash fails closed.
- Revoked authenticated direct write privileges for PO headers/lines so the transaction boundary cannot be bypassed.

### Goods receipts

- Added a database header-validation trigger checking vendor activity, invoice/receipt dates, receiving destination, PO/vendor consistency, and draft-only direct insertion.
- Direct PostgREST may stage receipt headers in `DRAFT`; posting stays on the existing transactional `rpc_post_goods_receipt`.
- Added Flask `POST /api/v1/goods-receipts/post` and `GET /api/v1/goods-receipts/{id}`.
- The POST handler returns persisted server-calculated accepted/canonical quantities, conversion provenance, and ledger references after the transactional RPC completes.

### API/service integration

- Added `POST /api/v1/purchase-orders` and `GET /api/v1/purchase-orders/{id}`.
- Added allow-listed, caller-JWT-scoped PostgREST helpers for master catalogs and purchasing reads.
- Authentication, profile RBAC, RLS, and database functions remain the trust boundary; no service-role key is used for request authorization.
- Updated API/schema documentation and local setup notes.

## Validation results

| Validation | Result |
|---|---|
| Python pytest | 41 passed |
| Ruff lint | Passed |
| pgTAP database suite | 9 SQL test files, 200 assertions, PASS |
| Phase 4-specific checks | Unit price persistence; role restrictions; direct-write grants; PO replay/conflict; no inventory side effect; dynamic category insert; GRN date/destination validation |

The Phase 4-specific pgTAP suite has 16 assertions. The database job applies the migrations to a fresh local Supabase stack before running all tests.

## Migration & deployment status

Migration `20261020000006_phase_4_purchasing_rpc.sql` has been merged and applied to the linked Supabase project (`PACKING ERP`, `bkyzwdaazscsiocmefbn`, `ap-south-1`). The remote migration ledger records `20261020000006_phase_4_purchasing_rpc`.

Post-apply checks against the linked project confirmed:

- The `purchase_order_lines.unit_price` column exists.
- `authenticated` cannot directly insert purchase order headers or lines.
- `authenticated` can execute the new `rpc_create_purchase_order` RPC.
- The `goods_receipts` validation trigger is installed.
- The RPC is `SECURITY DEFINER` with an empty `search_path`.

The application/backend itself has **not been deployed**. Supabase advisor notices remain consistent with the previous security model: the two idempotency tables intentionally have no direct RLS policies (fail-closed), authenticated RPCs use explicit server-side role checks, and unused-index notices remain on the relatively fresh database. Re-evaluate unused indexes after meaningful production workload rather than removing them pre-emptively.

This is the first Phase 4 purchasing slice, not the completion of every later ERP phase. BOM/planning, stock movement APIs, production, closing, reporting and frontend work remain in the roadmap.
