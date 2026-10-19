# Phase 1.2 Final Architecture Consistency & Database Readiness Review

**Project:** Packing Material Inventory & BOM Management System  
**Phase:** Phase 1.2 — Final Architecture Consistency & Database Readiness Gate  
**Document Version:** 1.0.0  
**Date:** 2026-10-14  
**Author:** Senior PostgreSQL, Supabase Security & Inventory-Domain Architect  

---

## 1. Executive Summary & Scope Governance

Phase 1.1 established foundational improvements in material categorisation, signed ledger equations, atomic balance projections, quarantine/disposal separation, application-role helpers, anti-cascade protections, and shift closing models. 

Phase 1.2 represents the **final architectural consistency and database readiness review** prior to authoring SQL migrations. A comprehensive, critical re-examination of the entire canonical documentation suite (`docs/`) was executed to identify remaining edge cases, security risks, ambiguous invariants, and cross-document inconsistencies.

### Strict Scope Compliance:
- **Documentation & Architecture Only:** Zero SQL migration scripts were created or executed.
- **Zero Database Mutations:** No live Supabase or PostgreSQL instances were contacted or modified.
- **Zero Code Implementation:** No Flask routes, models, or React UI components were implemented.
- **Zero Package Modifications:** No dependencies were installed, updated, or deployed.
- **Historical Integrity:** `docs/REPOSITORY_AUDIT.md` remains strictly preserved as the immutable Phase 0 baseline.
- **No Premature Runtime Claims:** All consistency validations are structural and architectural; no claims of runtime automated tests having passed are made.

---

## 2. Comprehensive Inconsistency Analysis & Architectural Remedies

### Inconsistency 1: Insecure `search_path` and Vulnerable Profile Role Self-Service Updates
- **Identified Defect:**
  1. The initial Phase 1.1 `public.get_current_user_role()` helper specified `SET search_path = public`. In PostgreSQL, a search path containing `public` without qualification exposes `SECURITY DEFINER` functions to search-path hijacking attacks if malicious users can create objects in `public` or schemas prepended by connection parameters.
  2. Draft RLS policies permitted users to update their own profile row (`id = auth.uid()`). Because row-level security `UPDATE` policies evaluate at the row level, a malicious authenticated user could update their own row and include `"role": "ADMIN"` or `"is_active": true`, achieving self-privilege escalation.
- **Architectural Remedy Selected:**
  1. **Hardened Security Definer Configuration (ADR-012):**
     Configured `SET search_path = ''` (completely empty). All objects within the function are strictly qualified (`public.profiles`, `auth.uid()`). Function privileges are explicitly revoked from `PUBLIC` and `anon`, and granted strictly to `authenticated` and `service_role`.
  2. **Profile Column-Level Update Protection Trigger:**
     Implemented a `BEFORE UPDATE` trigger (`trg_protect_profile_role`) on `public.profiles`. The trigger evaluates `NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active`. If either column is modified, the trigger verifies `public.get_current_user_role() = 'ADMIN'`. If not, it raises SQL exception `42501` (`insufficient_privilege`).
  3. **Backend Authorization Verification:**
     Flask verifies every Supabase Auth JWT cryptographically, extracts `sub` (`auth.uid()`), queries `profiles` via a dedicated connection, and asserts that `role` matches the route requirement and `is_active = true`. Never trusts client-submitted roles or headers.
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-012), `docs/SYSTEM_DESIGN.md` (§6), `docs/TEST_PLAN.md` (Scenario 14), `docs/REQUIREMENT_TRACEABILITY.md` (A.10).
- **Validating Scenario:** Acceptance Scenario 14 in `docs/TEST_PLAN.md`.

---

### Inconsistency 2: Incomplete RLS Matrix with Ambiguous Table Permissions
- **Identified Defect:** The existing documentation contained a high-level RLS summary that covered only 12 core tables while claiming table-by-table coverage. Essential operational entities (such as `material_categories`, `workers`, `bom_lines`, `bom_revision_events`, `packing_job_bom_snapshots`, `packing_job_revisions`, `packing_job_events`, `production_completions`, `material_consumption_records`, `stock_adjustments`, `material_conversions`, `units`, and `idempotency_keys`) lacked explicit CRUD definitions and draft-vs-posted mutation rules.
- **Architectural Remedy Selected:**
  1. **Exhaustive 31-Table RLS Matrix:** Formatted a complete matrix in `docs/SYSTEM_DESIGN.md` (§6.4) explicitly defining `SELECT`, `INSERT`, `UPDATE`, `DELETE`, mutability class (Mutable, Versioned, Immutable Append-Only), and write mechanism (Flask API only vs Direct PostgREST) for every single table.
  2. **Draft vs Posted Enforcement:** Defined immutable state locking across headers: `goods_receipts` (`POSTED`), `daily_plans` (`RELEASED`/`CLOSED`), `boms` (`ACTIVE`/`SUPERSEDED`), and `daily_closings` (`CLOSED`). Once locked, all updates and deletes are rejected at both the RLS policy and trigger levels.
  3. **Default-Deny Architecture:** All direct client writes to financial/inventory tables (`stock_transactions`, `material_location_balances`, `stock_reservations`, `packing_job_bom_snapshots`, `daily_closings`, `idempotency_keys`, `audit_logs`) are strictly forbidden (`DROP POLICY` / zero insert policies for authenticated roles).
- **Files Updated:** `docs/SYSTEM_DESIGN.md` (§6.4), `docs/TEST_PLAN.md` (Scenario 9), `docs/PRD.md` (§6).
- **Validating Scenario:** Acceptance Scenario 9 in `docs/TEST_PLAN.md`.

---

### Inconsistency 3: Ambiguous Packing-Job Cancellation and Quantity Accounting
- **Identified Defect:** The data model conflated original planned quantities with revised targets and did not explicitly track cancelled remainder units. When a job of 520 units was revised to 450 units, 100 units were packed, and the remaining 350 units were cancelled, existing designs risked either overwriting original plans, dropping pending units without an audit trail, or leaving completed production unlinked.
- **Architectural Remedy Selected (ADR-016):**
  1. **Explicit 5-Variable Conservation Invariant:**
     On `packing_jobs`, five distinct non-negative integer columns are defined:
     - `original_planned_quantity` (Unchanging historical baseline: `520`).
     - `current_revised_quantity` (Active planning target: `450`).
     - `completed_quantity` (Confirmed packed finished units: `100`).
     - `pending_quantity` (Remaining units to be packed: `0`).
     - `cancelled_quantity` (Authorized dropped remainder: `350`).
  2. **Database Mathematical Check Constraint:**
     ```sql
     CHECK (current_revised_quantity = completed_quantity + pending_quantity + cancelled_quantity)
     ```
  3. **Revision & Cancellation Protocol:**
     - A revision from 520 to 450 records a row in `packing_job_revisions` (`original_qty = 520`, `revised_qty = 450`, `reason`, `actor`), sets `current_revised_quantity = 450`, adjusts `pending_quantity`, and immediately releases 70 units of reserved material.
     - Cancelling the remainder moves remaining `pending_quantity` (350) into `cancelled_quantity`, sets `pending_quantity = 0`, updates status to `CANCELLED`, releases 350 units of reservations, and records `packing_job_events`. Completed production history (100 units) is 100% preserved.
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-016), `docs/SYSTEM_DESIGN.md` (§3.4, §5.1), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/TEST_PLAN.md` (Scenario 15), `docs/REQUIREMENT_TRACEABILITY.md` (E.4).
- **Validating Scenario:** Acceptance Scenario 15 in `docs/TEST_PLAN.md`.

---

### Inconsistency 4: Conflation of Theoretical BOM Usage, Backflush, and Physical Consumption
- **Identified Defect:** `material_consumption_records.actual_consumed_quantity` was defined as `NOT NULL`, forcing automatic BOM backflush routines to label estimated theoretical deductions as "actual" physical usage. This obscured true shop-floor scrap, made physical count audits impossible, and created misleading variance reports.
- **Architectural Remedy Selected (ADR-014):**
  1. **Three-Tier Consumption Schema in `material_consumption_records`:**
     - `theoretical_quantity` (NUMERIC NOT NULL): Computed from $\text{completed\_units} \times \text{snapshot\_line\_quantity}$.
     - `posted_ledger_quantity` (NUMERIC NOT NULL): Authoritative quantity deducted from the inventory ledger.
     - `physically_confirmed_quantity` (NUMERIC NULL): Nullable; populated *only* when an operator or supervisor physically measures or confirms actual count or weight.
  2. **Metadata & Status Flags:**
     - `is_estimated` (BOOLEAN NOT NULL): `true` for pure backflush deductions; `false` when physically verified.
     - `measurement_method` (TEXT NOT NULL): `AUTO_BOM_BACKFLUSH`, `SCALE_WEIGHED`, `SEALED_BUNDLE`, or `MANUALLY_COUNTED`.
     - `consumption_policy` (TEXT NOT NULL): `AUTO_BOM_BACKFLUSH` or `CONFIRMED_ACTUAL`.
  3. **Variance Invariant:**
     - When `physically_confirmed_quantity IS NOT NULL`, $\text{variance} = \text{physically\_confirmed\_quantity} - \text{theoretical\_quantity}$.
     - When `physically_confirmed_quantity IS NULL`, $\text{variance} = 0$, explicitly reflecting an unverified backflush.
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-014), `docs/SYSTEM_DESIGN.md` (§3.5), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/TEST_PLAN.md` (Scenario 2), `docs/REQUIREMENT_TRACEABILITY.md` (F.4).
- **Validating Scenario:** Acceptance Scenario 2 in `docs/TEST_PLAN.md`.

---

### Inconsistency 5: Incomplete Multi-Location Accounting and Potential Hierarchy Double Counting
- **Identified Defect:** Previous equations accounted only for store shelves, worker custody, and quarantine bays. However, the physical facility model includes receiving bays, line-side shop-floor buffers, and dispatch staging areas. Furthermore, parent-child location trees risked double counting if both a room and its shelves carried balances.
- **Architectural Remedy Selected (ADR-017):**
  1. **Exhaustive 6 Facility Node Types:**
     Defined on `locations.location_type`:
     `STORE_SHELF`, `RECEIVING_BAY`, `SHOP_FLOOR_BUFFER`, `WORKER_CUSTODY`, `DAMAGE_QUARANTINE`, `DISPATCH`.
  2. **Strict Leaf-Node Rollup Rule:**
     Inventory is physically credited and transacted *strictly* on leaf location nodes (`locations.is_leaf = true`). Parent locations (e.g., "Warehouse A", "Room 2") are purely organisational containers that carry zero direct balances, completely eliminating double counting.
  3. **Comprehensive Facility Stock Formulas:**
     $$\text{Total Company Physical Tracked Inventory} = \sum_{L \in \text{All Leaf Nodes}} \text{Balance}(M, L)$$
     $$\text{Usable Stock} = \sum_{L \in (\text{STORE\_SHELF} \cup \text{SHOP\_FLOOR\_BUFFER})} \text{Balance}(M, L)$$
     $$\text{Worker Custody} = \sum_{L \in \text{WORKER\_CUSTODY}} \text{Balance}(M, L)$$
     $$\text{Quarantined Stock} = \sum_{L \in \text{DAMAGE\_QUARANTINE}} \text{Balance}(M, L)$$
     $$\text{Available-to-Promise (ATP)} = \text{Usable Stock} - \text{Active Job Reservations (in canonical units)}$$
  4. **Movement Validation Matrix:**
     Mandated source and destination location validation rules in `docs/SYSTEM_DESIGN.md` (§4.3) prohibiting invalid transfers (e.g., transfers where $\text{source} = \text{destination}$, or disposal originating from usable store shelves).
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-017), `docs/SYSTEM_DESIGN.md` (§4.2, §4.3), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/TEST_PLAN.md` (Scenario 16), `docs/REQUIREMENT_TRACEABILITY.md` (A.11).
- **Validating Scenario:** Acceptance Scenario 16 in `docs/TEST_PLAN.md`.

---

### Inconsistency 6: Conversion Provenance and Cross-Unit Reservation Hazards
- **Identified Defect:** Conversions between packaging units (boxes, bundles) and stock units (KG, PCS) risked ambiguous directionality, loss of raw measurement provenance, and illegal cross-unit summation during job reservations.
- **Architectural Remedy Selected (ADR-005, ADR-014):**
  1. **Canonical Stock Unit Foundation:**
     Every material variant specifies an authoritative `canonical_unit_id` (KG, PCS, or MTR). All ledger transactions, location balances, and job reservations are strictly recorded and aggregated in the canonical unit.
  2. **Unambiguous Conversion Provenance on Inward Receipts:**
     `goods_receipt_lines` captures:
     - `entered_qty` & `entered_unit_id` (Vendor invoice values).
     - `received_qty` & `canonical_unit_id` (Calculated by trusted backend procedure; client-supplied derived values are rejected).
     - `conversion_factor_snapshot` & `conversion_type` (`EXACT` vs `ESTIMATED`).
     - Physical packaging auxiliary attributes: `box_count`, `weight_kg`, `pcs_count`.
  3. **Frozen BOM Snapshots:**
     When a daily plan is released, `packing_job_bom_snapshot_lines` calculates and freezes `quantity_per_finished_unit` strictly in the material's canonical unit. A future modification to the conversion master table has zero retroactive impact on released jobs or historical ledger balances.
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-005, ADR-014), `docs/SYSTEM_DESIGN.md` (§3.1, §3.3, §4.1), `docs/API_CONTRACT.yaml`, `docs/TEST_PLAN.md` (Scenario 1).
- **Validating Scenario:** Acceptance Scenario 1 in `docs/TEST_PLAN.md`.

---

### Inconsistency 7: Cascading Foreign Key Deletions, Polymorphic Audit References, and Duplicate Posts
- **Identified Defect:**
  1. `bom_lines` had an unrestricted `ON DELETE CASCADE` from `boms`. If an administrator deleted an active or historical master BOM, its entire recipe line history would be destroyed.
  2. `stock_transactions` used polymorphic fields (`reference_entity_type` and `reference_entity_id`), which cannot enforce foreign key constraints, leaving the ledger vulnerable to orphaned references.
  3. Network timeouts during stock posting or job completion could cause duplicate transactions upon client retry without database-backed idempotency.
- **Architectural Remedy Selected (ADR-013, ADR-018):**
  1. **BOM Versioning & Conditional Line Deletion:**
     Master BOMs are immutable once released (`ACTIVE` / `SUPERSEDED`). Deletion is permitted *only* for draft BOMs (`status = 'DRAFT'`) that have never been referenced by any job snapshot. Once referenced, `ON DELETE RESTRICT` is enforced.
  2. **Strongly-Typed Explicit Audit Foreign Keys:**
     Replaced polymorphic fields on `stock_transactions` with dedicated nullable foreign keys:
     - `goods_receipt_id` REFERENCES `goods_receipts(id) ON DELETE RESTRICT`
     - `packing_job_id` REFERENCES `packing_jobs(id) ON DELETE RESTRICT`
     - `production_completion_id` REFERENCES `production_completions(id) ON DELETE RESTRICT`
     - `stock_adjustment_id` REFERENCES `stock_adjustments(id) ON DELETE RESTRICT`
     - Check constraint: `CHECK (num_nonnulls(goods_receipt_id, packing_job_id, production_completion_id, stock_adjustment_id) <= 1)`.
  3. **Database-Backed Transactional Idempotency (`idempotency_keys`):**
     Introduced a dedicated table `idempotency_keys` (`key` TEXT PRIMARY KEY, `user_id` UUID, `request_hash` TEXT, `response_status` INT, `response_payload` JSONB, `status` TEXT, `created_at` TIMESTAMPTZ, `locked_at` TIMESTAMPTZ).
     Stock posting procedures acquire a row lock on the key. If an identical request is re-sent, the stored HTTP 201 response is replayed without executing duplicate ledger movements. If payload hash differs, HTTP 409 Conflict is returned.
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-013, ADR-018), `docs/SYSTEM_DESIGN.md` (§3.2, §3.5), `docs/API_CONTRACT.yaml`, `docs/TEST_PLAN.md` (Scenario 13), `docs/REQUIREMENT_TRACEABILITY.md` (F.5).
- **Validating Scenario:** Acceptance Scenario 13 in `docs/TEST_PLAN.md`.

---

### Inconsistency 8: Status Models, Uniqueness Constraints, and Cardinality Misalignments
- **Identified Defect:**
  1. Generic Master BOMs (where `party_id` is NULL) were vulnerable to duplicate definitions because standard PostgreSQL `UNIQUE(product_id, party_id, packing_variant_name, version_number)` treats NULLs as distinct.
  2. Daily closing cardinality lacked a formal constraint linking it to the specific daily plan and shift model.
  3. Fully customized packing jobs risked bypassing frozen BOM snapshot creation.
- **Architectural Remedy Selected (ADR-015):**
  1. **Master BOM Uniqueness with `NULLS NOT DISTINCT`:**
     Applied PostgreSQL 15+ syntax:
     ```sql
     UNIQUE NULLS NOT DISTINCT (product_id, party_id, packing_variant_name, version_number)
     ```
     Guarantees that generic master BOMs (`party_id IS NULL`) cannot be duplicated.
  2. **Shift Closing 1:1 Invariant:**
     Enforced `UNIQUE(daily_plan_id)` on `daily_closings`. Because each `daily_plans` record represents an explicit operational shift on a specific calendar date (`plan_date`, `shift_code`), exactly one closing record is generated per plan, eliminating duplicate closures.
  3. **Mandatory BOM Snapshots for Customized Jobs:**
     Every released packing job is required to link to a `packing_job_bom_snapshots` header. For ad-hoc jobs, the snapshot is created with `is_customized = true` and `customization_notes` populated, ensuring 100% of jobs have immutable frozen line items.
- **Files Updated:** `docs/ARCHITECTURE_DECISIONS.md` (ADR-015), `docs/SYSTEM_DESIGN.md` (§3.3, §3.4, §3.6), `docs/TEST_PLAN.md` (Scenario 3, Scenario 8, Scenario 10).
- **Validating Scenarios:** Acceptance Scenarios 3, 8, and 10 in `docs/TEST_PLAN.md`.

---

## 3. Cross-Document Consistency Matrix

The canonical documentation suite was comprehensively synchronized to ensure 100% agreement on schema definitions, table names, permission rules, quantity models, and terminology:

| Architectural Concept | `SYSTEM_DESIGN.md` | `ARCHITECTURE_DECISIONS.md` | `API_CONTRACT.yaml` | `PRD.md` & `MRD.md` | `TEST_PLAN.md` | `IMPLEMENTATION_PLAN.md` | `UI_UX_WALKTHROUGH.md` | `REQUIREMENT_TRACEABILITY.md` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Total Relational Tables** | 31 Tables | ADR-009, 010, 018 | Full Schema Types | 31 Tables | 16 Scenarios | Phase 2 Scope | 13 Screens | 35 Mapped Req |
| **Role Helper & Profile Trigger** | §6.1, §6.2 | ADR-012 | Error Models | §6 RBAC | Scenario 14 | Phase 2 Tasks | Screen 14 Specs | Req A.10 |
| **Complete RLS Matrix (31 Tables)** | §6.4 | ADR-007, 012 | Auth Bearer | §6 Matrix | Scenario 9 | Phase 2 Tasks | RBAC Labels | Req A.9 |
| **5-Variable Quantity Conservation** | §3.4, §5.1 | ADR-016 | `QuantityBreakdown` | §3 Invariants | Scenario 15 | Phase 6 Tasks | Screen 11 Card | Req E.4 |
| **Three-Tier Consumption Schema** | §3.5 | ADR-014 | `ConsumptionItem` | §3 Modules | Scenario 2 | Phase 7 Tasks | Screen 12 Form | Req F.4 |
| **6 Facility Location Node Types** | §4.2, §4.3 | ADR-017 | `locationType` Enum | §3 Modules | Scenario 16 | Phase 5 Tasks | Screen 5 Tree | Req A.11 |
| **Database Transactional Idempotency**| §3.5, `idempotency_keys` | ADR-018 | `Idempotency-Key` | §4 NFRs | Scenario 13 | Phase 3 Tasks | Network Replay | Req F.5 |
| **Strongly-Typed Stock FKs** | §3.5 | ADR-013, 018 | Ledger References | §3 Invariants | Scenario 13 | Phase 2 Tasks | Ledger Drilldown | Req F.3 |
| **BOM `NULLS NOT DISTINCT`** | §3.3 | ADR-015 | BOM Endpoints | §3 Modules | Scenario 8 | Phase 2 Tasks | Screen 9 Uniqueness | Req D.1 |
| **Shift Closing 1:1 Invariant** | §3.6 | ADR-015 | Closing Endpoints | §3 Modules | Scenario 10 | Phase 7 Tasks | Screen 13 Summary | Req H.1 |

---

## 4. Operational Defaults & Explicit Configuration Registry

To avoid making unverified business assumptions while ensuring immediate implementation readiness, the following operational parameters are formally catalogued:

| Parameter / Workflow | Architectural Default | Configurable Scope & Mechanism | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **Canonical Inventory Unit** | Configured per material variant (`KG`, `PCS`, `MTR`). Flexible rolls default to `KG`; rigid cartons default to `PCS`. | Selected on variant creation in `materials.canonical_unit_id`. Never hardcoded globally. | `SYSTEM_DESIGN.md` §3.1, `OPEN_DECISIONS.md` §8 |
| **Bundle & Packaging Rules** | Auxiliary entry permitted on inward receipts (`box_count`, `weight_kg`, `pcs_count`). Multiples are informational. | Configurable per material or category via `materials.additional_specs` JSON. No global forced rounding. | `SYSTEM_DESIGN.md` §3.1, `OPEN_DECISIONS.md` §8 |
| **Production Consumption Mode** | `AUTO_BOM_BACKFLUSH` is default. Operator may override with confirmed physical entry. | Configurable per product, material category, or shift in system settings. | `SYSTEM_DESIGN.md` §3.5, `OPEN_DECISIONS.md` §5 |
| **Inward Receipt without PO** | Supported. `purchase_order_id` is nullable on `goods_receipts`. | Permitted by default for immediate stock intake; supervisor approval toggleable. | `SYSTEM_DESIGN.md` §3.2, `OPEN_DECISIONS.md` §1 |
| **Shift Structure & Closing** | Supports 1, 2, or 3 shifts per day via `daily_plans.shift_code`. | Cardinality is strictly 1:1 between `daily_plans` and `daily_closings` (`UNIQUE(daily_plan_id)`). | `SYSTEM_DESIGN.md` §3.6, `OPEN_DECISIONS.md` §7 |
| **Pending Job Rollover** | Manual Planner confirmation required at shift closing (`CARRY_FORWARD`, `CANCEL`, `RESCHEDULE`). | Configurable default action in daily closing console. Never silently rolls over. | `SYSTEM_DESIGN.md` §5.1, `OPEN_DECISIONS.md` §7 |

---

## 5. Phase 2 Database Readiness Sign-Off Gate

All prerequisite architectural conditions for entering **Phase 2 (Supabase Schema Migrations, Invariant Constraints & Row Level Security)** have been rigorously audited and certified:

- [x] **Function Security & Role Protection:** `public.get_current_user_role()` search path is secured (`SET search_path = ''`), privileges revoked from `PUBLIC`, and profile update trigger (`trg_protect_profile_role`) explicitly specified.
- [x] **Complete RLS Matrix:** Exhaustive, table-by-table RLS matrix covering all 31 tables with draft-vs-posted permission gating and default-deny policies.
- [x] **Mathematical Quantity Conservation:** 5-variable quantity conservation invariant (`current = completed + pending + cancelled`) specified with SQL check constraints and immutable revision logging.
- [x] **Three-Tier Consumption Separation:** Clear distinction between theoretical BOM requirement, auto-BOM backflush deduction, and nullable physically confirmed actual usage.
- [x] **Complete Multi-Location Accounting:** All 6 facility node types modeled; leaf-node rollup formulas established; movement validation matrix finalized.
- [x] **Unambiguous Conversion Provenance:** Inward receipt dual-unit capture specified; BOM snapshot requirements frozen in canonical units; cross-unit reservation hazards eliminated.
- [x] **Anti-Cascade Integrity & Idempotency:** Historical production protected with `ON DELETE RESTRICT`; polymorphic ledger fields replaced with strongly-typed FKs; database-backed `idempotency_keys` table designed.
- [x] **Status & Cardinality Alignment:** BOM uniqueness with `NULLS NOT DISTINCT`, shift closing 1:1 cardinality (`UNIQUE(daily_plan_id)`), and mandatory snapshots for customized jobs reconciled.
- [x] **Configuration Registry:** Flexible units, bundle rules, backflush defaults, and pending job rollover behaviors formally documented without arbitrary assumptions.
- [x] **Cross-Document Harmonization:** 100% agreement across System Design, Architecture Decisions, API Contract, PRD, MRD, Test Plan, Implementation Plan, UI/UX Walkthrough, and Requirement Traceability Matrix.

---

## 6. Conclusion & Next Steps

The architectural specification and database design are **certified ready for database migration authoring**.

In accordance with the strict scope constraints of Phase 1.2:
- **No SQL migration scripts have been created or run.**
- **No live database has been contacted or modified.**
- **Implementation remains gated pending formal user review and authorization to proceed to Phase 2.**
