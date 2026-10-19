# Test Strategy & Quality Assurance Plan

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## 1. Test Strategy & Architectural Verification

The testing strategy is engineered to guarantee strict inventory invariants, prevent concurrency race conditions, verify PostgreSQL Row Level Security (RLS) policies, prevent historical data loss, and validate end-to-end operator workflows.

### 1.1 Testing Pyramid & Framework Matrix

| Level | Scope | Framework | Execution Target | Invariants Verified |
| :--- | :--- | :--- | :--- | :--- |
| **Unit Tests** | Math, Conversions, Validations | `pytest` | Python Backend | Exact vs estimated unit math, signed aggregation equations, BOM theoretical scaling. |
| **Database & RLS Tests** | Policies, Triggers & Restrict Actions | `pytest` + `psycopg2` | Supabase PostgreSQL | Hardened `get_current_user_role()`, `trg_protect_profile_role` (`IS DISTINCT FROM 'ADMIN'`), anti-cascade `ON DELETE RESTRICT`, direct PostgREST lockout across all 33 tables. |
| **Transactional Integration** | Multi-step Services & Endpoints | `pytest` + Flask Test Client | Flask REST API (`/api/v1`) | Inward posting, worker issue, return, quarantine, scrap disposal, 520 $\to$ 450 revision, daily close, multi-row idempotency. |
| **Concurrency & Lock Tests** | Race Conditions & Idempotency | `pytest` + `threading` | Live PostgreSQL Test DB | Two workers issuing same stock simultaneously; duplicate idempotency retries; multi-row payload replay; payload mismatch conflict. |
| **Frontend Component Tests** | Forms, Validation, UI State | `Vitest` + React Testing Library | JSDOM Environment | Category dropdown, JSON spec editor, dual-unit display formatting, unverified variance badge, modal guards. |
| **Frontend Integration Tests**| User Journeys & API Mocking | `Vitest` + `MSW` | JSDOM Environment | Scenario walkthroughs (GRN receipt, quarantine vs disposal, job revision, daily close, custom BOM jobs). |

---

## 2. Core Acceptance Scenarios

### Acceptance Scenario 1: Dual-Unit & Estimated Conversion Labeling
- **Requirement:** 25 KG of poly bags received with estimated calibration (1 KG ≈ 100 PCS). Never sum KG and PCS.
- **Test Steps:**
  1. Post inward receipt with only original measurements: `enteredQuantity = 25.000`, `enteredUnitId = KG`, `rejectedQuantity = 0`, `rejectedUnitId = KG`, and physical evidence. Do not submit accepted, canonical, factor, direction, or estimation fields.
  2. Query `GET /api/v1/stock/balances`.
- **Expected Results:**
  - Trusted response returns accepted quantity/unit, canonical quantity/unit, selected rule ID/factor/direction, and estimated classification; the authoritative balance in canonical unit is exactly `25.000 KG`.
  - Secondary estimated quantity is returned as `2500` with flag `is_estimated = true`.
  - UI renders: `25.000 KG (≈ 2,500 PCS)`.
  - Attempting to add `25 KG` and `100 PCS` directly throws `INVALID_UNIT_ARITHMETIC` error.
  - A deliberately incorrect optional `expectedCanonicalQuantity` is rejected or flagged against the trusted result and cannot alter the ledger.

---

### Acceptance Scenario 2: BOM Theoretical Scaling & Unverified Variance Tracking
- **Requirement:** Product X has BOM: 1 poly bag, 1 foam piece, 4 screws M4. Job planned for 1,000 units. Completed batch: 530 units.
- **Test Steps:**
  1. Release packing job of 1,000 units.
  2. Record production completion of `530 units` using `AUTO_BOM_THEORETICAL`.
  3. Query `material_consumption_records` linked to the completion batch.
- **Expected Results:**
  - Theoretical requirement calculated as:
    - Poly Bag: $530 \times 1 = 530\text{ PCS}$.
    - Foam Piece: $530 \times 1 = 530\text{ PCS}$.
    - Screws M4: $530 \times 4 = 2,120\text{ PCS}$.
  - Auto-consumption ledger rows logged with `measurement_method = 'AUTO_BOM_BACKFLUSH'`, `is_estimated = true`.
  - In `material_consumption_records`, `physically_confirmed_quantity = NULL`, `variance_quantity = NULL`, and `variance_status = 'UNVERIFIED'`.
  - System does NOT falsely claim variance is zero. UI displays pending verification badge.
  - Pending units on job updates to $1,000 - 530 = 470\text{ units}$. Job status updates to `PARTIALLY_COMPLETED`.

---

### Acceptance Scenario 3: Repeated Product with Distinct BOMs & Screw Sizes
- **Requirement:** Same party and product appears multiple times on the same date with different packaging specifications.
- **Test Steps:**
  1. Create Daily Plan for date `2026-10-15` and `shift_code = 'SHIFT_1'`.
  2. Add Job 1: Party A, Product X, 300 units, BOM V1 (Screw M4x10mm).
  3. Add Job 2: Party A, Product X, 100 units, BOM V2 (Screw M4x16mm + Bubble Sheet).
  4. Release Daily Plan.
- **Expected Results:**
  - Both jobs are assigned distinct `job_code` identifiers and distinct snapshot records.
  - Snapshot 1 requires 1,200 screws of M4x10mm.
  - Snapshot 2 requires 400 screws of M4x16mm and 100 bubble sheets.
  - Stock reservations are segregated by material SKU without cross-contamination.

---

### Acceptance Scenario 4: Quantity Revision (520 $\to$ 450 Units)
- **Requirement:** In-flight planned quantity revision preserves original quantity, records reason, and recalculates material reservation.
- **Test Steps:**
  1. Release Job of 520 units. Initial screw reservation: $520 \times 4 = 2,080\text{ PCS}$.
  2. Send `POST /api/v1/packing-jobs/{id}/revise-quantity` with `revisedQuantity = 450` and `reason = "Truck transport capacity limitation"`.
- **Expected Results:**
  - HTTP 200 OK.
  - `packing_job_revisions` contains row: `original_quantity = 520`, `revised_quantity = 450`, `difference = -70`.
  - Job status fields: `original_planned_quantity = 520`, `current_revised_quantity = 450`, `pending_quantity = 450`.
  - Screw reservation is reduced from 2,080 to $450 \times 4 = 1,800\text{ PCS}$ (releasing 280 screws to available stock).
  - Attempting to revise below completed units (e.g., revising to 400 when 450 already packed) fails with HTTP 422.

---

### Acceptance Scenario 5: Job Cancellation Reconciling Custody and Completed Output
- **Requirement:** Cancellation never deletes rows; reconciles completed units, remaining reservations, and worker custody.
- **Test Steps:**
  1. Job planned for 1,000 units. 530 units packed. Worker holds 100 unused screws in custody.
  2. Planner attempts cancellation via `POST /api/v1/packing-jobs/{id}/cancel`.
- **Expected Results:**
  - Initial attempt is blocked with error `OUTSTANDING_WORKER_CUSTODY` (100 screws remain with worker).
  - Storekeeper posts return of 100 screws (`RETURN_FROM_WORKER`). Worker custody becomes 0.
  - Planner re-submits cancellation.
  - HTTP 200 OK.
  - 530 packed units and past consumption records remain intact in database.
  - `cancelled_quantity` is set to 470, `pending_quantity` becomes 0. Status becomes `CANCELLED`.
  - Unused reservations for 470 units are completely released.

---

### Acceptance Scenario 6: Authoritative Stock Ledger Balance Invariants
- **Requirement:** Signed aggregation equations correctly calculate store balance, worker custody, and total physical stock.
- **Test Steps:**
  1. Shelf A-1 initial balance: 100 KG. Total company stock: 100 KG.
  2. Issue 10 KG to Worker John (`ISSUE_TO_WORKER`).
  3. Transfer 20 KG from Shelf A-1 to Shelf B-2 (`LOCATION_TRANSFER`).
  4. Worker John returns 2 KG to Shelf A-1 (`RETURN_FROM_WORKER`).
  5. Worker John consumes 8 KG in production (`CONSUMPTION`).
- **Expected Results:**
  - Balance equation $\sum \text{dest} - \sum \text{src}$ matches `material_location_balances` exactly:
    - After Step 2: Shelf A-1 = 90 KG, Worker John = 10 KG, Total Stock = 100 KG (Unchanged).
    - After Step 3: Shelf A-1 = 70 KG, Shelf B-2 = 20 KG, Worker John = 10 KG, Total Stock = 100 KG (Unchanged).
    - After Step 4: Shelf A-1 = 72 KG, Shelf B-2 = 20 KG, Worker John = 8 KG, Total Stock = 100 KG (Unchanged).
    - After Step 5: Shelf A-1 = 72 KG, Shelf B-2 = 20 KG, Worker John = 0 KG, Total Stock = 92 KG (Reduced by 8 KG once).

---

### Acceptance Scenario 7: Concurrency, Multi-Row Idempotency & Replay
- **Requirement:** Simultaneous requests cannot overspend inventory; multi-row requests safely link to one owner-bound key; duplicate requests replay only for matching owner/scope/payload; mismatches return generic 409 Conflict.
- **Test Steps:**
  1. Post a Goods Receipt with 3 distinct material items under `Idempotency-Key: KEY-GRN-101`.
  2. Inspect `stock_transactions` for `idempotency_key = 'KEY-GRN-101'`.
  3. Re-send exact request as the same authenticated user, same normalized endpoint, key and payload.
  4. Send request with `KEY-GRN-101` but modify invoice date or line quantity.
- **Expected Results:**
  - Step 1 creates 1 row in `idempotency_keys` and 3 rows in `stock_transactions` with `transaction_sequence = 1, 2, 3`.
  - Step 3 returns cached HTTP 200 response without inserting additional transactions.
  - Step 4 returns **HTTP 409 Conflict** (`IDEMPOTENCY_KEY_REUSE_WITH_DIFFERENT_PAYLOAD`).

---

### Acceptance Scenario 8: Single Active BOM Version & Customized Ad-hoc Snapshots
- **Requirement:** Master BOM updates preserve historical snapshots; at most one active version exists per recipe; completely custom jobs are supported.
- **Test Steps:**
  1. Product X has active BOM V1.
  2. Create BOM V2 for Product X. Attempt to set status to `ACTIVE` directly while V1 is `ACTIVE`.
  3. Execute atomic promotion transaction (V1 $\to$ `SUPERSEDED`, V2 $\to$ `ACTIVE`).
  4. Release custom Job `JOB-CUSTOM-1` with `is_customized = true` and `source_bom_id = NULL`.
- **Expected Results:**
  - Step 2 fails with unique constraint violation on `idx_boms_single_active_version`.
  - Step 3 succeeds atomically. `bom_revision_events` logs the revision reason.
  - Step 4 creates a valid immutable snapshot header (`source_bom_id IS NULL`, `is_customized = true`) and detail lines, successfully releasing the job.

---

### Acceptance Scenario 9: Row Level Security (RLS) & Hardened Role Resolution
- **Requirement:** Direct client-side writes to stock ledger via Supabase PostgREST are blocked; roles verified via hardened `get_current_user_role()`.
- **Test Steps:**
  1. Authenticate as Storekeeper using Supabase client.
  2. Attempt `supabase.from('stock_transactions').insert({...})`.
  3. Attempt to mutate `material_categories` (Admin only).
- **Expected Results:**
  - Both operations throw PostgreSQL RLS violation errors (`new row violates row-level security policy`).
  - Read queries succeed according to user permissions.

---

### Acceptance Scenario 10: End-of-Day Closing with Custody & Shift Resolution
- **Requirement:** Daily close summarizes all metrics for a specific shift and blocks closure if unreturned custody exists.
- **Test Steps:**
  1. Shift 1 plan has 1 job with 20 pending units and Worker Mark holding 15 unreturned poly bags.
  2. Planner attempts `POST /api/v1/closings` without override.
  3. Planner resolves pending units (carries forward to Shift 2) and storekeeper logs return of 15 bags.
  4. Planner re-attempts closing.
- **Expected Results:**
  - Initial attempt fails with error `UNRESOLVED_DISCREPANCIES`.
  - Second attempt succeeds (HTTP 200). `daily_closings` records complete summary; daily plan status updates to `CLOSED`.

---

### Acceptance Scenario 11: Dynamic Admin Creation of Material Categories & Extensible Specs
- **Requirement:** Admin adds new material categories and extensible custom specifications without database migrations.
- **Test Steps:**
  1. Authenticate as `ADMIN`.
  2. Send `POST /api/v1/material-categories` with `{"categoryCode": "DESICCANT", "categoryName": "Silica Gel Desiccants"}`.
  3. Send `POST /api/v1/materials` with `categoryId` pointing to new category, and `additionalSpecs = {"absorption_capacity_pct": 30, "pouch_material": "tyvek"}`.
- **Expected Results:**
  - HTTP 201 Created.
  - New category and material are stored and queryable in catalog immediately.
  - Zero database schema migrations or code changes required.

---

### Acceptance Scenario 12: Segregation of Damage Quarantine vs Scrap Disposal
- **Requirement:** Moving damaged stock to quarantine preserves physical inventory; scrap disposal permanently reduces physical inventory.
- **Test Steps:**
  1. Shelf A-1 initial balance: 500 Cartons. Total physical stock: 500 Cartons.
  2. Move 40 damaged cartons to quarantine (`DAMAGE_QUARANTINE`).
  3. Check inventory balances.
  4. Condemn and write off 40 cartons from quarantine (`SCRAP_DISPOSAL`).
  5. Check inventory balances.
- **Expected Results:**
  - After Step 2: Usable Store Stock = 460, Quarantined Stock = 40, Total Physical Stock = 500 (Unchanged). ATP = 460.
  - After Step 4: Usable Store Stock = 460, Quarantined Stock = 0, Total Physical Stock = 460 (Reduced by 40).

---

### Acceptance Scenario 13: Anti-Cascade Referential Deletion Protection
- **Requirement:** Deleting a parent daily plan, job with completions, or posted GRN is strictly blocked by foreign keys.
- **Test Steps:**
  1. Release Daily Plan `PLAN-001` containing active Job `JOB-001`. Record 1 production completion.
  2. Attempt SQL: `DELETE FROM daily_plans WHERE id = '...';`
  3. Attempt SQL: `DELETE FROM packing_jobs WHERE id = '...';`
  4. Attempt SQL: `DELETE FROM goods_receipts WHERE id = '...';` (for a posted GRN).
- **Expected Results:**
  - All deletion attempts are rejected with foreign key violation errors (`update or delete on table violates foreign key constraint ... on delete restrict`).
  - Production history, frozen snapshots, and goods receipts remain 100% intact.

---

### Acceptance Scenario 14: Fail-Closed Profile Role Protection Trigger
- **Requirement:** A non-admin user cannot escalate role or reactivate an account. Inactive or missing profiles fail closed.
- **Test Steps:**
  1. Authenticate as Storekeeper user (UUID: `user-123`).
  2. Send PostgREST update: `PATCH /profiles?id=eq.user-123` with payload `{"role": "ADMIN"}`.
  3. Simulate an unauthenticated or deactivated profile caller (where `get_current_user_role()` returns `NULL`) attempting to modify `role`.
  4. Send PostgREST update: `PATCH /profiles?id=eq.user-123` with payload `{"full_name": "Storekeeper John Updated"}`.
- **Expected Results:**
  - Step 2 is rejected by `trg_protect_profile_role` with SQL error `42501` (`Only active administrators can modify profile roles or active status`).
  - Step 3 is also rejected immediately: `NULL IS DISTINCT FROM 'ADMIN'` evaluates to `TRUE`, failing closed.
  - Step 4 succeeds (permitted self-service profile update of non-role fields).

---

### Acceptance Scenario 15: Packing Job Five-Variable Quantity Conservation & Cancellation
- **Requirement:** Quantity revision (520 $\to$ 450), partial completion (100 units), and cancellation (350 units) maintain invariant:
  $\text{revised} = \text{completed} + \text{pending} + \text{cancelled}$.
- **Test Steps:**
  1. Release Job `JOB-201` with Planned: 520 units. Verify fields: `original = 520`, `revised = 520`, `completed = 0`, `pending = 520`, `cancelled = 0`.
  2. Revise planned quantity to 450 units (`POST /api/v1/packing-jobs/{id}/revise-quantity`).
  3. Complete batch of 100 units (`POST /api/v1/production/completions`).
  4. Cancel remaining job order (`POST /api/v1/packing-jobs/{id}/cancel`).
- **Expected Results:**
  - After Step 2: `original = 520`, `revised = 450`, `completed = 0`, `pending = 450`, `cancelled = 0`. (Invariant: $450 = 0 + 450 + 0$).
  - After Step 3: `original = 520`, `revised = 450`, `completed = 100`, `pending = 350`, `cancelled = 0`. (Invariant: $450 = 100 + 350 + 0$).
  - After Step 4: `original = 520`, `revised = 450`, `completed = 100`, `pending = 0`, `cancelled = 350`. (Invariant: $450 = 100 + 0 + 350$).
  - Job status updates to `CANCELLED`. 100 completed units and consumption records remain intact.

---

### Acceptance Scenario 16: Strict Leaf-Only Movement Validation
- **Requirement:** Ledger postings must record physical balances strictly against leaf locations (`is_leaf = true`). Parent container nodes, identical source/destination, and invalid flow combinations are rejected.
- **Test Steps:**
  1. Attempt to post transfer where `source_location_id` equals `destination_location_id`.
  2. Attempt to post transfer to a parent warehouse node (`is_leaf = false`).
  3. Attempt to post `CONSUMPTION` with a non-null `destination_location_id`.
  4. Attempt to post `SCRAP_DISPOSAL` where source is `STORE_SHELF` instead of `DAMAGE_QUARANTINE`.
  5. Attempt to post `DAMAGE_QUARANTINE` where destination is `STORE_SHELF`.
- **Expected Results:**
  - Step 1 fails with invariant violation: `Source and destination locations cannot be identical`.
  - Step 2 fails with invariant violation: `Transactions can only be posted to active leaf locations`.
  - Step 3 fails with invariant violation: `Consumption movement cannot have a destination location`.
  - Step 4 fails with invariant violation: `Scrap disposal must originate strictly from DAMAGE_QUARANTINE`.
  - Step 5 fails with invariant violation: `Quarantine movement destination must be DAMAGE_QUARANTINE`.

---

### Acceptance Scenario 17: Stock Movement Reference Integrity & Single-Direction Adjustment FK
- **Requirement:** Every movement type satisfies `chk_stock_movement_reference_integrity`. Standalone transfers are backed by `movement_reason`. Circular dependency between adjustments and transactions is broken.
- **Test Steps:**
  1. Post a standalone location transfer with `movementReason = 'Rebalancing racks'`.
  2. Attempt a standalone location transfer with `movementReason = NULL`.
  3. Post cycle count adjustment via `POST /api/v1/stock/adjustments`. Inspect `stock_adjustments` and linked `stock_transactions`.
- **Expected Results:**
  - Step 1 succeeds.
  - Step 2 fails check constraint `chk_stock_movement_reference_integrity`.
  - Step 3 creates `stock_adjustments` row first, followed by ledger row with `stock_adjustment_id` pointing to it. `stock_adjustments.stock_transaction_id` column does not exist. Single-direction FK committed without deadlocks.

---

### Acceptance Scenario 18: Shift-Aware Closing & Composite Plan Foreign Key Alignment
- **Requirement:** `daily_closings` enforces composite foreign key referencing `(daily_plan_id, shift_code)` on `daily_plans`.
- **Test Steps:**
  1. Create Daily Plan for `date = 2026-10-15` and `shift_code = 'SHIFT_1'`.
  2. Attempt to insert row into `daily_closings` referencing the plan ID but specifying `shift_code = 'SHIFT_2'`.
  3. Submit closing with matching `shift_code = 'SHIFT_1'`.
- **Expected Results:**
  - Step 2 fails with PostgreSQL foreign key violation: `insert on table daily_closings violates foreign key constraint (daily_plan_id, shift_code)`.
  - Step 3 succeeds, guaranteeing 100% shift alignment.

---

### Acceptance Scenario 19: Source-Less Custom Job Creation and Release
- **Requirement:** A custom job must be releasable without a fake master BOM, but never without a complete immutable snapshot.
- **Test Steps:**
  1. Create a daily-plan job containing no `masterBomId`, a positive planned quantity, and two complete `customBomLines`.
  2. Release the plan.
  3. Attempt a second custom job with no custom lines, then one with a zero quantity or duplicate material line.
- **Expected Results:**
  - The released job has `packing_jobs.master_bom_id IS NULL`; its snapshot has `is_customized = true`, `source_bom_id IS NULL`, and `bom_version IS NULL` with two immutable valid lines and reservations based on frozen canonical quantities.
  - No `boms` row is created.
  - Each incomplete custom case is rejected before release; no released status, snapshot, reservation, or ledger effect is produced.

---

### Acceptance Scenario 20: Administrator Access Changes Through Actual JWT Identity
- **Requirement:** Only an existing active administrator may change another user's `role` or `is_active`; direct writes and self-reactivation are not an alternate path.
- **Test Steps:**
  1. Call `POST /api/v1/admin/users/{targetId}/access` as an active ADMIN with a valid JWT, role/status values, and a reason.
  2. Repeat as a normal user, as a caller with no profile, and as an inactive caller.
  3. Attempt direct PostgREST/SQL-style update of another profile and an arbitrary `actorId` request field.
  4. Deactivate a user through the administrator path, then have that user attempt self-reactivation through `/profiles/me` or direct update.
- **Expected Results:**
  - Step 1 succeeds only through `admin_update_profile_access`; audit has the JWT-derived administrator as actor.
  - Step 2 and Step 3 fail with authorization/validation errors; no target row changes. The API schema contains no actor ID field.
  - Step 4 leaves the user inactive; all self-reactivation attempts fail closed with SQLSTATE 42501 or HTTP 403/400 as applicable.

---

### Acceptance Scenario 21: Exhaustive Movement References and Location Transition Guards
- **Requirement:** Each of the nine movement types accepts only its documented reference set and active leaf location flow; invalid topology changes are rejected.
- **Test Steps:**
  1. Post one valid row for each movement type using the matrix in `SYSTEM_DESIGN.md`; for consumption use a completion tied to the same job and worker.
  2. For every type, add one prohibited unrelated FK (for example a GRN on `LOCATION_TRANSFER`, a job on `PURCHASE_RECEIPT`, or a completion on `RETURN_FROM_WORKER`) and attempt posting.
  3. Attempt inactive/parent endpoint posting, a same-location transfer, a worker-custody issue/return with mismatched worker location, a receipt destination mismatch, and an adjustment sign/location mismatch.
  4. Attempt to deactivate a balanced or historically used location, make such a leaf a parent, or reclassify its type.
- **Expected Results:**
  - Valid rows succeed with the documented business origin, source/destination direction, and synchronized projection balances.
  - Every unrelated reference and invalid cross-table/location combination is rejected by the check or database posting validation before a ledger insert.
  - All prohibited topology changes are rejected. The ledger and `material_location_balances` remain unchanged after each rejected request.

---

### Acceptance Scenario 22: Canonical Unit Lock and Conversion Provenance Reconstruction
- **Requirement:** A canonical unit cannot silently reinterpret inventory history; conversion-dependent history remains reproducible.
- **Test Steps:**
  1. Post a receipt and release a BOM snapshot for a material using a versioned conversion rule, then create an active reservation.
  2. Attempt to change that material's `canonical_unit_id` from KG to PCS.
  3. Supersede the conversion rule and inspect the posted receipt, ledger row, reservation, and snapshot.
  4. Create a replacement PCS material variant and verify the original variant remains historically queryable.
- **Expected Results:**
  - Step 2 fails at the database guard because transactions/reservations/released snapshots exist; balances and historical quantities are unchanged.
  - Step 3 retains each frozen rule ID, source/canonical units, factor, direction, exact/estimated classification, original measured quantity, and canonical quantity; reports do not recalculate with the newer rule.
  - Step 4 creates no reinterpretation or mutation of the original ledger/projection/snapshot history.

---

### Acceptance Scenario 23: Matching Owner, Scope & Canonical Hash Idempotency Replay (Requirement 1)
- **Requirement:** Matching owner identity, normalized operation scope, and canonical request payload hash returns the original cached response before expiration without duplicate ledger rows.
- **Setup:** Authenticate User A (JWT derived from `auth.uid()`). Send a valid mutating stock command (`POST /api/v1/stock/transfer`) with bounded key `K` (`TRANSFER-20261015-001`), server-normalized scope `POST:/api/v1/stock/transfer`, and canonical payload `P`. Wait for successful 200 OK commit. Before cache expiry (`NOW() < expires_at`), submit an identical retry as User A with key `K`, scope `POST:/api/v1/stock/transfer`, and payload `P`.
- **Expected HTTP Result:** Initial request returns HTTP 200 with operation payload. Retry returns identical HTTP 200 with the original cached response body without re-executing logic.
- **Database Invariants:** Exactly one `idempotency_keys` header row (`status = 'COMPLETED'`) and one `idempotency_responses` record. Exactly one pair of source/destination `stock_transactions` rows and synchronized `material_location_balances`. The retry executes zero additional inserts, updates, or ledger rows.

---

### Acceptance Scenario 24: Cross-User Idempotency Key Replay Denial (Requirement 2)
- **Requirement:** Another user cannot retrieve or replay an existing idempotency key, preventing cross-tenant information disclosure.
- **Setup:** Authenticate User A and execute valid stock command with key `K` and payload `P`. Authenticate User B (different `auth.uid()`) and attempt to execute a request with key `K`, regardless of whether scope and payload match.
- **Expected HTTP Result:** User B receives generic HTTP 409 `IDEMPOTENCY_KEY_REUSED` (`{"error": {"code": "IDEMPOTENCY_KEY_REUSED", "message": "The provided Idempotency-Key has already been used for a different request."}}`). User A's cached body, owner ID, endpoint, and payload are strictly redacted and undisclosed.
- **Database Invariants:** No operation or ledger row is created for User B. User A's `idempotency_keys` and `idempotency_responses` records remain unmodified. Zero cross-tenant data leakage.

---

### Acceptance Scenario 25: Cross-Endpoint & Modified Payload Idempotency Rejection (Requirement 3)
- **Requirement:** Reusing the same idempotency key with a different endpoint or modified payload is rejected without disclosing original cached data.
- **Setup:**
  - Case A (Cross-Endpoint): User A completes key `K` at `POST:/api/v1/goods-receipts/post`. User A then submits key `K` to `POST:/api/v1/stock/transfer` with any payload.
  - Case B (Modified Payload): User A completes key `K` at `POST:/api/v1/stock/transfer` with payload `P1` (quantity 50). User A then re-submits key `K` to `POST:/api/v1/stock/transfer` with payload `P2` (quantity 60, altered date, or altered material line).
- **Expected HTTP Result:** Both Case A and Case B return generic HTTP 409 `IDEMPOTENCY_KEY_REUSED`. Original cached responses are not returned.
- **Database Invariants:** Existing completed records and stock transactions from the initial request remain unchanged. Case A creates no transfer ledger row. Case B creates no updated quantity or second ledger row.

---

### Acceptance Scenario 26: Ephemeral Response Cache Pruning Preserves Header and Stock References (Requirement 4)
- **Requirement:** Expiring and pruning response data does not delete the request identity header or violate historical stock transaction foreign keys.
- **Setup:** Authenticate User A and post a goods receipt via `POST /api/v1/goods-receipts/post` with key `K`. The operation creates `goods_receipts`, three `stock_transactions` lines referencing `idempotency_keys(idempotency_key)` via `ON DELETE RESTRICT`, an `idempotency_keys` header, and an `idempotency_responses` row with `expires_at = NOW() - INTERVAL '1 minute'`. Trigger the background pruning job (`DELETE FROM idempotency_responses WHERE expires_at < NOW()`).
- **Expected HTTP Result:** Background maintenance job executes successfully and reports expired rows removed.
- **Database Invariants:** The expired row in `idempotency_responses` is deleted. The permanent header in `idempotency_keys` remains intact. All three `stock_transactions` referencing `K` remain valid and intact. Foreign key constraint `ON DELETE RESTRICT` is not violated (`SQLSTATE 23503` is avoided). Audit trail and historical stock links are fully preserved.

---

### Acceptance Scenario 27: Retrying Expired Idempotency Key Yields HTTP 410 Without Re-Execution (Requirement 5)
- **Requirement:** Retrying an operation after response-cache expiry must never execute the operation a second time and must return a safe, documented HTTP 410 status.
- **Setup:** Following Scenario 26 where `idempotency_responses` was pruned after expiry, User A submits a retry with the exact same key `K`, matching scope `POST:/api/v1/goods-receipts/post`, and matching canonical payload hash.
- **Expected HTTP Result:** Server returns **HTTP 410 Gone** with error code `IDEMPOTENCY_RESPONSE_EXPIRED` and structured resource reference:
  `{"success": false, "error": {"code": "IDEMPOTENCY_RESPONSE_EXPIRED", "message": "The cached response for this idempotency key has expired and been pruned.", "resourceReference": {"resourceType": "GOODS_RECEIPT", "resourceId": "<uuid>", "operationCompletedAt": "<timestamp>"}}}`.
- **Database Invariants:** The operation is NEVER re-executed. Zero new `goods_receipts` or `stock_transactions` rows are inserted. Ledger balances and projections remain strictly unchanged.

---

### Acceptance Scenario 28: Authorized Operation-Status Retrieval After Response Cache Expiration (Requirement 6)
- **Requirement:** After response cache expiration, clients can verify operation outcome strictly through authorized, role-governed resource endpoints using the reference provided in the HTTP 410 response.
- **Setup:** Following Scenario 27 where User A received HTTP 410 with `resourceType: "GOODS_RECEIPT"` and `resourceId: "<uuid>"`, User A (holding `STOREKEEPER` role) executes `GET /api/v1/goods-receipts/{resourceId}`. User C (an unauthorized `OPERATOR` without GRN read permissions) also attempts `GET /api/v1/goods-receipts/{resourceId}`.
- **Expected HTTP Result:** User A receives HTTP 200 with the full, authoritative posted goods receipt, line items, and ledger transaction references. User C receives HTTP 403 Forbidden.
- **Database Invariants:** Post-expiration status verification is mediated entirely through standard, role-authorized business resource endpoints. No unauthenticated or unauthorized client can inspect business records through idempotency mechanisms.

---

### Acceptance Scenario 29: Direct PostgREST Access to Headers and Cached Responses Denied (Requirement 7)
- **Requirement:** Direct PostgREST access to idempotency headers and cached responses is strictly denied to prevent enumeration, tampering, or unauthorized inspection.
- **Setup:** Authenticate User A and complete a transaction with key `K`. Authenticate User B (or an anonymous client) and attempt direct PostgREST calls:
  - `GET /rest/v1/idempotency_keys`
  - `POST /rest/v1/idempotency_keys`
  - `GET /rest/v1/idempotency_responses`
  - `DELETE /rest/v1/idempotency_responses`
- **Expected HTTP Result:** PostgREST returns HTTP 200 with empty array `[]` (for RLS filter denial `USING (false)`) or HTTP 403/401 Forbidden/Unauthorized. Insertion or deletion attempts fail closed with SQLSTATE `42501` (permission denied) or RLS policy violation.
- **Database Invariants:** Zero rows can be read, enumerated, inserted, modified, or deleted via PostgREST. Idempotency tables are accessible exclusively via internal database procedures (`SECURITY DEFINER` with verified `auth.uid()`).

---

### Acceptance Scenario 30: Concurrent Duplicate Request Serialization (Requirement 8)
- **Requirement:** Concurrent duplicate requests with the same key create at most one logical stock operation without race conditions or double postings.
- **Setup:** Two concurrent requests from User A with the exact same key `K`, scope `POST:/api/v1/stock/transfer`, and canonical payload `P` arrive at the server within 2ms of each other.
- **Expected HTTP Result:** The first request to acquire the database row lock processes and returns HTTP 200 with newly generated transfer details. The second concurrent request is blocked at the transaction lock, detects `status = 'COMPLETED'` upon lock acquisition, and returns identical HTTP 200 with cached body.
- **Database Invariants:** Exactly one `idempotency_keys` record, one `idempotency_responses` record, and exactly one pair of transfer ledger entries. Zero duplicate stock debits or credits.

---

### Acceptance Scenario 31: Multi-Line Goods Receipt Atomic Commit and Key Association (Requirement 9)
- **Requirement:** A multi-line stock request commits all movements, ledger rows, and cache data atomically under a single idempotency key.
- **Setup:** User A posts a 5-line Goods Receipt via `POST /api/v1/goods-receipts/post` with key `K` and canonical payload `P`.
- **Expected HTTP Result:** HTTP 200 with posted GRN response body.
- **Database Invariants:** All of the following commit atomically in a single PostgreSQL transaction:
  - One `goods_receipts` header (`status = 'POSTED'`).
  - Five `goods_receipt_lines`.
  - Five `stock_transactions` rows, each with `idempotency_key = K` and sequential `transaction_sequence = 1, 2, 3, 4, 5`.
  - Five synchronized `material_location_balances` incremented.
  - One `idempotency_keys` record with `resource_type = 'GOODS_RECEIPT'`, `resource_id = goods_receipts.id`, `status = 'COMPLETED'`.
  - One `idempotency_responses` record with response JSON and `expires_at = NOW() + INTERVAL '24 hours'`.

---

### Acceptance Scenario 32: Transaction Failure Rolls Back Stock and Leaves No Cached Success State (Requirement 10)
- **Requirement:** Failed transactions leave no partial stock movements, balance changes, or cached success records, enabling safe retries.
- **Setup:** User A posts a 3-line stock transfer with key `K`. Line 1 and 2 succeed, but Line 3 triggers a check constraint violation (e.g. Insufficient Available Stock, `CHECK (on_hand_quantity >= 0)`).
- **Expected HTTP Result:** HTTP 422 Unprocessable Entity with error code `INSUFFICIENT_STOCK`.
- **Database Invariants:** PostgreSQL transaction rolls back entirely. No partial ledger rows exist for Line 1 or Line 2. No `idempotency_keys` or `idempotency_responses` record exists with `status = 'COMPLETED'`. Key `K` is completely free to be retried after stock replenishment without conflict.

---

### Acceptance Scenario 33: Client Network Timeout After Successful Commit Replay
- **Requirement:** If a client experiences a network timeout after the database transaction has committed, retrying with the original key returns the cached response without re-executing.
- **Setup:** User A submits a valid material issue with key `K`. The server commits the transaction and inserts response cache, but network drops before client receives the TCP response. User A's client library automatically retries with identical key `K`, scope, and payload.
- **Expected HTTP Result:** Retry receives HTTP 200 with original cached response body.
- **Database Invariants:** Zero duplicate material issuance transactions or duplicate stock deductions. Balance projection reflects exactly one issuance.

---

### Acceptance Scenario 34: Bounded Key Format & Schema Validation Guard
- **Requirement:** Client-supplied idempotency keys must conform strictly to bounded length and character constraints before database processing.
- **Setup:** Clients submit mutating requests with invalid `Idempotency-Key` headers:
  - Case A: Empty string `""`
  - Case B: Short string `"short"` (< 16 characters)
  - Case C: Oversized string (> 128 characters)
  - Case D: Disallowed characters (e.g., spaces or control characters)
- **Expected HTTP Result:** HTTP 400 Bad Request with error code `INVALID_IDEMPOTENCY_KEY`.
- **Database Invariants:** Request is rejected at the API middleware boundary before database connection or transaction initiation. Zero database rows inspected or touched.

---

### Acceptance Scenario 35: Route Registry Alignment & Mandatory Flask Idempotency Verification
- **Requirement:** 100% of state-changing Flask POST commands require an `Idempotency-Key` header matching `^[A-Za-z0-9_\-\.:]{16,128}$`; missing or invalid headers are rejected with HTTP 400. Direct PostgREST master CRUD does not accept Flask idempotency headers (`N/A`) and prevents duplicate writes via database primary keys and unique constraints.
- **Setup:**
  - Case A: Client submits `POST /api/v1/stock/transfer` without an `Idempotency-Key` header.
  - Case B: Client submits `POST /api/v1/boms` or `POST /api/v1/purchase-orders` without an `Idempotency-Key` header.
  - Case C: Client submits direct PostgREST insert to `POST /rest/v1/material_categories` or `POST /rest/v1/materials`.
- **Expected HTTP Result:** Case A and Case B are rejected immediately with HTTP 400 `MISSING_IDEMPOTENCY_KEY`. Case C succeeds via PostgREST if authorized by RLS, and duplicate insert is rejected with HTTP 409 / PostgreSQL unique constraint violation.
- **Database Invariants:** Zero partial or un-idempotent domain mutations occur in Flask endpoints.

---

### Acceptance Scenario 36: Post-410 Authorized Resource Lookup Verification (Complete 10-Route Map)
- **Requirement:** Every `resource_type` returned in an HTTP 410 response maps to an authorized detail GET endpoint in Flask API, enabling deterministic client state recovery. All 10 enum values must have a corresponding route (updated from 8 in Phase 1.8 to 10 in Phase 1.9).
- **Setup:** Test each of the 10 resource types:
  1. `GOODS_RECEIPT` -> `GET /api/v1/goods-receipts/{id}` (`getGoodsReceipt`)
  2. `PRODUCTION_COMPLETION` -> `GET /api/v1/production/completions/{id}` (`getProductionCompletion`)
  3. `STOCK_TRANSACTION` -> `GET /api/v1/stock/transactions/{id}` (`getStockTransaction`)
  4. `STOCK_ADJUSTMENT` -> `GET /api/v1/stock/adjustments/{id}` (`getStockAdjustment`) **[Added Phase 1.9]**
  5. `PURCHASE_ORDER` -> `GET /api/v1/purchase-orders/{id}` (`getPurchaseOrder`)
  6. `BOM` -> `GET /api/v1/boms/{id}` (`getBom`)
  7. `DAILY_PLAN` -> `GET /api/v1/daily-plans/{id}` (`getDailyPlan`)
  8. `PACKING_JOB` -> `GET /api/v1/packing-jobs/{id}` (`getPackingJob`)
  9. `DAILY_CLOSING` -> `GET /api/v1/closings/{id}` (`getDailyClosing`)
  10. `PROFILE` -> `GET /api/v1/admin/users/{targetId}` (`getUserProfile`) **[Added Phase 1.9]**
- **Expected HTTP Result:** When requested by an authorized user role, each GET returns HTTP 200 with the full entity representation matching the schema. If unauthorized, returns HTTP 403 Forbidden. If ID not found, returns HTTP 404 Not Found.
- **Database Invariants:** Entity details are read strictly without side effects or mutations.

---

### Acceptance Scenario 37: OpenAPI SupabaseJWT Security Policy Validation
- **Objective:** Verify that the OpenAPI contract machine-readably enforces the JWT Bearer authentication policy on all Flask endpoints.
- **Test Matrix:**
  - Case A: `GET /api/v1/health` — `security: []` override present; request without `Authorization` header returns HTTP 200.
  - Case B: `GET /api/v1/stock/balances` without `Authorization` header — returns HTTP 401 (`UNAUTHORIZED`) via `UnauthorizedResponse` envelope.
  - Case C: `POST /api/v1/boms` with valid JWT but OPERATOR role — returns HTTP 403 (`FORBIDDEN`) via `ForbiddenResponse` envelope.
  - Case D: `POST /api/v1/goods-receipts/post` with expired JWT — returns HTTP 401 (`UNAUTHORIZED`).
  - Case E: All 32 non-health operations inherit global `security: [{SupabaseJWT: []}]` policy (verified in `API_CONTRACT.yaml` parse).
- **Pass Invariant:** No Flask endpoint (other than `GET /health`) serves a response other than 401 to a request missing or carrying an invalid `Authorization: Bearer <token>` header.

---

### Acceptance Scenario 38: OperationId Uniqueness and Completeness Verification
- **Objective:** Verify that all 33 Flask operations carry a unique, non-null `operationId` enabling automated SDK generation and contract-driven testing.
- **Test Matrix:**
  - Case A: Parse `API_CONTRACT.yaml` using a YAML parser; enumerate all `operationId` values across all paths and HTTP methods.
  - Case B: Assert count of `operationId` values equals 33 (20 POST commands + 13 GET queries/lookups).
  - Case C: Assert zero duplicate `operationId` values exist.
  - Case D: Assert all 20 POST command operationIds match the authoritative list in ADR-030 §2.
  - Case E: Assert all 13 GET query operationIds match the authoritative list in ADR-030 §2.
- **Pass Invariant:** `len(operationIds) == 33` and `len(set(operationIds)) == 33`.

---

### Acceptance Scenario 39: Complete POST Success Schema Coverage
- **Objective:** Verify that every one of the 20 state-changing POST commands defines a structured success response schema (no bare `description`-only 2xx responses).
- **Test Matrix:**
  - Case A: Parse `API_CONTRACT.yaml`; for every `post` operation, assert the primary success status code (`200` or `201`) has a `content.application/json.schema` key referencing a component or inline schema.
  - Case B: `POST /stock/issue-to-worker` returns `StockMovementResponse`.
  - Case C: `POST /stock/adjustments` returns `StockAdjustmentDetailResponse`.
  - Case D: `POST /admin/users/{targetId}/access` returns `ProfileAccessUpdateResponse` containing a `ProfileResponse`.
  - Case E: All other POST operations return previously defined response schemas (`PurchaseOrderResponse`, `BomDetailResponse`, `PostGoodsReceiptResponse`, `DailyPlanDetailResponse`, `PackingJobDetailResponse`, `ProductionCompletionDetailResponse`, `DailyClosingDetailResponse`).
- **Pass Invariant:** Zero POST operations with a bare `description`-only 2xx response body. All 20 success schemas resolve to a named or inline schema definition.

---

### Acceptance Scenario 40: Idempotency Expired Response camelCase Contract Verification & Identifier Alignment
- **Objective:** Verify that the OpenAPI contract machine-readably enforces camelCase field naming for HTTP 410 expired responses (`resourceReference`, `resourceType`, `resourceId`, `operationCompletedAt`), eliminates non-existent surrogate `idempotencyKeyId: UUID` properties from success response schemas (`StockMovementResponse`, `StockAdjustmentDetailResponse`), and guarantees 100% enum compatibility with database check constraint `chk_idempotency_keys_resource_type`.
- **Test Matrix:**
  - Case A: Parse `API_CONTRACT.yaml`; assert `IdempotencyExpiredError.properties.error.properties` contains `resourceReference` (not snake_case `resource_reference`).
  - Case B: Assert `resourceReference.properties` contains exactly `resourceType`, `resourceId`, and `operationCompletedAt` (all camelCase, zero snake_case properties).
  - Case C: Assert `resourceReference.properties.resourceType.enum` contains exactly 10 enum values (`GOODS_RECEIPT`, `PRODUCTION_COMPLETION`, `STOCK_TRANSACTION`, `STOCK_ADJUSTMENT`, `PURCHASE_ORDER`, `DAILY_PLAN`, `PACKING_JOB`, `DAILY_CLOSING`, `BOM`, `PROFILE`), matching Table 31 check constraint `chk_idempotency_keys_resource_type`.
  - Case D: Assert neither `StockMovementResponse` nor `StockAdjustmentDetailResponse` defines an `idempotencyKeyId` property in `properties` or `required`.
  - Case E: Assert exactly 32 operations inherit the global `SupabaseJWT` security policy while `GET /health` defines `security: []`.
- **Pass Invariant:** `all(k in ['resourceType', 'resourceId', 'operationCompletedAt'] for k in resRefProps)` and `'idempotencyKeyId' not in stockMoveProps` and `'idempotencyKeyId' not in stockAdjProps` and `len(resourceTypes) == 10` and `len(protectedOps) == 32`.
