# Architectural Decision Records (ADRs)

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## Index of Architectural Decisions

- [ADR-001: Hybrid Data Access Architecture (Supabase Instant REST vs Flask REST API)](#adr-001-hybrid-data-access-architecture-supabase-instant-rest-vs-flask-rest-api)
- [ADR-002: Authoritative Append-Only Stock Transaction Ledger with Atomic Projections](#adr-002-authoritative-append-only-stock-transaction-ledger-with-atomic-projections)
- [ADR-003: Worker Material Custody as Internal Location Transfer rather than Premature Consumption](#adr-003-worker-material-custody-as-internal-location-transfer-rather-than-premature-consumption)
- [ADR-004: Immutable Packing Job BOM Snapshots for Historical Production Stability](#adr-004-immutable-packing-job-bom-snapshots-for-historical-production-stability)
- [ADR-005: Dual-Unit Dimension Tracking with Explicit Provenance (Measured vs Estimated Conversions)](#adr-005-dual-unit-dimension-tracking-with-explicit-provenance-measured-vs-estimated-conversions)
- [ADR-006: Atomic Database-Level Invariant Enforcement via Stored Procedures and Advisory Locks](#adr-006-atomic-database-level-invariant-enforcement-via-stored-procedures-and-advisory-locks)
- [ADR-007: Supabase JWT Verification and RBAC in Python Flask Application Server](#adr-007-supabase-jwt-verification-and-rbac-in-python-flask-application-server)
- [ADR-008: Selection of Vitest and React Testing Library for Frontend Verification](#adr-008-selection-of-vitest-and-react-testing-library-for-frontend-verification)
- [ADR-009: Data-Driven Material Categories Table and Extensible Specifications Model](#adr-009-data-driven-material-categories-table-and-extensible-specifications-model)
- [ADR-010: Explicit Signed Ledger Aggregation and Fast-Read Balance Projection](#adr-010-explicit-signed-ledger-aggregation-and-fast-read-balance-projection)
- [ADR-011: Clear Segregation between Damage Quarantine and Permanent Disposal](#adr-011-clear-segregation-between-damage-quarantine-and-permanent-disposal)
- [ADR-012: Hardened Database Security-Definer Helper and Profile Column Protection](#adr-012-hardened-database-security-definer-helper-and-profile-column-protection)
- [ADR-013: Strict Foreign Key Referential Actions and Anti-Cascade Protection for Historical Records](#adr-013-strict-foreign-key-referential-actions-and-anti-cascade-protection-for-historical-records)
- [ADR-014: Full Conversion Provenance Tracking on Stock Transactions and Frozen Snapshots](#adr-014-full-conversion-provenance-tracking-on-stock-transactions-and-frozen-snapshots)
- [ADR-015: Shift-Aware Daily Closing Cardinality and NULLS NOT DISTINCT Uniqueness](#adr-015-shift-aware-daily-closing-cardinality-and-nulls-not-distinct-uniqueness)
- [ADR-016: Explicit Packing Job Quantity Accounting and Cumulative Invariant Model](#adr-016-explicit-packing-job-quantity-accounting-and-cumulative-invariant-model)
- [ADR-017: Comprehensive Location Inventory Accounting across All Facility Node Types](#adr-017-comprehensive-location-inventory-accounting-across-all-facility-node-types)
- [ADR-018: Database-Backed Transactional Idempotency and Strongly-Typed Audit References](#adr-018-database-backed-transactional-idempotency-and-strongly-typed-audit-references)
- [ADR-019: Source-Optional Packing Jobs with Release-Gated Immutable Snapshots](#adr-019-source-optional-packing-jobs-with-release-gated-immutable-snapshots)
- [ADR-020: Complete Stock-Movement Reference and Location Validation](#adr-020-complete-stock-movement-reference-and-location-validation)
- [ADR-021: Actual-Administrator JWT Role-Update RPC](#adr-021-actual-administrator-jwt-role-update-rpc)
- [ADR-022: OpenAPI 3.0.3 Contract Baseline and Safe Quantity Revision](#adr-022-openapi-303-contract-baseline-and-safe-quantity-revision)
- [ADR-023: Trusted Goods Receipt Calculation and Response Model](#adr-023-trusted-goods-receipt-calculation-and-response-model)
- [ADR-024: Canonical Unit Immutability after Inventory Activity](#adr-024-canonical-unit-immutability-after-inventory-activity)
- [ADR-025: Immutable Conversion Provenance](#adr-025-immutable-conversion-provenance)
- [ADR-026: Leaf-Only Authoritative Location Accounting](#adr-026-leaf-only-authoritative-location-accounting)
- [ADR-027: Owner-Bound Idempotency Replay and Rollback-Removes-Key Semantics](#adr-027-owner-bound-idempotency-replay-and-rollback-removes-key-semantics)
- [ADR-028: Two-Tier Idempotency Architecture with Ephemeral Response Cache, Foreign Key Preservation, and HTTP 410 Expiration Semantics](#adr-028-two-tier-idempotency-architecture-with-ephemeral-response-cache-foreign-key-preservation-and-http-410-expiration-semantics)
- [ADR-029: Authoritative Route Registry, 100% Mandatory Flask Idempotency, and Expired-Response Recovery Contract](#adr-029-authoritative-route-registry-100-mandatory-flask-idempotency-and-expired-response-recovery-contract)
- [ADR-030: OpenAPI SupabaseJWT Security Scheme, Complete OperationIds, and Explicit Success Schemas](#adr-030-openapi-supabasejwt-security-scheme-complete-operationids-and-explicit-success-schemas)
- [ADR-031: Idempotency Identifier Alignment, camelCase Error References, and Protected Operation Accounting](#adr-031-idempotency-identifier-alignment-camelcase-error-references-and-protected-operation-accounting)

---

### ADR-001: Hybrid Data Access Architecture (Supabase Instant REST vs Flask REST API)

#### Status
Accepted

#### Context
The system requires both high-productivity CRUD access for master catalog management and strict transactional guarantees for inventory, stock ledger, BOM snapshots, quantity revisions, and daily closings. Exposing all operations directly to the frontend via Supabase Instant REST API risks business invariant violations (e.g., client-side balance checks subject to race conditions and negative inventory). Conversely, routing simple read-only queries (e.g., product lists, location pickers) through a custom Flask backend introduces unnecessary boilerplate, latency, and maintenance overhead.

#### Decision
We adopt a **strict command-query and security separation**:
1. **Supabase Instant REST API (PostgREST)**: Used exclusively by the React frontend for read-only queries, filterable lists, reference dropdowns, and permitted low-risk master data CRUD (e.g., updating non-critical party contact info). All client access is gated by PostgreSQL Row Level Security (RLS) using the authenticated user's JWT.
2. **Flask Application Server (`/api/v1`)**: Handles all critical transactional workflows, including:
   - Goods receipt posting.
   - Worker material issues, returns, damage quarantine, scrap disposal, transfers, and inventory adjustments.
   - BOM versioning and releasing packing jobs with frozen snapshots.
   - Job quantity revisions (e.g., 520 to 450) and multi-entity cancellations.
   - Production completion and actual consumption reconciliation.
   - Daily closing calculations and status lockdowns.
3. **Database Guardrails**: Stock-affecting tables (`stock_transactions`, `material_location_balances`, `stock_reservations`, `packing_job_bom_snapshots`, `daily_closings`, `audit_logs`) have RLS policies set to **deny direct client INSERT/UPDATE/DELETE**. Only service-role or elevated database functions executed within Flask orchestrations can mutate these tables.

---

### ADR-002: Authoritative Append-Only Stock Transaction Ledger with Atomic Projections

#### Status
Accepted

#### Context
Traditional ERP systems frequently maintain a mutable `quantity_on_hand` column on the item record. Concurrent updates, partial rollbacks, or manual edits cause stock drift, where physical quantities do not match ledger records.

#### Decision
All stock changes are modeled as **immutable, append-only entries in `stock_transactions`**.
- An authoritative transaction row records positive magnitude with source and destination locations.
- Current physical stock by location is calculated using **explicit signed aggregation**:
  $$\text{Balance}(M, L) = \sum_{\text{dest}=L} \text{quantity} - \sum_{\text{src}=L} \text{quantity}$$
- For instant $O(1)$ read performance and atomic negative-stock prevention, a projection table `material_location_balances` is maintained atomically in the same database transaction via PostgreSQL row locks and check constraints (`CHECK (on_hand_quantity >= 0)`).
- No user, API route, or admin interface is permitted to execute `UPDATE stock_transactions` or `DELETE FROM stock_transactions`. Corrections must be executed as explicit `STOCK_ADJUSTMENT` transactions with documented business reasons and user attribution.

---

### ADR-003: Worker Material Custody as Internal Location Transfer rather than Premature Consumption

#### Status
Accepted

#### Context
In packing shop floors, cartons, poly bags, and screws are handed over to operators at the start of a shift. Some systems treat this issue as immediate consumption. However, workers may pack fewer units than planned, damage materials, or return unused items at the end of the shift. Treating issue as consumption leads to fictitious inventory depletion and distorts cost accounting.

#### Decision
Issuing materials to a worker is classified as an **internal custody transfer** (`ISSUE_TO_WORKER`):
- Source: Store Location (e.g., Main Store Shelf A-1).
- Destination: Worker Custody Location (a specialized virtual location associated with the worker profile, e.g., `LOC_WORKER_<UUID>`).
- Physical company stock remains unchanged: `Store Stock` decreases, `Worker Custody` increases by identical magnitude.
- Stock consumption (`CONSUMPTION`) is only recorded when finished goods are confirmed packed (`production_completions`) or when scrap/damage is reported.
- Unused materials returned at shift close are posted as `RETURN_FROM_WORKER`, transferring stock from `Worker Custody` back to `Store Location`.

---

### ADR-004: Immutable Packing Job BOM Snapshots for Historical Production Stability

#### Status
Accepted

#### Context
A master Bill of Materials (BOM) changes over time (e.g., transitioning from 8mm screws to 10mm screws, or changing poly bag gauge). If active or historical packing jobs reference a live `boms` record by foreign key, editing the master BOM silently rewrites the material requirements and theoretical consumption of past or in-progress jobs.

#### Decision
When a packing job is transitioned from `DRAFT` to `RELEASED` / `IN_PROGRESS`, the system creates an **immutable snapshot**:
- Master BOM definitions in `boms` and `bom_lines` are versioned.
- A packing job points to an immutable record in `packing_job_bom_snapshots` and child `packing_job_bom_snapshot_lines`.
- Any subsequent edit to the master BOM increments the master BOM version number but **never affects existing snapshots**.
- Any custom job-level packing adjustments (e.g., adding an extra export corner protector for a specific client batch) are recorded in the job snapshot without modifying the master catalog.

---

### ADR-005: Dual-Unit Dimension Tracking with Explicit Provenance (Measured vs Estimated Conversions)

#### Status
Accepted

#### Context
Packing materials are purchased and stocked in varying units (e.g., poly bags purchased in KG, stocked in KG, but consumed per finished unit in PCS; cartons purchased in BOX of 50 PCS). Converting 25 KG of poly bags to PCS using an average weight (e.g., 10g per bag = 2,500 PCS) is an *estimate*, subject to manufacturing tolerance (+/- 5%). Treating estimates as exact counts leads to phantom shortages or false surpluses.

#### Decision
The system enforces:
1. **Canonical Stock Unit**: Each material variant has exactly one canonical stock unit (e.g., KG for poly film/bags, PCS for cartons and screws).
2. **Explicit Conversion Classification**:
   - `EXACT`: Mathematically fixed (e.g., 1 BOX = 100 PCS).
   - `ESTIMATED`: Weight-to-count calibration (e.g., 1 KG ≈ 100 PCS).
3. **Dual-Display UI & Data Integrity**:
   - The authoritative ledger only balances in the canonical stock unit.
   - Secondary units are labeled in UI with `≈` (e.g., `25.000 KG (≈ 2,500 PCS)`).
   - The system forbids adding or subtracting numbers across different units without an explicit conversion record.

---

### ADR-006: Atomic Database-Level Invariant Enforcement via Stored Procedures and Advisory Locks

#### Status
Accepted

#### Context
Concurrent operations (such as two storekeepers issuing the same screws from the same shelf to different workers simultaneously) can lead to race conditions where both read sufficient balance, both write deductions, and the shelf balance becomes negative.

#### Decision
All critical inventory operations are wrapped in **PostgreSQL transactions featuring row-level locks (`SELECT ... FOR UPDATE`) or PostgreSQL advisory locks** keyed on `(material_id, location_id)`.
- Implemented via PostgreSQL stored functions (e.g., `fn_post_stock_transaction`, `fn_release_packing_job`, `fn_complete_production_batch`).
- Flask calls these transactional procedures using database connections with application-level idempotency tokens (`idempotency_key` stored in `idempotency_keys` table and `stock_transactions`).
- Check constraints (`CHECK (quantity > 0)`) and balance checks guarantee no negative stock unless an authorized override flag is set.

---

### ADR-007: Supabase JWT Verification and RBAC in Python Flask Application Server

#### Status
Accepted

#### Context
The user authenticates with Supabase Auth on the frontend. The Flask API must securely authenticate requests without maintaining a separate session store or password database.

#### Decision
Flask implements a centralized authentication and RBAC decorator (`@require_auth`, `@require_role`):
1. React includes the Supabase Auth access token in the `Authorization: Bearer <JWT>` header on every Flask API request.
2. Flask validates the JWT signature using the Supabase JWT secret / public JWKS via `PyJWT`.
3. The user's identity is extracted strictly from `sub` (user UUID). Client-supplied headers or body fields claiming identity are rejected.
4. Flask queries `public.profiles` directly to verify `role` and `is_active == true`.
5. When executing database operations via service credentials, Flask explicitly sets local transaction context (`SET LOCAL app.current_user_id = '<user_uuid>';`) or passes caller parameters to stored functions for audit logging.

---

### ADR-008: Selection of Vitest and React Testing Library for Frontend Verification

#### Status
Accepted

#### Context
The repository currently lacks frontend scaffolding. The prompt requires evaluating the repository and recommending a suitable frontend testing framework.

#### Decision
We select **Vitest** paired with **React Testing Library** and **jsdom**:
1. **Vitest** provides native Vite configuration sharing, ESM support, and high execution speed without duplicate build pipelines.
2. **React Testing Library** encourages testing user behavior and accessibility over implementation details.
3. **MSW (Mock Service Worker)** will be utilized to mock both PostgREST and Flask `/api/v1` endpoints during frontend integration testing.

---

### ADR-009: Data-Driven Material Categories Table and Extensible Specifications Model

#### Status
Accepted

#### Context
The initial design utilized an inline PostgreSQL `CHECK (material_type IN ('CARTON', 'POLY_BAG', ...))` constraint. This violates the business requirement that administrators must be able to add new material categories dynamically without altering database schemas or modifying application source code.

#### Decision
1. We introduce a dedicated master entity: `material_categories` table:
   - Primary Key: `id` (UUID).
   - Columns: `category_code` (TEXT UNIQUE NOT NULL), `category_name` (TEXT NOT NULL), `description` (TEXT), `is_active` (BOOLEAN DEFAULT TRUE), `created_at`, `updated_at`.
2. The `materials` table references `material_categories(id)` via foreign key with `ON DELETE RESTRICT`.
3. The `materials` table retains common, strongly-typed physical dimensions (`thickness_gauge`, `width_mm`, `length_mm`, `height_mm`, `diameter_thread_spec`).
4. For domain-specific or novel material attributes, an extensible `additional_specs` (`jsonb`) column is added to `materials` with check constraints validating that it contains a JSON object.

---

### ADR-010: Explicit Signed Ledger Aggregation and Fast-Read Balance Projection

#### Status
Accepted

#### Context
A naïve `SUM(quantity)` grouped by material and location does not work for a ledger where each movement row contains positive magnitude along with both `source_location_id` and `destination_location_id`.

#### Decision
We establish a two-tiered, mathematically airtight inventory calculation architecture:
1. **Authoritative Ledger Formula (Historical Reconstruction):**
   $$\text{Balance}(M, L, T) = \sum_{\substack{\text{dest}=L \\ t \le T}} \text{quantity} - \sum_{\substack{\text{src}=L \\ t \le T}} \text{quantity}$$
2. **Atomic Projection Table (`material_location_balances`):**
   - Maintained atomically within the same stored procedure (`fn_post_stock_transaction`) that inserts into `stock_transactions`.
   - Protected by check constraint `CHECK (on_hand_quantity >= 0)`.

---

### ADR-011: Clear Segregation between Damage Quarantine and Permanent Disposal

#### Status
Accepted

#### Context
Prior documentation conflated moving damaged materials to a quarantine area with permanent scrap write-off. Moving defective goods to quarantine segregates them from usable stock, but they remain physical company property until formally disposed of.

#### Decision
We introduce two distinct operational movement types and explicit inventory classifications:
1. **`DAMAGE_QUARANTINE` Movement:**
   - Source: Usable Store Location or Worker Custody.
   - Destination: Damage Quarantine Location (`location_type = 'DAMAGE_QUARANTINE'`).
   - Effect: Usable store stock / worker custody decreases; quarantine stock increases. **Total physical company stock is unchanged.**
2. **`SCRAP_DISPOSAL` Movement:**
   - Source: Damage Quarantine Location.
   - Destination: External / NULL.
   - Effect: Quarantined stock decreases; **total physical company stock decreases permanently**.
3. **Inventory Classification Equations:**
   - $\text{Total Physical Stock} = \text{Usable Stock} + \text{Worker Custody} + \text{Quarantined Stock}$
   - $\text{Available-to-Promise (ATP)} = \text{Usable Stock} - \text{Reserved Stock}$

---

### ADR-012: Fail-Closed Profile Role Protection, Empty Search Path, and Privilege Isolation

#### Status
Accepted (Hardened with Fail-Closed Semantics in Phase 1.3)

#### Context
`public.get_current_user_role()` with `SET search_path = public` is vulnerable to search path hijacking if objects can be shadowed in public schemas. Furthermore, standard row-level `UPDATE` RLS policies check the target row, but cannot prevent users from modifying individual privileged columns (`role`, `is_active`) in their own profile row.
Critically, using standard comparison `IF public.get_current_user_role() != 'ADMIN'` creates a dangerous vulnerability due to SQL 3-valued NULL logic: if an unauthenticated, inactive, or unprofiled caller triggers the check, `public.get_current_user_role()` returns `NULL`. Since `NULL != 'ADMIN'` evaluates to `NULL` (unknown), PL/pgSQL treats it as FALSE and skips the exception, silently granting unauthorized updates!

#### Decision
1. **Hardened Role Function (Fail-Closed & Search Path Isolated):**
   ```sql
   CREATE OR REPLACE FUNCTION public.get_current_user_role()
   RETURNS text
   LANGUAGE sql
   STABLE
   SECURITY DEFINER
   SET search_path = ''
   AS $$
     SELECT role FROM public.profiles 
     WHERE id = auth.uid() AND is_active = true;
   $$;

   -- Lock down function privileges
   REVOKE ALL ON FUNCTION public.get_current_user_role() FROM PUBLIC, anon;
   GRANT EXECUTE ON FUNCTION public.get_current_user_role() TO authenticated;
   ```
2. **Column-Level Role Protection via Fail-Closed Trigger:**
   To guarantee that non-admin users cannot elevate their own role or reactivate an account, a `BEFORE UPDATE` trigger on `public.profiles` blocks any modification to `role` or `is_active` using `IS DISTINCT FROM 'ADMIN'`:
   ```sql
   CREATE OR REPLACE FUNCTION public.trg_protect_profile_role()
   RETURNS trigger
   LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = ''
   AS $$
   BEGIN
     IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active) THEN
       -- Fail-closed check: NULL role or non-ADMIN is immediately rejected
       IF public.get_current_user_role() IS DISTINCT FROM 'ADMIN' THEN
         RAISE EXCEPTION 'Unauthorized: Only active administrators can modify profile roles or active status.'
           USING ERRCODE = '42501';
       END IF;
     END IF;
     RETURN NEW;
   END;
   $$;

   -- Lock trigger function ownership and permissions
   ALTER FUNCTION public.trg_protect_profile_role() OWNER TO postgres;
   REVOKE ALL ON FUNCTION public.trg_protect_profile_role() FROM PUBLIC, anon, authenticated;
   ```
3. **Application Server Security Enforcement:**
   - Flask validates JWTs independently using cryptographic JWKS/secret verification. Client-submitted claims in headers or request bodies are ignored.
   - Profile self-update (`PATCH /api/v1/profiles/me`) explicitly prohibits modifying `role` or `is_active` at the schema validation layer.

---

### ADR-013: Strict Foreign Key Referential Actions and Anti-Cascade Protection for Historical Records

#### Status
Accepted

#### Context
Using `ON DELETE CASCADE` on operational headers risks catastrophic loss of production history, frozen BOM snapshots, and inventory audit logs if a user deletes a parent schedule.

#### Decision
We enforce a strict **Anti-Cascade Deletion Policy** across the entire database:
1. All foreign keys referencing production batches, released jobs, snapshots, posted goods receipts, and stock transactions utilize `ON DELETE RESTRICT`.
2. Master catalog entities enforce soft deactivation (`is_active = false`) instead of hard deletion.
3. Deletion of draft records is permitted only if zero child transactions or released records exist.

---

### ADR-014: Full Conversion Provenance, Backflush Transparency, and Unverified Variance Tracking

#### Status
Accepted (Updated in Phase 1.3)

#### Context
1. Flexible packaging materials are purchased in one unit (e.g., KG) and consumed in another (e.g., PCS). If a calibration factor is updated, historical transactions and released jobs could experience retroactive recalculation if the conversion was computed dynamically.
2. In automated production completion, automated BOM backflush computes theoretical consumption. Setting variance to zero during backflush falsely reports theoretical deductions as physically verified zero-variance counts.

#### Decision
1. **Authoritative Conversion Provenance:**
   Every row in `stock_transactions` explicitly stores `canonical_quantity`, `canonical_unit_id`, `entered_quantity`, `entered_unit_id`, `conversion_factor_applied`, `conversion_direction`, `is_estimated`, and `measurement_method`.
2. **Frozen Snapshot Line Provenance:**
   When a packing job is released, `packing_job_bom_snapshot_lines` freeze both the recipe requirement and the conversion factor.
3. **Backflush Transparency and Nullable Variance:**
   In `material_consumption_records`:
   - `theoretical_quantity` and `posted_ledger_quantity` are non-null.
   - `physically_confirmed_quantity` is `NULL` during automated backflush.
   - `variance_quantity` is `NULL` until physical count/scale audit occurs.
   - `variance_status` is set to `'UNVERIFIED'` during backflush; only updated to `'VERIFIED_ZERO'` or `'VARIANCE_RECORDED'` upon supervisor physical reconciliation.

---

### ADR-015: Single Active BOM Version Invariant and Composite Shift-Aware Closing Alignment

#### Status
Accepted (Updated in Phase 1.3)

#### Context
1. In PostgreSQL, standard unique constraints treat `NULL` as distinct, permitting duplicate generic BOMs where `party_id IS NULL`. Furthermore, standard uniqueness on `(product_id, party_id, packing_variant_name, version_number)` does not prevent multiple active versions from coexisting.
2. `daily_closings` referencing `daily_plans` must guarantee that shift codes remain perfectly aligned without storing independent contradictory shift values.

#### Decision
1. **Single Active BOM Version Invariant:**
   At most one active BOM version can exist for any recipe key `(product_id, party_id, packing_variant_name)`. Enforced via a PostgreSQL partial unique index:
   ```sql
   CREATE UNIQUE INDEX idx_boms_single_active_version 
   ON public.boms (product_id, party_id, packing_variant_name) 
   NULLS NOT DISTINCT 
   WHERE (status = 'ACTIVE');
   ```
2. **Atomic Version Release Transaction:**
   Promoting a new BOM version atomically locks the current active BOM, transitions it to `SUPERSEDED`, activates the new BOM, and logs a revision audit row in `bom_revision_events` within a single database transaction.
3. **Composite Shift Alignment on Daily Closings:**
   `daily_plans` defines `UNIQUE(id, shift_code)`. `daily_closings` enforces a composite foreign key:
   `FOREIGN KEY (daily_plan_id, shift_code) REFERENCES daily_plans(id, shift_code) ON DELETE RESTRICT`. Contradictory shift values between plan and closing are mathematically impossible.

---

### ADR-016: Explicit Five-Variable Quantity Accounting and Completely Customized Packing Snapshots

#### Status
Accepted (Updated in Phase 1.3)

#### Context
1. Job revisions (520 $\to$ 450) and partial cancellations must track original quota, revised quota, completed output, pending quantity, and cancelled volume without data loss.
2. Production frequently encounters custom or ad-hoc packing jobs that do not derive from any master catalog BOM. A non-null `source_bom_id` constraint prevents custom jobs.

#### Decision
1. **Five-Variable Quantity Model on `packing_jobs`:**
   $$\text{current\_revised\_quantity} = \text{completed\_quantity} + \text{pending\_quantity} + \text{cancelled\_quantity}$$
   Revisions log sequential records in `packing_job_revisions`; cancellations update `cancelled_quantity` and preserve completed volume.
2. **Support for Completely Customized BOM Snapshots:**
   In `packing_job_bom_snapshots`:
   - `source_bom_id` is nullable.
   - Enforced by check constraint:
     ```sql
     CHECK (
       (is_customized = false AND source_bom_id IS NOT NULL AND bom_version IS NOT NULL) OR
       (is_customized = true)
     )
     ```
   - Invariant: A released packing job MUST have an immutable snapshot header and at least one line in `packing_job_bom_snapshot_lines`, whether master-derived or completely custom.

---

### ADR-017: Comprehensive Leaf-Only Location Inventory Accounting

#### Status
Accepted (Hardened in Phase 1.3)

#### Context
A warehouse contains storage shelves, receiving bays, shop-floor buffers, worker custody, damage quarantine, and dispatch. If parent container locations receive ledger postings, balances double-count and inventory integrity collapses.

#### Decision
1. **Strict Leaf-Only Ledger Postings:**
   All inventory ledger movements (`stock_transactions`) record physical balances strictly against leaf locations (`is_leaf = true`). Parent nodes (`is_leaf = false`) are pure organizational aggregators and cannot receive direct postings.
2. **Explicit Rejection Rules:**
   - Source and destination cannot be identical (`source IS DISTINCT FROM destination`).
   - Consumption must have `destination_location_id IS NULL`.
   - Scrap disposal must originate strictly from `DAMAGE_QUARANTINE` with `destination_location_id IS NULL`.
   - Quarantine moves must set `destination_location_id` to `DAMAGE_QUARANTINE`.

---

### ADR-018: Multi-Row Transactional Idempotency and Normalized Stock Movement Integrity

#### Status
Accepted (Updated in Phase 1.3)

#### Context
1. An HTTP request (e.g., posting Goods Receipt with 5 items, or backflushing 4 BOM lines) generates multiple ledger rows. Unique constraints on `stock_transactions.idempotency_key` break multi-row operations.
2. Polymorphic string references (`reference_entity_type` + `id`) prevent PostgreSQL foreign key validation. Furthermore, a circular foreign key between `stock_adjustments.stock_transaction_id` and `stock_transactions.stock_adjustment_id` creates chicken-and-egg insertion deadlocks.

#### Decision
1. **Multi-Row Request Idempotency Model:**
   - Dedicated table `idempotency_keys` stores the request header, endpoint, payload SHA-256 hash, and cached response.
   - `stock_transactions` references `idempotency_keys.idempotency_key` as a non-unique foreign key, complemented by `transaction_sequence INT NOT NULL DEFAULT 1` and `UNIQUE(idempotency_key, transaction_sequence)`.
   - Idempotent retries return the stored response without reposting ledger rows; payload collisions return HTTP 409 Conflict.
2. **Normalized Stock Movement Integrity (Eliminating Polymorphic Strings):**
   `stock_transactions` replaces polymorphic strings with strongly-typed, nullable foreign keys and a strict constraint `chk_stock_movement_reference_integrity` covering all 9 movement types.
3. **Resolution of Circular Reference:**
   The circular dependency is eliminated: `stock_transactions.stock_adjustment_id` references `stock_adjustments.id`. `stock_adjustments.stock_transaction_id` is permanently removed. The adjustment header is committed first, followed by the ledger deduction/addition pointing to it.

---

### ADR-019: Source-Optional Packing Jobs with Release-Gated Immutable Snapshots

#### Status
Accepted (Phase 1.4 correction)

#### Decision
`packing_jobs.master_bom_id` is nullable. A job is either master-derived (`master_bom_id` selected, snapshot copies the selected version) or source-less custom (`master_bom_id NULL`, supplied custom lines). Draft input is not production authority. A single release transaction creates exactly one immutable snapshot and non-empty complete lines, validates them, creates reservations, and only then transitions the job to `RELEASED`. A custom snapshot has `is_customized = true`, `source_bom_id = NULL`, and `bom_version = NULL`; a master-derived snapshot has all three source fields consistently populated. Fake one-off master BOMs are prohibited.

---

### ADR-020: Complete Stock-Movement Reference and Location Validation

#### Status
Accepted (Phase 1.4 correction)

#### Decision
The nine movement types use an exhaustive row-level reference matrix in `SYSTEM_DESIGN.md`. A same-row CHECK rejects every prohibited null/non-null reference combination. A ledger posting procedure plus `BEFORE INSERT` trigger validates cross-table facts—active leaf endpoints, location types, receipt/job/completion/worker/adjustment correlations, and direction—while locking source balances and projections. Location topology changes are blocked when balances, reservations, assignments, or movement history would make the change invalid. CHECK constraints are never used for table lookups.

---

### ADR-021: Actual-Administrator JWT Role-Update RPC

#### Status
Accepted (Phase 1.4 correction)

#### Decision
Administrator role and activation changes occur only through a narrowly scoped, security-definer RPC invoked with the actual verified administrator JWT. The function derives the actor from `auth.uid()`, independently verifies an active `ADMIN` profile, locks actor and target, applies validated access changes, and writes an audit record atomically. It has no actor-ID argument; `authenticated` alone gets EXECUTE, while direct target-profile writes and privileged server-credential impersonation are denied. `trg_protect_profile_role` remains fail-closed and therefore observes the same identity as the RPC.

---

### ADR-022: OpenAPI 3.0.3 Contract Baseline and Safe Quantity Revision

#### Status
Accepted (Phase 1.4 correction)

#### Decision
The canonical YAML remains OpenAPI **3.0.3**, matching its `nullable: true` syntax. Documentation must not call it OpenAPI 3.1. A quantity revision is rejected with HTTP 422 when `revisedQuantity < completed_quantity`; completed production is immutable and an overproduction case requires a separately authorized, audited exception workflow.

---

### ADR-023: Trusted Goods Receipt Calculation and Response Model

#### Status
Accepted (Phase 1.5 correction)

#### Decision
The GRN request carries original measurements only: entered quantity/unit, explicit rejected quantity/unit, physical packaging evidence, and receipt/destination context. The posting procedure selects/validates conversions, normalizes rejection without mixed-unit arithmetic, calculates accepted entered-unit quantity and authoritative canonical quantity, records immutable provenance, posts receipt and ledger rows atomically, and returns those calculated results. A UI `expectedCanonicalQuantity` is optional comparison data only and can never be ledger authority.

---

### ADR-024: Canonical Unit Immutability after Inventory Activity

#### Status
Accepted (Phase 1.5 correction)

#### Decision
A material canonical unit may change only before any stock transaction, reservation, or released BOM snapshot line exists. A database trigger rejects later changes. The selected correction path preserves the old variant and creates a replacement variant with the intended canonical unit; historical ledger rows, projections, reservations, and snapshots are never silently rebased or reinterpreted. No conversion/rebase procedure is authorized by this design.

---

### ADR-025: Immutable Conversion Provenance

#### Status
Accepted (Phase 1.5 correction)

#### Decision
Every conversion-dependent receipt, ledger transaction, and released snapshot stores source/canonical units, selected conversion-rule ID when applicable, applied factor, direction, exact/estimated classification, and original/canonical quantities. Conversion rules are append-only versions. Direct canonical-unit operations store a null rule, factor 1, `NONE`, and `EXACT`. Reports reconstruct history from frozen values rather than a rule currently effective today.

---

### ADR-026: Leaf-Only Authoritative Location Accounting

#### Status
Accepted (Phase 1.5 correction)

#### Decision
Only active leaves can hold `material_location_balances` and receive ledger postings. Parents are organizational display containers whose totals are derived from descendants and never added to total physical stock. Leaves are partitioned into usable (`STORE_SHELF`, `SHOP_FLOOR_BUFFER`), receiving, worker custody, quarantine, and dispatch; the existing movement matrix remains the authority for each permitted flow.

---

### ADR-027: Owner-Bound Idempotency Replay and Rollback-Removes-Key Semantics

#### Status
Accepted (Phase 1.6 correction)

#### Decision
The idempotency token remains a globally unique opaque primary key, but no key alone authorizes a replay. Each header stores JWT-derived `owner_id`, server-normalized `operation_scope`, and canonical payload hash. Existing-key lookup compares all four values before status/body access; any mismatch returns one generic HTTP 409 and reveals neither cached data nor its owner.

The header, all $1 \dots N$ generated ledger rows, projections, domain effects, and cached 2xx response share one PostgreSQL transaction. A failure rolls everything back, including the newly inserted key; no `FAILED` state is persisted. A timeout after commit is safe because the matching retry reads the completed cached response. Direct PostgREST cache reads/writes are denied, and a service credential is not treated as a caller identity.

---

### ADR-028: Two-Tier Idempotency Architecture with Ephemeral Response Cache, Foreign Key Preservation, and HTTP 410 Expiration Semantics

#### Status
Accepted (Phase 1.7 correction)

#### Context
`stock_transactions` and `production_completions` reference the request-level idempotency key with restrictive foreign keys (`ON DELETE RESTRICT`) to provide unshakeable audit provenance. However, storing large HTTP response JSONB bodies indefinitely creates severe table bloat and violates data minimization policies. A naive background pruning job attempting to delete old `idempotency_keys` would trigger PostgreSQL foreign key constraint violations (`23503`) against historical stock transactions, while cascading deletion would destroy the ledger. Furthermore, previous matrix descriptions erroneously listed `idempotency_keys` as having PostgREST read access.

#### Decision
1. **Two-Tier Schema Separation:**
   - **`idempotency_keys` (Table 31 - Permanent Request Identity Header):** Stores `idempotency_key`, `owner_id` (JWT-derived), `operation_scope`, `request_hash`, `status`, `resource_type`, `resource_id`, `created_at`, `locked_at`, and `operation_completed_at`. This table is permanently retained and NEVER pruned, preserving 100% foreign key integrity for `stock_transactions` and `production_completions`.
   - **`idempotency_responses` (Table 32 - Ephemeral Response Cache):** Stores `idempotency_key` (PK referencing `idempotency_keys` ON DELETE CASCADE), `response_status_code`, `response_body` (JSONB), `created_at`, and `expires_at` (default: `created_at + INTERVAL '7 days'`).
2. **Safe Background Pruning:**
   Background maintenance workers periodically prune expired cached responses:
   ```sql
   DELETE FROM public.idempotency_responses WHERE expires_at < NOW();
   ```
   This deletes only response JSONB payloads without touching `idempotency_keys` or any stock transactions, avoiding foreign key errors completely.
3. **HTTP 410 Expiration Semantics on Retry:**
   When a client retries an operation whose key exists in `idempotency_keys` with `status = 'COMPLETED'` and matching owner/scope/hash, but whose response cache row in `idempotency_responses` has expired and been pruned, the server **never re-executes the operation**. Instead, it returns **HTTP 410 Gone** with error code `IDEMPOTENCY_RESPONSE_EXPIRED`, returning the linked `resource_type`, `resource_id`, and `operation_completed_at` timestamp. The client can query the business entity directly via its authorized GET endpoint.
4. **Complete PostgREST Denial:**
   Both `idempotency_keys` and `idempotency_responses` have all direct PostgREST reads, writes, updates, and deletes denied (`USING (false)` for `anon` and `authenticated`). Access is mediated strictly via authorized transactional database procedures callable by Flask.
5. **Canonical Table Count:**
   The addition of `idempotency_responses` establishes the authoritative database schema at exactly **33 relational tables**.

---

### ADR-029: Authoritative Route Registry, 100% Mandatory Flask Idempotency, and Expired-Response Recovery Contract

#### Status
Accepted (Phase 1.8 alignment)

#### Context
Discrepancies emerged between `SYSTEM_DESIGN.md` §2.3, `API_CONTRACT.yaml`, and secondary project documents:
1. Route naming was inconsistent between plural and singular conventions (e.g., `/stock/transfers` vs `/stock/transfer`, `/stock/issues` vs `/stock/issue-to-worker`, `/stock/returns` vs `/stock/return-from-worker`, `/stock/quarantine` vs `/stock/damage-quarantine`, `/stock/scrap` vs `/stock/scrap-disposal`, `/stock/purchase-returns` vs `/stock/purchase-return`, `/packing-jobs/{id}/revisions` vs `/packing-jobs/{id}/revise-quantity`, `/closings/submit` vs `/closings`).
2. The idempotency header policy was fragmented: stock endpoints required idempotency while BOM and PO creation endpoints marked it as optional, leaving non-stock state-changing writes vulnerable to duplicate requests.
3. Master catalog operations (`material_categories`, `materials`) were mistakenly conflated between direct PostgREST CRUD and the Flask API contract.
4. HTTP 410 (`IDEMPOTENCY_RESPONSE_EXPIRED`) responses referred clients to query resources via GET, but the Flask API contract lacked explicit detail GET endpoints for several returned `resource_type` entities (such as `GOODS_RECEIPT`, `PRODUCTION_COMPLETION`, `DAILY_CLOSING`).
5. Pre-commit timestamps were labeled `committed_at`, falsely asserting that a physical PostgreSQL commit timestamp was known prior to transaction commit.

#### Decision
1. **Authoritative Route Registry Standards:**
   - State-changing stock movements adopt singular, domain-action verbs:
     - `POST /api/v1/stock/transfer`
     - `POST /api/v1/stock/issue-to-worker`
     - `POST /api/v1/stock/return-from-worker`
     - `POST /api/v1/stock/damage-quarantine`
     - `POST /api/v1/stock/scrap-disposal`
     - `POST /api/v1/stock/adjustments`
     - `POST /api/v1/stock/purchase-return`
   - Job lifecycle mutations use explicit actions: `POST /api/v1/packing-jobs/{id}/revise-quantity`, `POST /api/v1/packing-jobs/{id}/cancel`.
   - Shift closings use canonical paths: `POST /api/v1/closings`, `POST /api/v1/closings/{id}/reopen`.
   - Administrative role updates use: `POST /api/v1/admin/users/{targetId}/access`.
2. **Channel Ownership & 100% Mandatory Flask Idempotency:**
   - **Direct PostgREST Channel:** Master catalog tables (`material_categories`, `parties`, `products`, `vendors`, `units`, `locations`, `workers`, `materials`, `material_conversions`) are managed directly through Supabase REST (`/rest/v1/...`). PostgREST does not accept Flask idempotency headers (`N/A`); duplicate writes are strictly prevented via PostgreSQL primary keys and unique constraints (`UNIQUE` indexes).
   - **Flask API Channel:** 100% of state-changing commands (all 20 POST endpoints under `/api/v1`) **mandatorily** require an `Idempotency-Key` header (16–128 ASCII characters matching `^[A-Za-z0-9_\-\.:]{16,128}$`).
3. **Complete Expired-Response Recovery Contract:**
   The Flask API provides 10 authoritative detail GET endpoints corresponding 1:1 with `idempotency_keys.resource_type`:
   - `GET /api/v1/goods-receipts/{id}` (`GOODS_RECEIPT`)
   - `GET /api/v1/production/completions/{id}` (`PRODUCTION_COMPLETION`)
   - `GET /api/v1/stock/transactions/{id}` (`STOCK_TRANSACTION`)
   - `GET /api/v1/stock/adjustments/{id}` (`STOCK_ADJUSTMENT`) — **Added in Phase 1.9**
   - `GET /api/v1/purchase-orders/{id}` (`PURCHASE_ORDER`)
   - `GET /api/v1/boms/{id}` (`BOM`)
   - `GET /api/v1/daily-plans/{id}` (`DAILY_PLAN`)
   - `GET /api/v1/packing-jobs/{id}` (`PACKING_JOB`)
   - `GET /api/v1/closings/{id}` (`DAILY_CLOSING`)
   - `GET /api/v1/admin/users/{targetId}` (`PROFILE`) — **Added in Phase 1.9**
4. **Strict Timestamp Semantics (`operation_completed_at`):**
   The response schema for HTTP 410 and Table 31 (`idempotency_keys`) replaces `committed_at` with `operation_completed_at` (timestamptz, nullable; set when the transaction completes processing and marks `status = 'COMPLETED'`). Pre-commit timestamps must not be represented as database commit timestamps.

---

## ADR-030: OpenAPI SupabaseJWT Security Scheme, Complete OperationIds, and Explicit Success Schemas

**Status:** Accepted  
**Date:** 2026-10-19  
**Phase:** 1.9 — Final API Security and Contract Completeness Gate  

### Context

Phase 1.8 established an authoritative 31-endpoint Flask REST API contract (later expanded to 33 operations in Phase 1.9 by adding `GET /stock/adjustments/{id}` and `GET /admin/users/{targetId}`). Three contract-level deficiencies remained:

1. **Missing security scheme:** `API_CONTRACT.yaml` lacked `components.securitySchemes`, a global `security` policy, and explicit 401/403 response definitions. While the authentication mechanism was described in prose (Phase 1.8 ADR-029 and SYSTEM_DESIGN.md §2.2), it was not machine-readable in OpenAPI terms, preventing code generators and security linting tools from enforcing it.
2. **Missing operationIds:** None of the 31+ operations had `operationId` fields, blocking client SDK generation, contract-driven testing, and automated documentation tools.
3. **Incomplete success schemas:** 7 POST operations returned HTTP 200 with no `content` schema (issue-to-worker, return-from-worker, transfer, damage-quarantine, scrap-disposal, adjustments, purchase-return). The profile access update command also lacked a structured 200 schema. This prevented response validation and client type generation.
4. **Incomplete resource recovery map:** `STOCK_ADJUSTMENT` and `PROFILE` appeared in the `IdempotencyExpiredError.resourceReference.resourceType` enum but had no corresponding Flask GET recovery endpoint, creating an irreconcilable gap between the recovery protocol and the actual API surface.

### Decision

The following additions are formalized in `API_CONTRACT.yaml`:

#### 1. SupabaseJWT Security Scheme
- `components.securitySchemes.SupabaseJWT` is defined as type `http`, scheme `bearer`, bearerFormat `JWT`.
- A top-level `security: [{SupabaseJWT: []}]` policy applies globally to all operations. Of the 33 total Flask operations (20 POST commands, 13 GET queries), exactly 32 are protected operations requiring a valid Bearer token; `GET /health` overrides this with `security: []` (explicitly unauthenticated).
- Two reusable HTTP error responses are added: `components.responses.UnauthorizedResponse` (HTTP 401, code `UNAUTHORIZED`) and `components.responses.ForbiddenResponse` (HTTP 403, code `FORBIDDEN`), both using `StandardError` schema. All protected endpoints replace generic `ErrorResponse` references in 401/403 positions with the semantically correct `UnauthorizedResponse` and `ForbiddenResponse`.

#### 2. Unique OperationIds on All 33 Operations
Every operation receives a descriptive, camelCase `operationId`. All 33 are unique with zero duplicates. The full list is:
- Commands (20): `updateUserProfileAccess`, `createPurchaseOrder`, `createMasterBom`, `createBomVersion`, `activateBomVersion`, `postGoodsReceipt`, `issueStockToWorker`, `returnStockFromWorker`, `transferStock`, `damageQuarantineStock`, `scrapDisposalStock`, `postStockAdjustment`, `postPurchaseReturn`, `createDailyPlan`, `releaseDailyPlan`, `revisePackingJobQuantity`, `cancelPackingJob`, `recordProductionCompletion`, `executeDailyClosing`, `reopenDailyClosing`.
- Queries (13): `getHealth`, `getPurchaseOrder`, `getBom`, `getGoodsReceipt`, `getStockTransaction`, `getStockAdjustment`, `getStockBalances`, `getStockLedger`, `getDailyPlan`, `getPackingJob`, `getProductionCompletion`, `getDailyClosing`, `getUserProfile`.

#### 3. Complete Success Response Schemas
All 20 POST operations now have structured success response schemas:
- `POST /stock/issue-to-worker`, `POST /stock/return-from-worker`, `POST /stock/transfer`, `POST /stock/damage-quarantine`, `POST /stock/scrap-disposal`, `POST /stock/purchase-return` → `StockMovementResponse` (reusable schema). Returns `stockTransactionId`, `movementType`, `materialId`, `canonicalQuantity`, `canonicalUnitId`, `sourceLocationId`, `destinationLocationId`, `createdAt`.
- `POST /stock/adjustments` → `StockAdjustmentDetailResponse` (reusable schema). Returns adjustment primary key, material, location, counted quantity, system quantity before, signed variance, supervisor approval reference, linked `stockTransactionId`, `createdAt`.
- `POST /admin/users/{targetId}/access` → `ProfileAccessUpdateResponse` (reusable schema). Returns `success`, `profile` (as `ProfileResponse`), and `auditLogId`.
- `ProfileResponse`: User profile projection schema reused by both `POST /admin/users/{targetId}/access` and `GET /admin/users/{targetId}`.

#### 4. Complete Resource Recovery Map (10 → 10, was 8)
Two previously unresolved resource types now have Flask GET endpoints:
- `STOCK_ADJUSTMENT` → `GET /api/v1/stock/adjustments/{id}` (`operationId: getStockAdjustment`, schema `StockAdjustmentDetailResponse`)
- `PROFILE` → `GET /api/v1/admin/users/{targetId}` (`operationId: getUserProfile`, schema `ProfileResponse`)

All 10 `resourceType` enum values in `IdempotencyExpiredError` now map 1:1 to an authorized Flask GET endpoint.

### Consequences
- `API_CONTRACT.yaml` advances to **v1.9.0** (and further refined in v1.10.0) with 33 operations, 33 unique operationIds, 238 `$ref` pointers (all resolved), global `SupabaseJWT` security policy, 5 named response components, and complete success schemas on all 20 POST commands.
- SDK generators (OpenAPI Generator, swagger-codegen) can now produce fully typed client libraries without manual response schema annotation.
- Security linting tools can validate that no operation exposes an unprotected route except `/health`.
- The recovery protocol is provably complete: every `resourceType` the server can return in an HTTP 410 body has a corresponding authorized GET endpoint that returns a machine-readable success schema.
- `SYSTEM_DESIGN.md §2.2` and `§2.4` updated; `TEST_PLAN.md` Scenarios 37–39 added.

---

## ADR-031: Idempotency Identifier Alignment, camelCase Error References, and Protected Operation Accounting

**Status:** Accepted  
**Date:** 2026-10-19  
**Phase:** 1.10 — Final Schema/API Alignment Before Database Migrations  

### Context

Ahead of Phase 2 database migrations, four inconsistencies across schema definitions, endpoint accounting, and API response conventions were identified:

1. **Idempotency Identifier Type Mismatch:** `StockMovementResponse` and `StockAdjustmentDetailResponse` exposed an invented `idempotencyKeyId: UUID` property. However, in `SYSTEM_DESIGN.md` Table 31 (`idempotency_keys`), the primary key is the client-supplied text token `idempotency_key` (length 16–128). Foreign keys in `stock_transactions` and `production_completions` reference this text key directly. No surrogate UUID row-ID column exists in the database.
2. **Ambiguous Protected Endpoint Count:** While 33 total operations exist (20 POST commands + 13 GET queries), certain sections described 31 endpoints (from Phase 1.8 before recovery route expansion) or claimed that "all 33 operations require authentication" without acknowledging that `GET /health` explicitly overrides security with `security: []`.
3. **Incomplete Table 31 Resource Type Description:** The descriptive resource type list for `idempotency_keys.resource_type` only listed 8 example types, omitting `STOCK_ADJUSTMENT` and `PROFILE` which were added to the 10-type recovery enum in Phase 1.9.
4. **Error Field Naming Inconsistency:** `IdempotencyExpiredError` (HTTP 410) utilized snake_case properties (`resource_reference`, `resource_type`, `resource_id`, `operation_completed_at`), deviating from the camelCase convention used consistently across all other public API request and response bodies.

### Decision

1. **Eliminate Invented Surrogate Identifier (`idempotencyKeyId`):**
   - Removed `idempotencyKeyId` from `StockMovementResponse` and `StockAdjustmentDetailResponse` in `docs/API_CONTRACT.yaml`.
   - Table 31 retains the client-supplied text token `idempotency_key` as its natural primary key. No surrogate UUID row-ID is introduced to the database.
   - Clients track and recover stock movements and cycle count adjustments exclusively via domain entity identifiers (`stockTransactionId`, `id`) and through the HTTP 410 `resourceReference` object. Internal idempotency provenance is preserved in database foreign keys (`stock_transactions.idempotency_key`, `production_completions.idempotency_key`) without exposing internal tokens across tenant or user boundaries.
2. **Canonical Protected Endpoint Accounting:**
   - Formalized exact endpoint counts across all canonical documents:
     - **33 total Flask operations** (20 state-changing POST commands + 13 GET queries/lookups).
     - **Exactly 32 protected operations** requiring a valid Supabase JWT Bearer token (`SupabaseJWT` scheme).
     - **1 explicitly unauthenticated probe** (`GET /health` with `security: []`).
3. **Enumerated Table 31 Resource Types & Authoritative Enforcement:**
   - Table 31 `idempotency_keys.resource_type` explicitly enumerates all 10 supported types: `'GOODS_RECEIPT'`, `'PRODUCTION_COMPLETION'`, `'STOCK_TRANSACTION'`, `'STOCK_ADJUSTMENT'`, `'PURCHASE_ORDER'`, `'DAILY_PLAN'`, `'PACKING_JOB'`, `'DAILY_CLOSING'`, `'BOM'`, `'PROFILE'`.
   - Documented that the authoritative enum is enforced at the database level by check constraint `chk_idempotency_keys_resource_type` and mirrored in the OpenAPI contract.
4. **Standardize HTTP 410 JSON Error Fields to camelCase:**
   - Standardized `IdempotencyExpiredError` to use:
     - `resourceReference`: object
       - `resourceType`: string (10-value enum)
       - `resourceId`: UUID string
       - `operationCompletedAt`: ISO date-time string
   - Preserved semantic meaning of HTTP 410: a completed operation with an expired response cache is never re-executed.

### Consequences

- Zero surrogate identifier discrepancies between database schema and API contracts.
- Exact alignment of protected endpoint accounting (32 protected, 1 public, 33 total).
- 100% camelCase consistency across public JSON API request and response envelopes.
- Provable 10/10 recovery route bijection backed by database check constraints and OpenAPI enums.
- All 10 canonical documents advance to version 1.10.0 with full mutual consistency.
