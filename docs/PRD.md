# Product Requirements Document (PRD)

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## 1. Product Vision & Strategic Objectives

The **Packing Material Inventory & BOM Management System** is a mission-critical manufacturing ERP subsystem designed to solve pervasive packing inventory drift, eliminate unauthorized material wastage, enforce customer-specific packaging standards, and provide real-time visibility into finished goods packaging operations.

### 1.1 Core Problems Solved
1. **Inventory Shrinkage & Fictitious Balances:** Eliminates phantom stock caused by direct balance overwrites and uncontrolled shop-floor material withdrawals.
2. **Packaging Non-Compliance:** Prevents packing operators from using incorrect screw lengths, wrong bag gauges, or unapproved cartons by freezing immutable BOM snapshots upon job release.
3. **Premature Consumption Accounting:** Replaces the flawed practice of treating material issues as immediate consumption with a rigorous **Store $\to$ Worker Custody $\to$ Finished Production** lifecycle.
4. **Unit Mismatch Errors:** Solves the discrepancy between purchasing bulk flexible film by weight (KG) and consuming packaging per finished unit (PCS) via dual-unit estimation with audit provenance.
5. **Hardcoded Category Fragility:** Replaces hardcoded category enums with data-driven categories and extensible specifications, allowing administrators to add new packaging materials without code changes.
6. **Incomplete Location Visibility:** Accounts for all facility nodes (receiving bays, store shelves, shop-floor buffers, worker custody, quarantine bays, dispatch) without double counting.

---

## 2. User Personas & Role-Based Access Control (RBAC)

The system enforces five standardized user roles verified via hardened database helper `get_current_user_role()` with empty search path and fail-closed profile column trigger `trg_protect_profile_role()` (`IS DISTINCT FROM 'ADMIN'`):

| Role | Operational Scope | Key Responsibilities |
| :--- | :--- | :--- |
| **`ADMIN`** | Full System Authority | Manage user profiles, system settings, material categories, approve cycle count adjustments, reopen closed operational days, view complete audit logs. |
| **`STOREKEEPER`** | Warehouse & Stock Control | Receive inward shipments (GRN), post material issues to workers, receive unused returns, quarantine damaged goods, execute cycle counts. |
| **`PLANNER`** | Production Scheduling | Maintain master BOMs, create daily packing schedules, customize job-level packaging, revise job quantities, execute daily close. |
| **`OPERATOR`** | Shop-Floor Packing | View assigned packing jobs, record finished goods production completions, log physical material consumption and scrap. |
| **`VIEWER`** | Read-Only Audit & Reporting | Plant managers and auditors who view dashboards, inventory reports, variance analytics, and vendor performance history. |

---

## 3. Detailed Functional Requirements

### Module 1: Master Data Management
- **Material Categories:** Data-driven `material_categories` table (category code, name, description, active toggle). Admin can create new categories dynamically.
- **Materials & Variants:** Item code, material name, category link, canonical unit (selected per material variant), common dimensions (thickness gauge, width, length, height, thread diameter), and extensible `additional_specs` (`jsonb`) for custom domain attributes.
- **Parties / Customers:** Unique party code, name, billing/shipping addresses, active status.
- **Finished Products:** SKU, product description, default customer link, active status.
- **Suppliers / Vendors:** Vendor code, company name, contact info, tax ID (GSTIN), payment terms.
- **Locations Hierarchy:** Comprehensive topology supporting `STORE_SHELF`, `RECEIVING_BAY`, `SHOP_FLOOR_BUFFER`, `WORKER_CUSTODY`, `DAMAGE_QUARANTINE`, and `DISPATCH`. Only active leaves hold balances and receive transactions; parent totals are descendant-derived display values and are never double-counted.
- **Workers / Operators:** Worker ID, name, department, linked virtual custody location.
- **Units & Conversions:** Standard units (KG, G, PCS, BOX, ROLL, MTR) and material-specific exact or estimated conversion formulas with audit notes and explicit conversion directions.

### Module 2: Vendor Purchasing & Inward Receipts
- **Purchase Orders:** PO number, vendor, order date, expected delivery date, status (`DRAFT`, `APPROVED`, `PARTIALLY_RECEIVED`, `COMPLETED`, `CANCELLED`). *Creating a PO does not increase physical stock.*
- **Inward Goods Receipts (GRN):**
  - Vendor, PO reference (optional), invoice number, invoice date, received date (tracked separately from purchase date), destination location.
  - Line items submitted by the operator: entered quantity/unit, rejected quantity with its explicit unit, box count, gross weight, piece count, and optional non-authoritative display estimate.
  - **Trusted Calculation & Posting Rule:** Database procedure validates units and applicable rules, normalizes any differently-unitized rejection, calculates accepted quantity and canonical quantity, freezes conversion rule/factor/direction/classification, then atomically posts the receipt and ledger. Its response returns calculated quantities and provenance. Once posted, the document is permanently immutable (`ON DELETE RESTRICT`).

### Module 3: Authoritative Stock Ledger & Location Accounting
- **Append-Only Ledger:** All physical movements are stored in `stock_transactions` with strongly-typed foreign keys (`goods_receipt_id`, `packing_job_id`, `production_completion_id`, `stock_adjustment_id`), sequential transaction sequence for multi-row request idempotency, and full conversion provenance.
- **Signed Balance Equation:**
  $$\text{Balance}(M, L) = \sum_{\text{dest}=L} \text{quantity} - \sum_{\text{src}=L} \text{quantity}$$
- **Facility Inventory Classification:**
  - $\text{Total Physical Stock} = \sum_{\text{All Leaf Locations}} \text{Balance}(M, L)$
  - $\text{Usable Stock} = \sum_{\text{STORE\_SHELF, SHOP\_FLOOR\_BUFFER}} \text{Balance}(M, L)$
  - $\text{Available-to-Promise (ATP)} = \text{Usable Stock} - \text{Reserved Stock}$
- **Atomic Balance Projections:** `material_location_balances` maintained synchronously by ledger procedures with `CHECK (on_hand_quantity >= 0)`.
- **Quarantine vs Disposal:** `DAMAGE_QUARANTINE` segregates stock on premises; `SCRAP_DISPOSAL` permanently reduces company physical stock.
- **Canonical Unit Preservation:** A material's canonical unit cannot change after transactions, reservations, or released snapshot lines exist. A corrected unit requires a replacement material variant; history and balances are never silently reinterpreted.

### Module 4: Worker Custody & Shop-Floor Material Tracking
- **Internal Custody Transfer:** Handing materials to an operator is an internal transfer (`ISSUE_TO_WORKER`), decreasing store stock and increasing worker custody without affecting total physical stock.
- **End-of-Shift Returns:** Unused items returned to store counter are logged as `RETURN_FROM_WORKER`. Defective items are routed to `DAMAGE_QUARANTINE`.
- **Worker Custody Balance:** Real-time visibility into exact materials held by each operator on the shop floor.

### Module 5: Bill of Materials (BOM) & Immutable Snapshots
- **Reusable Recipe:** Defines packing material quantities required per single unit of finished product.
- **Uniqueness Invariants:**
  - `UNIQUE NULLS NOT DISTINCT (product_id, party_id, packing_variant_name, version_number)` prevents duplicate version numbers.
  - Partial Unique Index `idx_boms_single_active_version` enforces at most one ACTIVE BOM version per recipe key.
- **Party-Specific Overrides:** Allows defining customized packing variants for specific customer accounts.
- **Immutable Job Snapshots & Custom BOMs:** `packing_jobs.master_bom_id` is nullable. A released master-derived job has a selected master BOM and copied snapshot; a released custom job has no master BOM and a complete source-less snapshot. Release is a single validation transaction that rejects empty, duplicate, inactive-material, wrong-unit, or non-positive snapshot lines before reservations and the status change. Master BOM updates never alter previously released jobs.

### Module 6: Daily Planning & Quantity Conservation Accounting
- **Daily Schedule:** Groups multiple packing jobs for an operating date and `shift_code` (e.g., 'GENERAL', 'SHIFT_1', 'SHIFT_2').
- **Repeated Products Support:** The same party and product can appear multiple times in a single day with different quantities, BOM variants, or screw specifications.
- **Five-Variable Quantity Conservation Model:**
  $$\text{current\_revised\_quantity} = \text{completed\_quantity} + \text{pending\_quantity} + \text{cancelled\_quantity}$$
- **Quantity Revision (520 $\to$ 450 Units):** Preserves `original_planned_quantity` (520), updates `current_revised_quantity` (450), logs revision difference (-70) with mandatory reason, and releases unneeded reservations.
- **Completed-Quantity Floor:** A revision below `completed_quantity` is rejected with HTTP 422 and database-procedure validation. Completed production is immutable; handling any authorized overproduction requires a separate audited exception workflow.
- **Safe Job Cancellation:** Preserves completed finished units and past consumption; sets `cancelled_quantity = pending_quantity`, `pending_quantity = 0`, and releases unfulfilled reservations.

### Module 7: Production Completion, Consumption & Variance
- **Partial Completion:** Supports reporting incremental production output (e.g., 530 units completed out of 1,000 planned). Pending units (470) are explicitly tracked.
- **Theoretical BOM Requirements:** Automatically calculated as $\text{Completed Units} \times \text{Snapshot Canonical Qty per Unit}$.
- **Auto-BOM Backflush vs Confirmed Actual:**
  - Backflush deductions are explicitly marked `measurement_method = 'AUTO_BOM_BACKFLUSH'`, `is_estimated = true`. In `material_consumption_records`, `physically_confirmed_quantity = NULL`, `variance_quantity = NULL`, and `variance_status = 'UNVERIFIED'`.
  - Confirmed physical measurements capture verified physical counts (`SCALE_WEIGHED`, `SEALED_BUNDLE`, `MANUALLY_COUNTED`), updating `variance_status` to `'VERIFIED_ZERO'` or `'VARIANCE_RECORDED'`.
- **Variance Tracking:** Automatically records $\text{Variance} = \text{Actual} - \text{Theoretical}$. Flags scrap, breakage, or yield loss.

### Module 8: Daily Closing & Reconciliations
- **Shift-Aware Closing Cardinality & Composite Alignment:** `daily_closings` enforces `FOREIGN KEY (daily_plan_id, shift_code) REFERENCES daily_plans(id, shift_code)`, supporting independent closings for multi-shift plant operations without shift mismatch.
- **Discrepancy Checks:** Flags outstanding worker custody balances and unapproved material variances. Quarantined stock is safely excluded from usable stock.
- **Pending Job Disposition:** Allows Planners to carry forward pending units to tomorrow's plan, reschedule, or cancel remainder.
- **Lockdown:** Closing the day locks the daily plan. Reopening requires `ADMIN` role and mandatory justification.

---

## 4. Non-Functional Requirements & Architectural Constraints

1. **Hardened Security & Column-Level Update Protection:**
   - Database function `public.get_current_user_role()` runs with `SET search_path = ''` and fully qualified objects.
   - Profile `BEFORE UPDATE` trigger `trg_protect_profile_role` blocks non-admin modification of `role` or `is_active` using fail-closed `IS DISTINCT FROM 'ADMIN'`.
   - Comprehensive RLS policies enforce default-deny across all 33 canonical tables.
   - Another user's role or active status changes only through the actual-administrator-JWT `admin_update_profile_access` RPC; it derives the actor from `auth.uid()`, verifies an active database `ADMIN`, and writes an audit row. Direct target-profile updates and client actor IDs are prohibited.
2. **Two-Tier Transactional Idempotency & PostgREST Access Denial:**
   - 100% of state-changing Flask API commands (`POST /api/v1/...`) mandatorily require an `Idempotency-Key` header with bounded format (16–128 ASCII chars `^[A-Za-z0-9_\-\.:]{16,128}$`). Direct PostgREST master CRUD does not accept Flask idempotency headers (`N/A`) and prevents duplicate writes via database primary keys and unique constraints.
   - Request identity is permanently stored in `idempotency_keys` (Table 31), retaining caller `owner_id` (derived from trusted JWT `auth.uid()`), normalized `operation_scope`, canonical payload SHA-256 hash, execution `status`, committed resource references (`resource_type`, `resource_id`), and `operation_completed_at`.
   - Ephemeral HTTP response payloads are stored separately in `idempotency_responses` (Table 32) with a configurable TTL (`expires_at`, default 7 days).
   - Both `idempotency_keys` and `idempotency_responses` strictly deny all direct PostgREST access (`USING (false)` / default-deny); they are exclusively read and mutated by authorized internal transactional database procedures.
   - A background retention pruning worker cleans expired responses (`expires_at < NOW()`) without touching immutable `idempotency_keys` headers, fully resolving foreign-key conflicts with historical stock transactions (`ON DELETE RESTRICT`).
   - Retries with matching owner, scope, and hash before expiration return the cached response; retries after response cache expiration return safe **HTTP 410 `IDEMPOTENCY_RESPONSE_EXPIRED`** with structured resource reference (`resourceReference`: `resourceType`, `resourceId`, `operationCompletedAt`), allowing callers to fetch completed entity details via authorized Flask GET endpoints and guaranteeing that expired operations are never executed a second time.
   - Reusing a key with conflicting owner, scope, or hash returns a generic HTTP 409 `IDEMPOTENCY_KEY_REUSED` without disclosing cached payloads, user identity, or original endpoint details.
   - Supports atomic multi-row stock movements via `(idempotency_key, transaction_sequence)`.
3. **Anti-Cascade Deletion Guard:** All foreign keys referencing production history (`daily_plans`, `packing_jobs`, `snapshots`, `goods_receipts`, `stock_transactions`) utilize `ON DELETE RESTRICT`. Master entities use `is_active = false` soft deactivation.
4. **Transactional Invariant Enforcement:** Multi-row inventory operations execute within atomic PostgreSQL transactions using row locks (`SELECT FOR UPDATE`). Conversion-dependent rows retain rule ID, source/canonical units, factor, direction, exact/estimated classification, and measured/canonical quantities for historical reconstruction.
