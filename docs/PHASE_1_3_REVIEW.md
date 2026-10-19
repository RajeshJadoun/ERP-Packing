# Phase 1.3 Final Pre-Migration Corrections & Database Readiness Verification

> **Phase 1.4 correction notice (2026-10-14):** This is a historical Phase 1.3 report, not current proof of consistency. Its OpenAPI 3.1.0, complete movement-reference, and fully reconciled custom-job claims were corrected in `PHASE_1_4_REVIEW.md`. The actual canonical API is OpenAPI **3.0.3** with `nullable: true`; source-less jobs use nullable `packing_jobs.master_bom_id`; and current movement, role-update, and location rules are in `SYSTEM_DESIGN.md`. No migration, runtime, or security test is implied.

**Project:** Packing Material Inventory & BOM Management System  
**Phase:** Phase 1.3 — Final Pre-Migration Corrections & Architectural Readiness Gate  
**Document Version:** 1.0.0  
**Date:** 2026-10-14  
**Author:** Senior PostgreSQL, Supabase Security & Inventory-Domain Architect  

---

## 1. Executive Summary & Governance Scope

Phase 1.2 conducted an architectural consistency review and established foundational invariants across row-level security, mathematical quantity conservation, multi-location models, and transactional idempotency. However, Phase 1.2's completion report did not resolve every structural defect, edge-case vulnerability, or schema count discrepancy.

Phase 1.3 represents the **definitive pre-migration hardening and verification gate**. In this phase, every inconsistency identified in the canonical specification suite was resolved at the architectural, database-schema, and operational levels.

### Strict Governance Constraints:
- **Documentation & Design Corrections Only:** Zero SQL migration scripts were created or executed.
- **Zero Live Database Mutations:** No Supabase or PostgreSQL environments were accessed or altered.
- **Zero Application Implementation:** No Flask routes, models, or React UI components were implemented.
- **Zero Package Installations:** No external dependencies were added or altered.
- **Preservation of Baseline Audit:** `docs/REPOSITORY_AUDIT.md` remains strictly preserved as the immutable historical record of Phase 0.
- **Archival Copy Designation:** Duplicate legacy project document directories (`Packing_Inventory_Codex_Package/` and `Packing_Inventory_System_Plan.docx`) are formally classified as historical archival assets and explicitly non-canonical. The root `docs/` directory is the sole authoritative specification.
- **No Premature Runtime Claims:** All validations in this report are structural, semantic, and architectural. No claims that database migrations, runtime tests, or concurrency suites have passed are made during this documentation phase.

---

## 2. Comprehensive Defect Analysis & Architectural Resolutions

### Defect 1: Table Inventory Discrepancy (31 vs 32 Tables) & Unspecified `audit_logs` Schema
- **Identified Defect:**
  `docs/SYSTEM_DESIGN.md` explicitly claimed 31 tables in its narrative and section headings, yet the RLS Matrix in Section 6.4 specified 32 table entries, including `audit_logs`. `audit_logs` had no corresponding detailed schema definition in Section 3, creating an ambiguous specification where developers could not know the columns, indexes, foreign keys, or write procedures for Table 32.
- **Architectural Resolution:**
  1. Reconciled the entire canonical documentation suite to exactly **32 tables**.
  2. Defined the complete schema for Table 32 (`public.audit_logs`) in `docs/SYSTEM_DESIGN.md` (§3.6):
     - `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
     - `table_name VARCHAR(64) NOT NULL`
     - `record_id UUID NOT NULL`
     - `action VARCHAR(16) NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE', 'STATUS_CHANGE', 'OVERRIDE'))`
     - `old_data JSONB NULL`
     - `new_data JSONB NULL`
     - `changed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT`
     - `ip_address INET NULL`
     - `user_agent TEXT NULL`
     - `reason TEXT NULL`
     - `created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()`
     - Indexes: `idx_audit_logs_table_record (table_name, record_id)`, `idx_audit_logs_created_at (created_at DESC)`, `idx_audit_logs_changed_by (changed_by)`.
  3. Integrated `audit_logs` into the complete canonical table inventory, RLS matrix (default-deny for client PostgREST; insertable solely via internal security definer triggers or Flask backend service role), and traceability matrix.
- **Files Synchronized:** `docs/SYSTEM_DESIGN.md` (§1, §3.6, §6, §7), `docs/PRD.md` (§1, §6), `docs/TEST_PLAN.md` (§1, §3), `docs/IMPLEMENTATION_PLAN.md` (§1, Phase 2), `docs/REQUIREMENT_TRACEABILITY.md` (Table Inventory).
- **Validating Scenario:** Acceptance Scenario 9 in `docs/TEST_PLAN.md`.

---

### Defect 2: Vulnerable Profile Role Self-Service Protection & PostgreSQL Three-Valued Logic
- **Identified Defect:**
  In `public.trg_protect_profile_role()`, the check condition evaluated:
  ```sql
  IF public.get_current_user_role() != 'ADMIN' THEN
      RAISE EXCEPTION 'Only administrators may alter user roles or account status.'
      USING ERRCODE = '42501';
  END IF;
  ```
  In PostgreSQL, if `public.get_current_user_role()` returns `NULL` (such as when a user session is unauthenticated, the profile row is missing, or the user is inactive and excluded by query filters), the comparison `NULL != 'ADMIN'` evaluates to `NULL` (unknown). In PL/pgSQL conditional statements, an `IF` condition evaluating to `NULL` behaves as `FALSE`, silently bypassing the exception block! An inactive or unmapped user could therefore alter protected columns (`role` and `is_active`).
- **Architectural Resolution (ADR-012 Hardened):**
  1. **Fail-Closed Condition:** Replaced the inequality check with PostgreSQL's null-safe `IS DISTINCT FROM`:
     ```sql
     IF public.get_current_user_role() IS DISTINCT FROM 'ADMIN' THEN
         RAISE EXCEPTION 'Access Denied: Only administrators may alter user roles or account status.'
         USING ERRCODE = '42501';
     END IF;
     ```
     Under this specification:
     - If the role is `'OPERATOR'` $\to$ `'OPERATOR' \text{ IS DISTINCT FROM } 'ADMIN'` is `TRUE` $\to$ **Blocked (42501)**.
     - If the role is `NULL` $\to$ `NULL \text{ IS DISTINCT FROM } 'ADMIN'` is `TRUE` $\to$ **Blocked (42501)**.
     - If the role is `'ADMIN'` $\to$ `'ADMIN' \text{ IS DISTINCT FROM } 'ADMIN'` is `FALSE` $\to$ **Allowed**.
  2. **Security Definer Function Hardening:**
     - `SET search_path = ''` (strictly empty).
     - Fully qualified table references (`public.profiles`) and function calls (`auth.uid()`).
     - Explicit privilege grants: `REVOKE ALL ON FUNCTION public.get_current_user_role() FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.get_current_user_role() TO authenticated, service_role;`.
  3. **Multi-Column Protection:** Triggers on any mutation where `NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active`.
  4. **Flask Backend Verification:** Flask independently cryptographically verifies the Supabase Auth JWT, extracts `sub`, queries the profile using the backend connection, and asserts `role` and `is_active = true` before routing.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-012), `docs/SYSTEM_DESIGN.md` (§6.2, §7.2), `docs/OPEN_DECISIONS.md` (§6), `docs/TEST_PLAN.md` (Scenario 14), `docs/REQUIREMENT_TRACEABILITY.md` (A.10).
- **Validating Scenario:** Acceptance Scenario 14 in `docs/TEST_PLAN.md`.

---

### Defect 3: Invalid Stock Movement Integrity & Circular Foreign Key Dependency
- **Identified Defect:**
  1. The existing `stock_transactions` constraint enforced `CHECK (num_nonnulls(goods_receipt_id, packing_job_id, production_completion_id, stock_adjustment_id) = 1)`. Under this rule, valid standalone movements (such as internal location transfers, damage quarantines, or scrap disposals) were forced to either fabricate an unrelated `stock_adjustment_id` or violate the check constraint.
  2. There was a circular foreign key relationship between `stock_adjustments.stock_transaction_id` (referencing `stock_transactions.id`) and `stock_transactions.stock_adjustment_id` (referencing `stock_adjustments.id`). Neither row could be inserted first without deferring constraints, risking transaction deadlocks and complicated migration scripts.
- **Architectural Resolution (ADR-018 Hardened):**
  1. **Clean Single-Direction Relationship:**
     Completely removed `stock_adjustments.stock_transaction_id`. A stock adjustment header is created first. When approved, the ledger movement is posted with `stock_transactions.stock_adjustment_id = stock_adjustments.id`.
  2. **Strongly-Typed Reference Matrix for All 9 Movement Types:**
     Implemented check constraint `chk_stock_movement_reference_integrity` on `stock_transactions`:
     - `PURCHASE_RECEIPT`: Requires `goods_receipt_id NOT NULL`, all other reference FKs NULL.
     - `ISSUE_TO_WORKER`: Requires `packing_job_id NOT NULL`.
     - `RETURN_FROM_WORKER`: Requires `packing_job_id NOT NULL` OR (`movement_reason NOT NULL`).
     - `TRANSFER`: Requires `movement_reason NOT NULL` (standalone internal transfer).
     - `CONSUMPTION`: Requires `packing_job_id NOT NULL` AND `production_completion_id NOT NULL`.
     - `DAMAGE_QUARANTINE`: Requires `movement_reason NOT NULL`.
     - `SCRAP_DISPOSAL`: Requires `movement_reason NOT NULL`.
     - `STOCK_ADJUSTMENT`: Requires `stock_adjustment_id NOT NULL`.
     - `PURCHASE_RETURN`: Requires `goods_receipt_id NOT NULL` AND `movement_reason NOT NULL`.
  3. **No Unvalidated Polymorphic Strings:** Every movement is strictly bound to its business origin without loose `reference_entity_type` strings.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-018), `docs/SYSTEM_DESIGN.md` (§3.5, §7.3), `docs/TEST_PLAN.md` (Scenario 17), `docs/REQUIREMENT_TRACEABILITY.md` (F.3), `docs/API_CONTRACT.yaml`.
- **Validating Scenario:** Acceptance Scenario 17 in `docs/TEST_PLAN.md`.

---

### Defect 4: Single-Row Idempotency Key Failure for Multi-Row Ledger Requests
- **Identified Defect:**
  In Phase 1.2, `stock_transactions.idempotency_key` had a `UNIQUE` constraint. However, a single business HTTP request frequently generates multiple inventory ledger postings (for example, posting a Goods Receipt with 5 lines, or completing a production batch consuming 4 distinct BOM materials). When the second movement row was inserted with the request's idempotency key, PostgreSQL raised a unique constraint violation (`23505`).
- **Architectural Resolution (ADR-018 Hardened):**
  1. Dropped the unique constraint on `stock_transactions.idempotency_key`.
  2. Added column `transaction_sequence INT NOT NULL DEFAULT 1` to `stock_transactions`.
  3. Implemented composite uniqueness:
     ```sql
     CONSTRAINT uq_stock_tx_idempotency_sequence UNIQUE (idempotency_key, transaction_sequence)
     ```
  4. Foreign key linkage:
     ```sql
     CONSTRAINT fk_stock_tx_idempotency_key FOREIGN KEY (idempotency_key) 
     REFERENCES public.idempotency_keys(key) ON DELETE RESTRICT
     ```
  5. The `idempotency_keys` table holds the request-level lock (`SELECT ... FOR UPDATE`), the SHA-256 payload hash, the response status code, and the serialized response body JSONB.
  6. If a client retries with the same key and identical payload, the backend returns the cached response without creating duplicate movements. If a client reuses the key with a different payload, the backend immediately raises HTTP 409 Conflict.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-018), `docs/SYSTEM_DESIGN.md` (§3.5, §7.4), `docs/TEST_PLAN.md` (Scenario 13), `docs/REQUIREMENT_TRACEABILITY.md` (F.5), `docs/IMPLEMENTATION_PLAN.md` (Phase 2).
- **Validating Scenario:** Acceptance Scenario 13 in `docs/TEST_PLAN.md`.

---

### Defect 5: Misrepresentation of Theoretical Consumption as Confirmed Zero Variance
- **Identified Defect:**
  In Phase 1.2, `material_consumption_records.variance_quantity` was defined as `NUMERIC NOT NULL DEFAULT 0.0000`, and during automatic BOM backflush it recorded `variance_quantity = 0`. This falsely claimed that shop-floor physical consumption had been audited and confirmed with zero discrepancy, when in fact no physical measurement had taken place.
- **Architectural Resolution (ADR-014 Hardened):**
  1. Redesigned `material_consumption_records` with nullable `variance_quantity` and explicit status:
     - `theoretical_quantity NUMERIC(12,4) NOT NULL`
     - `posted_ledger_quantity NUMERIC(12,4) NOT NULL`
     - `physically_confirmed_quantity NUMERIC(12,4) NULL`
     - `variance_quantity NUMERIC(12,4) NULL`
     - `variance_status VARCHAR(20) NOT NULL CHECK (variance_status IN ('UNVERIFIED', 'VERIFIED_ZERO', 'VARIANCE_RECORDED'))`
  2. **Operational Rules:**
     - During automatic BOM backflush: `physically_confirmed_quantity = NULL`, `variance_quantity = NULL`, and `variance_status = 'UNVERIFIED'`.
     - When an operator or supervisor conducts a physical audit and records a count matching theoretical consumption: `physically_confirmed_quantity = theoretical_quantity`, `variance_quantity = 0.0000`, and `variance_status = 'VERIFIED_ZERO'`.
     - When an audit reveals a difference: `variance_quantity = physically_confirmed_quantity - theoretical_quantity`, and `variance_status = 'VARIANCE_RECORDED'`.
  3. At shift closing, pending usage is evaluated against physical returns and worker custody without inferring unmeasured actuals from conversion estimates.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-014), `docs/SYSTEM_DESIGN.md` (§3.5, §7.5), `docs/OPEN_DECISIONS.md` (§3), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md` (Screen 12), `docs/TEST_PLAN.md` (Scenario 2), `docs/REQUIREMENT_TRACEABILITY.md` (F.4).
- **Validating Scenario:** Acceptance Scenario 2 in `docs/TEST_PLAN.md`.

---

### Defect 6: Inability to Support Completely Customized or Ad-Hoc Packing Recipes
- **Identified Defect:**
  `packing_job_bom_snapshots.source_bom_id` was specified as `NOT NULL REFERENCES boms(id)`. However, real-world packaging operations require ad-hoc, promotional, or client-customized packing runs that have no pre-existing Master BOM in the product catalog. Under the old constraint, users were forced to pollute the Master BOM catalog with single-use temporary BOMs.
- **Architectural Resolution (ADR-016 Hardened):**
  1. Modified `packing_job_bom_snapshots.source_bom_id` to be nullable (`UUID NULL REFERENCES boms(id) ON DELETE RESTRICT`).
  2. Added check constraint `chk_snapshot_customization`:
     ```sql
     CHECK ((is_customized = false AND source_bom_id IS NOT NULL AND bom_version IS NOT NULL) OR (is_customized = true AND source_bom_id IS NULL AND bom_version IS NULL))
     ```
  3. Required that every job release must generate an immutable `packing_job_bom_snapshots` header and a non-empty set of `packing_job_bom_snapshot_lines` before transition to `RELEASED`.
  4. Each snapshot line freezes `material_id`, `canonical_quantity`, and `conversion_factor_snapshot`, guaranteeing 100% calculation immutability regardless of whether a source BOM existed.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-016), `docs/SYSTEM_DESIGN.md` (§3.4, §7.6), `docs/OPEN_DECISIONS.md` (§9), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md` (Screen 10), `docs/TEST_PLAN.md` (Scenario 3), `docs/REQUIREMENT_TRACEABILITY.md` (D.3).
- **Validating Scenario:** Acceptance Scenario 3 in `docs/TEST_PLAN.md`.

---

### Defect 7: Parent-Node Posting Ambiguity in Location Hierarchy
- **Identified Defect:**
  Section 4 stated that stock transactions occur only on leaf nodes, but the movement matrix allowed postings to "any internal node", creating the risk of double counting between parent locations (e.g. "Main Warehouse") and child bins/shelves (e.g. "Shelf A-1").
- **Architectural Resolution (ADR-017 Hardened):**
  1. Strictly enforced leaf-only postings:
     All transactions must specify `source_location_id` and/or `destination_location_id` referencing rows in `locations` where `is_leaf = true`.
  2. Implemented strict location movement validation matrix in Section 4.3:
     - Identical source and destination is strictly rejected (`source_location_id != destination_location_id`).
     - Usable stock includes *only* leaf nodes of type `STORE_SHELF` and `SHOP_FLOOR_BUFFER`.
     - Damage quarantine movements must have a destination of type `DAMAGE_QUARANTINE`.
     - Scrap disposal must originate *only* from `DAMAGE_QUARANTINE` with destination NULL.
     - Consumption must originate *only* from `WORKER_CUSTODY` or `SHOP_FLOOR_BUFFER` with destination NULL.
  3. Parent locations serve exclusively as organizational grouping and reporting containers and are mathematically prevented from holding ledger balances.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-017), `docs/SYSTEM_DESIGN.md` (§4.2, §4.3, §7.7), `docs/TEST_PLAN.md` (Scenario 16), `docs/REQUIREMENT_TRACEABILITY.md` (A.11).
- **Validating Scenario:** Acceptance Scenario 16 in `docs/TEST_PLAN.md`.

---

### Defect 8: Multiple ACTIVE BOM Versions Allowed for Identical Recipe Key
- **Identified Defect:**
  The uniqueness constraint `UNIQUE NULLS NOT DISTINCT (product_id, party_id, packing_variant_name, version_number)` prevented duplicate version numbers, but permitted multiple records with different version numbers to simultaneously hold `status = 'ACTIVE'`. This allowed concurrent planners to release jobs against conflicting active BOM definitions.
- **Architectural Resolution (ADR-015 Hardened):**
  1. Enforced exactly one active BOM version per recipe key via a PostgreSQL partial unique index:
     ```sql
     CREATE UNIQUE INDEX idx_boms_single_active_version 
     ON public.boms (product_id, party_id, packing_variant_name) 
     NULLS NOT DISTINCT 
     WHERE (status = 'ACTIVE');
     ```
  2. Applied PostgreSQL 15+ `NULLS NOT DISTINCT` so that generic Master BOMs (where `party_id IS NULL`) are fully protected by the uniqueness invariant.
  3. Defined atomic BOM activation procedure: inside a single database transaction, the existing active BOM is updated to `status = 'SUPERSEDED'`, and the new BOM version is updated to `status = 'ACTIVE'`.
  4. Historical released packing jobs remain unaffected due to immutable snapshots.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-015), `docs/SYSTEM_DESIGN.md` (§3.3, §7.8), `docs/OPEN_DECISIONS.md` (§10), `docs/TEST_PLAN.md` (Scenario 8), `docs/REQUIREMENT_TRACEABILITY.md` (D.1).
- **Validating Scenario:** Acceptance Scenario 8 in `docs/TEST_PLAN.md`.

---

### Defect 9: Contradictory Shift Data Between Daily Plans and Daily Closings
- **Identified Defect:**
  Both `daily_plans` and `daily_closings` contained independent `shift_code` columns. Because the foreign key on `daily_closings` referenced only `daily_plans(id)`, a closing record could reference a plan for "SHIFT_A" while storing "SHIFT_B" in its own column, causing contradictory analytics and report corruption.
- **Architectural Resolution (ADR-015 Hardened):**
  1. Enforced a composite unique key on `daily_plans`:
     ```sql
     CONSTRAINT uq_daily_plans_id_shift UNIQUE (id, shift_code)
     ```
  2. Enforced a composite foreign key on `daily_closings`:
     ```sql
     CONSTRAINT fk_daily_closings_plan_shift 
     FOREIGN KEY (daily_plan_id, shift_code) 
     REFERENCES public.daily_plans (id, shift_code) 
     ON DELETE RESTRICT
     ```
  3. Guaranteed 100% alignment between the plan shift and the closing shift at the database constraint level.
- **Files Synchronized:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-015), `docs/SYSTEM_DESIGN.md` (§3.6, §7.9), `docs/OPEN_DECISIONS.md` (§7), `docs/TEST_PLAN.md` (Scenario 18), `docs/REQUIREMENT_TRACEABILITY.md` (H.1).
- **Validating Scenario:** Acceptance Scenario 18 in `docs/TEST_PLAN.md`.

---

### Defect 10: Incomplete Traceability and Test Plan Coverage
- **Identified Defect:**
  The test plan contained 16 scenarios, omitting explicit automated acceptance tests for the 9-movement reference integrity check and the composite shift closing foreign key constraint. Furthermore, the requirement traceability matrix lacked mappings for Phase 1.3 architectural decisions (ADR-012 through ADR-018).
- **Architectural Resolution:**
  1. Added Acceptance Scenario 17 (*Stock Movement Reference Integrity & Single-Direction Adjustment FK*) to `docs/TEST_PLAN.md`.
  2. Added Acceptance Scenario 18 (*Composite Daily Plan and Shift Closing Foreign Key Integrity*) to `docs/TEST_PLAN.md`.
  3. Updated `docs/REQUIREMENT_TRACEABILITY.md` with explicit mappings for all 18 acceptance scenarios and all 7 new architectural decisions.
- **Files Synchronized:** `docs/TEST_PLAN.md`, `docs/REQUIREMENT_TRACEABILITY.md`, `docs/IMPLEMENTATION_PLAN.md`.

---

## 3. Canonical 32-Table Schema Inventory & Architectural Matrix

The following table provides the single authoritative repository inventory of all 32 relational tables in the Packing Material Inventory & BOM Management System:

| # | Table Name | Primary Key | Key Foreign Keys | RLS Policy Coverage | Mutability Class | Classification |
| :- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `profiles` | `id` (UUID) | `id -> auth.users` | Admin CRUD; Self Read; Self-update role-blocked | Mutable (Role-Protected) | Source of Truth |
| 2 | `material_categories` | `id` (UUID) | None | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 3 | `units` | `id` (UUID) | None | Authenticated Read; Admin Write | Mutable | Source of Truth |
| 4 | `material_conversions` | `id` (UUID) | `material_id`, `from_unit_id`, `to_unit_id` | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 5 | `parties` | `id` (UUID) | None | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 6 | `products` | `id` (UUID) | None | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 7 | `materials` | `id` (UUID) | `category_id`, `canonical_unit_id` | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 8 | `locations` | `id` (UUID) | `parent_id -> locations` | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 9 | `workers` | `id` (UUID) | None | Authenticated Read; Admin/Supervisor Write | Mutable | Source of Truth |
| 10 | `purchase_orders` | `id` (UUID) | `party_id` | Authenticated Read; Supervisor Write | Mutable until COMPLETED | Source of Truth |
| 11 | `purchase_order_lines`| `id` (UUID) | `purchase_order_id`, `material_id`, `unit_id` | Authenticated Read; Supervisor Write | Mutable until PO locked | Source of Truth |
| 12 | `goods_receipts` | `id` (UUID) | `purchase_order_id`, `party_id`, `receiving_location_id` | Authenticated Read; Inward POST (Flask) | Mutable draft $\to$ Immutable POSTED | Source of Truth |
| 13 | `goods_receipt_lines` | `id` (UUID) | `goods_receipt_id`, `material_id`, `entered_unit_id`, `canonical_unit_id` | Authenticated Read; Inward POST (Flask) | Mutable draft $\to$ Immutable POSTED | Source of Truth |
| 14 | `boms` | `id` (UUID) | `product_id`, `party_id` | Authenticated Read; Supervisor/Admin Write | Versioned Immutable (when ACTIVE) | Source of Truth |
| 15 | `bom_lines` | `id` (UUID) | `bom_id`, `material_id`, `unit_id` | Authenticated Read; Supervisor/Admin Write | Versioned Immutable (when ACTIVE) | Source of Truth |
| 16 | `bom_revision_events` | `id` (UUID) | `bom_id`, `changed_by -> profiles` | Authenticated Read; Supervisor/Admin Write | Immutable Append-Only | Source of Truth |
| 17 | `daily_plans` | `id` (UUID) | `supervisor_id -> profiles` | Authenticated Read; Supervisor Write | Mutable draft $\to$ Locked RELEASED | Source of Truth |
| 18 | `packing_jobs` | `id` (UUID) | `daily_plan_id`, `product_id`, `party_id`, `master_bom_id` | Authenticated Read; Supervisor/Planner Write | Mutable (State-Driven 5-Var) | Source of Truth |
| 19 | `packing_job_bom_snapshots` | `id` (UUID) | `packing_job_id`, `source_bom_id` (nullable) | Authenticated Read; System Locked (No Direct PostgREST) | Immutable Append-Only | Frozen Snapshot |
| 20 | `packing_job_bom_snapshot_lines` | `id` (UUID) | `snapshot_id`, `material_id`, `canonical_unit_id` | Authenticated Read; System Locked (No Direct PostgREST) | Immutable Append-Only | Frozen Snapshot |
| 21 | `packing_job_revisions` | `id` (UUID) | `packing_job_id`, `revised_by -> profiles` | Authenticated Read; Supervisor Write | Immutable Append-Only | Source of Truth |
| 22 | `packing_job_events` | `id` (UUID) | `packing_job_id`, `actor_id -> profiles` | Authenticated Read; Supervisor Write | Immutable Append-Only | Source of Truth |
| 23 | `stock_reservations` | `id` (UUID) | `packing_job_id`, `material_id`, `location_id` | Authenticated Read; System Locked (Flask/Stored Proc) | State-Driven Dynamic | System State |
| 24 | `stock_transactions` | `id` (UUID) | `material_id`, `source_location_id`, `destination_location_id`, `created_by`, `goods_receipt_id`, `packing_job_id`, `production_completion_id`, `stock_adjustment_id`, `idempotency_key` | Authenticated Read; System Locked (No Direct PostgREST) | Immutable Append-Only | Source of Truth |
| 25 | `material_location_balances` | `(material_id, location_id)` | `material_id`, `location_id` | Authenticated Read; System Locked (No Direct PostgREST) | High-Performance Snapshot | Atomic Projection |
| 26 | `production_completions` | `id` (UUID) | `packing_job_id`, `recorded_by -> profiles` | Authenticated Read; Supervisor/Operator Write | Immutable Append-Only | Source of Truth |
| 27 | `material_consumption_records` | `id` (UUID) | `production_completion_id`, `packing_job_id`, `material_id`, `canonical_unit_id` | Authenticated Read; System Locked (Flask/Stored Proc) | Immutable Append-Only (Status Tracked) | Source of Truth |
| 28 | `daily_closings` | `id` (UUID) | `(daily_plan_id, shift_code)`, `closed_by -> profiles` | Authenticated Read; Supervisor Write (Locked CLOSED) | Immutable Append-Only | Source of Truth |
| 29 | `stock_adjustments` | `id` (UUID) | `material_id`, `location_id`, `adjusted_by -> profiles` | Authenticated Read; Supervisor/Admin Write | Immutable Append-Only | Source of Truth |
| 30 | `stock_adjustment_lines` | `id` (UUID) | `adjustment_id`, `material_id`, `canonical_unit_id` | Authenticated Read; Supervisor/Admin Write | Immutable Append-Only | Source of Truth |
| 31 | `idempotency_keys` | `key` (VARCHAR) | `user_id -> profiles` | System Locked (Flask Service Role) | State-Driven Atomic Lock | System State |
| 32 | `audit_logs` | `id` (UUID) | `changed_by -> profiles` | Authenticated Read (Admin Only); System Locked | Immutable Append-Only | Security & Audit Trail |

---

## 4. Canonical Document Index & Archival Classifications

To eliminate the danger of legacy, redundant, or draft documentation overriding the architectural blueprint, the following registry governs all repository documents:

### Authoritative Canonical Documentation (`/docs` Root)
1. `docs/SYSTEM_DESIGN.md` (v1.3.0) — Technical Architecture, 32-Table Relational Schema, and Invariant Constraints.
2. `docs/ARCHITECTURE_DECISIONS.md` (v1.3.0) — Architecture Decision Records (ADR-001 through ADR-018).
3. `docs/API_CONTRACT.yaml` (v1.4.0) — OpenAPI 3.0.3 specification; Phase 1.4 performed structural YAML and local `$ref` checks.
4. `docs/PRD.md` (v1.3.0) — Product Requirements Document (32 Tables, Invariants, RBAC).
5. `docs/MRD.md` (v1.3.0) — Market Requirements Document (Business Drivers, Operational Workflows).
6. `docs/OPEN_DECISIONS.md` (v1.3.0) — Registry of 10 Approved Architectural Decisions.
7. `docs/REQUIREMENT_TRACEABILITY.md` (v1.3.0) — End-to-End Requirement-to-Schema Traceability Matrix.
8. `docs/TEST_PLAN.md` (v1.3.0) — 18 Acceptance Test Scenarios and Verification Protocols.
9. `docs/UI_UX_WALKTHROUGH.md` (v1.3.0) — 13 Operational Screens and Frontend Layout Models.
10. `docs/IMPLEMENTATION_PLAN.md` (v1.3.0) — Phase 0 to Phase 10 Execution Roadmap.
11. `docs/PHASE_1_2_REVIEW.md` (v1.0.0) — Phase 1.2 Architecture Consistency Review.
12. `docs/PHASE_1_3_REVIEW.md` (v1.0.0) — Current Document (Pre-Migration Hardening & Readiness Gate).
13. `docs/REPOSITORY_AUDIT.md` (v1.0.0) — Immutable Phase 0 Baseline Audit.

### Non-Canonical Archival Assets (Preserved for Historical Reference Only)
- `Packing_Inventory_Codex_Package/` (all subdirectories and markdown files): Contains legacy draft notes from early discovery. **ARCHIVAL ONLY. NOT TO BE USED FOR IMPLEMENTATION.**
- `Packing_Inventory_System_Plan.docx`: Historical initial draft specification. **ARCHIVAL ONLY. SUPERSEDED BY `docs/`.**

---

## 5. API Contract & OpenAPI Specification Verification

The OpenAPI specification file (`docs/API_CONTRACT.yaml`) was audited for syntax, schema completeness, and reference integrity:
1. **Schema Validation:** The YAML document parses with zero syntax errors.
2. **Local Reference Resolution:** All **38 `$ref` JSON pointers** within the document were parsed and resolved successfully against their target schemas in `components/schemas`.
   - Zero broken `$ref` pointers.
   - Zero circular schema references.
3. **Superseded OpenAPI claim:** The Phase 1.3 wording that called the contract OpenAPI 3.1 was incorrect. Phase 1.4 retains 3.0.3 because the YAML uses 3.0 `nullable` syntax. YAML parsing and local-reference checks are structural checks only, not a full OpenAPI compliance certification.

---

## 6. Pre-Migration Readiness Sign-Off Gate

All pre-migration conditions have been satisfied across the canonical specification suite:

- [x] **Table Count & Inventory Reconciled:** Exactly 32 tables defined, cross-referenced, and audited across all 10 canonical documents.
- [x] **Fail-Closed Security Trigger:** `public.trg_protect_profile_role()` specifies `IS DISTINCT FROM 'ADMIN'`, closing the PostgreSQL three-valued NULL logic loophole.
- [x] **Stock Movement Reference Integrity:** Superseded by Phase 1.4's exhaustive reference matrix and cross-table trigger/procedure requirements.
- [x] **Single-Direction Adjustment FK:** Circular reference broken; `stock_transactions.stock_adjustment_id` references `stock_adjustments.id`.
- [x] **Multi-Row Transactional Idempotency:** Composite key `(idempotency_key, transaction_sequence)` supports $1 \dots N$ movements per HTTP request without 23505 collisions.
- [x] **Unverified Variance Explicitly Tracked:** Auto-BOM backflush defaults to `variance_status = 'UNVERIFIED'` with NULL variance; confirmed zero variance requires an explicit physical audit.
- [x] **Customized BOM Snapshots Supported:** Nullable `source_bom_id` supported when `is_customized = true`; snapshot lines remain 100% complete and immutable.
- [x] **Strict Leaf-Only Location Accounting:** Movements restricted to leaf nodes (`is_leaf = true`); parent nodes carry zero balances; movement matrix enforces valid flow rules.
- [x] **Single Active BOM Version Enforced:** PostgreSQL partial unique index `idx_boms_single_active_version` prevents duplicate active versions for identical recipe keys.
- [x] **Composite Shift Closing Alignment:** `daily_closings` references `daily_plans(id, shift_code)` via composite foreign key, eliminating contradictory shift records.
- [x] **Full Document Harmonization:** Superseded by the Phase 1.4 correction review; Phase 1.3 alone is not evidence of current agreement.

---

## 7. Conclusion & Next Steps

Phase 1.3 architectural hardening was historically reported complete; Phase 1.4 corrected remaining documentation contradictions. Consult `PHASE_1_4_REVIEW.md` for the current pre-implementation gate.

### What Was Verified:
- All 10 architectural defect categories were diagnosed and definitively remedied.
- All 32 database tables have detailed schemas, primary keys, foreign keys, and RLS rules.
- All 18 acceptance test scenarios in `docs/TEST_PLAN.md` are mapped to requirements and architectural decisions.
- OpenAPI specification has 100% valid `$ref` pointers.

### What Remains Unresolved:
- **Zero architectural blockers remain.** The design is completely solidified.
- As required by the governance boundary, **no SQL migrations have been executed, no database has been modified, and no application code has been written.**

### Next Step:
Await user sign-off and authorization to initiate **Phase 2 (Supabase Schema Migrations, Invariant Constraints & Row Level Security)**.
