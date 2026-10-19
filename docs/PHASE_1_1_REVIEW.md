# Phase 1.1 Critical Architecture Corrections Review & Audit

**Project:** Packing Material Inventory & BOM Management System  
**Phase:** Phase 1.1 — Critical Architecture Corrections  
**Document Version:** 1.0.0  
**Date:** 2026-10-14  
**Author:** Senior PostgreSQL, Supabase Security & Inventory-Domain Architect  

---

## 1. Executive Summary

During the Phase 1.1 architecture review, nine critical design inconsistencies and potential failure modes were identified in the initial draft specifications. These issues spanned the material category model, stock ledger balance math, inventory status partitioning (quarantine vs disposal), Row Level Security (RLS) role resolution, cascading foreign key deletions, theoretical backflush mislabeling, conversion provenance, inward receipt field ambiguity, and multi-shift closing cardinality.

All nine areas have been systematically corrected across the entire canonical documentation suite (`docs/`). This document provides the formal audit trail of each inconsistency identified, the architectural remedy selected, the specific files updated, the technical rationale, the validating acceptance test scenario, and the remaining operational decisions awaiting user input.

---

## 2. Inconsistency Analysis & Correction Matrix

### Inconsistency 1: Hardcoded Material Categories vs Dynamic Admin Extensibility
- **Identified Defect:** The initial design utilized an inline database constraint `CHECK (material_type IN ('CARTON', 'POLY_BAG', 'SCREW', 'OTHER'))`. This directly violated the business requirement that administrators must be able to add new material categories (e.g., corner protectors, bubble bags, desiccants) without modifying application source code or executing database schema migrations.
- **Correction Selected:**
  1. Created a dedicated relational table: `material_categories` (`id` UUID, `category_code` TEXT UNIQUE, `category_name` TEXT, `description` TEXT, `is_active` BOOLEAN).
  2. Changed `materials.category_id` to reference `material_categories(id)` via foreign key with `ON DELETE RESTRICT`.
  3. Retained typed physical dimensions (`thickness_gauge`, `width_mm`, `length_mm`, `height_mm`, `diameter_thread_spec`) on `materials`.
  4. Added an extensible `additional_specs` (`jsonb`) column with `CHECK (jsonb_typeof(additional_specs) = 'object')` to store category-specific attributes (e.g., ply, burst strength, adhesive type) without future schema migrations.
- **Files Changed:** `docs/SYSTEM_DESIGN.md`, `docs/ARCHITECTURE_DECISIONS.md` (ADR-009), `docs/OPEN_DECISIONS.md` (Decision 8), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/MRD.md`, `docs/PRD.md`, `docs/REQUIREMENT_TRACEABILITY.md`, `docs/IMPLEMENTATION_PLAN.md`.
- **Reason for Decision:** Provides true operational extensibility while maintaining relational integrity and indexing for common dimensional attributes.
- **Validating Acceptance Test:** [Acceptance Scenario 11 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-11-dynamic-admin-creation-of-material-categories--extensible-specs-added-in-phase-11).

---

### Inconsistency 2: Flawed Ledger Balance Aggregation (`SUM(quantity)`)
- **Identified Defect:** The initial specification proposed calculating location stock balances by running `SUM(quantity)` grouped by material and location on `stock_transactions`. This is mathematically invalid because an inventory movement has positive magnitude while simultaneously decreasing the source location and increasing the destination location.
- **Correction Selected:**
  1. Formally defined the exact **Signed Ledger Aggregation Formula**:
     $$\text{Balance}(M, L) = \sum_{\text{dest}=L} \text{quantity} - \sum_{\text{src}=L} \text{quantity}$$
  2. Replaced simple summation with explicit SQL aggregation:
     ```sql
     SELECT 
       material_id,
       COALESCE(SUM(CASE WHEN destination_location_id = :location_id THEN quantity ELSE 0 END), 0) -
       COALESCE(SUM(CASE WHEN source_location_id = :location_id THEN quantity ELSE 0 END), 0) AS balance
     FROM stock_transactions
     WHERE material_id = :material_id
       AND (:location_id IN (source_location_id, destination_location_id))
     GROUP BY material_id;
     ```
  3. Introduced the synchronous read-model table `material_location_balances(material_id, location_id, on_hand_quantity, updated_at)` maintained atomically by transaction procedures with check constraint `CHECK (on_hand_quantity >= 0)`.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§4), `docs/ARCHITECTURE_DECISIONS.md` (ADR-002, ADR-010), `docs/REQUIREMENT_TRACEABILITY.md`, `docs/TEST_PLAN.md`, `docs/IMPLEMENTATION_PLAN.md`.
- **Reason for Decision:** Guarantees mathematical accuracy across all movement types and eliminates $O(N)$ table scans for live balance checks.
- **Validating Acceptance Test:** [Acceptance Scenario 6 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-6-authoritative-stock-ledger-balance-invariants).

---

### Inconsistency 3: Conflation of Damage Quarantine with Permanent Scrap Disposal
- **Identified Defect:** The initial design used a single `DAMAGE_WRITEOFF` movement type that immediately depleted physical inventory when defect was discovered. This conflated moving damaged materials to a quarantine bay with physically discarding or disposing of them. Damaged stock remains company property on the warehouse premises until formally condemned.
- **Correction Selected:**
  1. Replaced single damage write-off with two distinct movement types:
     - `DAMAGE_QUARANTINE`: Moves material from store shelf or worker custody to a `DAMAGE_QUARANTINE` location. Decreases usable store stock; increases quarantine balance. **Total physical company stock remains unchanged.**
     - `SCRAP_DISPOSAL`: Writes off condemned material from a quarantine location. Decreases quarantine balance; **permanently decreases total physical company stock**.
  2. Defined explicit inventory classifications:
     $$\text{Total Physical Stock} = \text{Usable Store Stock} + \text{Worker Custody} + \text{Quarantined Stock}$$
     $$\text{Available-to-Promise (ATP)} = \text{Usable Store Stock} - \text{Reserved Stock}$$
  3. Quarantined stock is strictly excluded from Available-to-Promise and cannot be reserved by packing jobs.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§4), `docs/ARCHITECTURE_DECISIONS.md` (ADR-011), `docs/OPEN_DECISIONS.md` (Decision 7), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/MRD.md`, `docs/PRD.md`, `docs/TEST_PLAN.md`.
- **Reason for Decision:** Adheres to industrial ERP accounting standards, prevents fictitious inventory loss, and supports scrap recovery/vendor chargeback audits.
- **Validating Acceptance Test:** [Acceptance Scenario 12 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-12-segregation-of-damage-quarantine-vs-scrap-disposal-added-in-phase-11).

---

### Inconsistency 4: Insecure RLS Role Verification via Connection Claim (`auth.jwt() ->> 'role'`)
- **Identified Defect:** Draft RLS policies referenced `auth.jwt() ->> 'role' IN ('ADMIN', 'STOREKEEPER')`. In Supabase, the standard `role` claim in the JWT identifies the PostgreSQL connection role (almost always `'authenticated'`), NOT the user's business application role stored in `profiles.role`. This created a critical vulnerability resulting in either complete authorization failure or unauthorized permission escalation.
- **Correction Selected:**
  1. Implemented a trusted PostgreSQL `SECURITY DEFINER` helper function:
     ```sql
     CREATE OR REPLACE FUNCTION public.get_current_user_role()
     RETURNS text
     LANGUAGE sql
     STABLE
     SECURITY DEFINER
     SET search_path = public
     AS $$
       SELECT role FROM public.profiles 
       WHERE id = auth.uid() AND is_active = true;
     $$;
     ```
  2. Updated all RLS policies to evaluate `public.get_current_user_role() IN (...)`.
  3. Enforced that Flask verifies the JWT signature with `PyJWT` and confirms user role and active status against `profiles` on every authenticated request.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§6), `docs/ARCHITECTURE_DECISIONS.md` (ADR-012), `docs/TEST_PLAN.md`, `docs/PRD.md`.
- **Reason for Decision:** Eliminates token desynchronization risks, guarantees real-time revocation when a profile is deactivated, and prevents reliance on user-editable metadata.
- **Validating Acceptance Test:** [Acceptance Scenario 9 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-9-row-level-security-rls--trusted-role-resolution).

---

### Inconsistency 5: Dangerous Cascading Deletions on Historical Records (`ON DELETE CASCADE`)
- **Identified Defect:** Several operational headers (e.g., `daily_plans`, `purchase_orders`, `goods_receipts`) were defined with `ON DELETE CASCADE` to child jobs, snapshots, and receipt lines. If a user accidentally or maliciously deleted a daily plan, all associated packing jobs, frozen BOM snapshots, production completion records, and audit links would be irreversibly deleted.
- **Correction Selected:**
  1. Enforced `ON DELETE RESTRICT` on all production history foreign keys:
     - `packing_jobs` $\to$ `daily_plans` (`ON DELETE RESTRICT`)
     - `packing_job_bom_snapshots` $\to$ `packing_jobs` (`ON DELETE RESTRICT`)
     - `production_completions` $\to$ `packing_jobs` (`ON DELETE RESTRICT`)
     - `goods_receipt_lines` $\to$ `goods_receipts` (`ON DELETE RESTRICT`)
     - `stock_transactions` $\to$ all foreign keys (`ON DELETE RESTRICT`)
  2. Draft records may be deleted only if zero released jobs or posted transactions reference them.
  3. Master entities (`parties`, `products`, `materials`, `material_categories`, `vendors`, `locations`, `workers`) enforce soft deactivation (`is_active = false`) instead of hard deletion.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§3), `docs/ARCHITECTURE_DECISIONS.md` (ADR-013), `docs/TEST_PLAN.md`, `docs/PRD.md`, `docs/IMPLEMENTATION_PLAN.md`.
- **Reason for Decision:** Guarantees strict compliance and prevents catastrophic loss of manufacturing history.
- **Validating Acceptance Test:** [Acceptance Scenario 13 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-13-anti-cascade-referential-deletion-protection-added-in-phase-11).

---

### Inconsistency 6: Conflating Theoretical BOM Calculations with Physically Measured Consumption
- **Identified Defect:** The draft specification lacked clarity on how theoretical BOM consumption was recorded, risking labeling theoretical backflushed quantities (e.g., 530 finished units $\times$ 1 poly bag = 530 bags) as though they were physically measured or scale-weighed on the shop floor.
- **Correction Selected:**
  1. Established three distinct concepts:
     - **Theoretical BOM Requirement:** Mathematical calculation ($\text{completed\_units} \times \text{snapshot\_qty}$).
     - **Auto-BOM Backflush Deduction:** Automatic ledger deduction tagged `measurement_method = 'AUTO_BOM_BACKFLUSH'` and `is_estimated = true`. Displayed in UI as a purple `Theoretical Backflush` pill.
     - **Confirmed Physical Consumption:** Explicit physical count entered by operator with `is_physically_measured = true` and empirical method (`SCALE_WEIGHED`, `SEALED_BUNDLE`, `MANUALLY_COUNTED`).
  2. Shift close reconciles theoretical backflush against actual remaining worker custody. Any difference is highlighted as an explicit variance.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§5), `docs/MRD.md` (§5), `docs/PRD.md` (Module 7), `docs/UI_UX_WALKTHROUGH.md`, `docs/OPEN_DECISIONS.md` (Decision 3), `docs/TEST_PLAN.md`.
- **Reason for Decision:** Adheres to the core ground rule that software must never invent or mislabel physical measurements.
- **Validating Acceptance Test:** [Acceptance Scenario 2 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-2-bom-theoretical-scaling-for-partial-production).

---

### Inconsistency 7: Lack of Frozen Conversion Provenance on Historical Transactions
- **Identified Defect:** The initial ledger recorded only canonical quantities without capturing the entered measurement or freezing the conversion factor at posting time. If a calibration factor was updated in `material_conversions` later (e.g., from 100 PCS/KG to 105 PCS/KG), historical transactions and active BOM snapshots were at risk of retroactive distortion.
- **Correction Selected:**
  1. Added explicit provenance columns to `stock_transactions`: `entered_quantity`, `entered_unit_id`, `measurement_method`, `conversion_factor`, and `is_estimated`.
  2. Added `conversion_factor_frozen` to `packing_job_bom_snapshot_lines`.
  3. Once posted or released, conversion factors are immutable. Future edits to master conversion formulas affect only future transactions.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§3, §4), `docs/ARCHITECTURE_DECISIONS.md` (ADR-014), `docs/OPEN_DECISIONS.md` (Decision 1), `docs/API_CONTRACT.yaml`, `docs/MRD.md`, `docs/TEST_PLAN.md`.
- **Reason for Decision:** Guarantees total historical reproducibility and audit compliance.
- **Validating Acceptance Test:** [Acceptance Scenario 1 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-1-dual-unit--estimated-conversion-labeling).

---

### Inconsistency 8: Ambiguity in Inward Goods Receipt Quantities and Dates
- **Identified Defect:** `goods_receipt_lines` included multiple quantity fields (`received_qty`, `rejected_qty`, `accepted_qty`, `box_count`, `weight_kg`, `pcs_count`, `canonical_quantity`) without a clear hierarchy defining which field was authoritative for stock posting. Date handling also conflated purchase date, invoice date, and arrival date.
- **Correction Selected:**
  1. Defined the explicit field hierarchy:
     - `entered_qty` & `entered_unit_id`: User's raw physical input.
     - `received_qty`: Gross delivered quantity in canonical unit.
     - `rejected_qty`: Defective quantity rejected at receiving dock.
     - `accepted_qty`: Net acceptable quantity: $\text{accepted} = \text{received} - \text{rejected}$ (enforced via DB check constraint).
     - `canonical_quantity`: The authoritative value posted to `stock_transactions` (equals `accepted_qty`).
     - `box_count`, `weight_kg`, `pcs_count`: Auxiliary physical packaging metadata.
  2. Explicitly separated business dates: `purchase_orders.order_date` (purchase date), `goods_receipts.invoice_date` (vendor invoice date), and `goods_receipts.received_date` (dock delivery date).
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§3), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/PRD.md`, `docs/TEST_PLAN.md`.
- **Reason for Decision:** Eliminates contradictory or ambiguous inventory postings.
- **Validating Acceptance Test:** [Acceptance Scenario 1 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-1-dual-unit--estimated-conversion-labeling).

---

### Inconsistency 9: Nullable Party Uniqueness in BOMs & Multi-Shift Closing Cardinality
- **Identified Defect:** 
  1. The constraint `UNIQUE(product_id, party_id, packing_variant_name, version_number)` failed on generic master BOMs because in standard PostgreSQL `NULL != NULL`, allowing multiple duplicate generic versions where `party_id IS NULL`.
  2. The constraint `UNIQUE(closing_date)` on `daily_closings` assumed only one close could ever occur per calendar date, which breaks factories operating multiple shifts or distinct scheduling batches.
- **Correction Selected:**
  1. Enforced BOM uniqueness via `UNIQUE NULLS NOT DISTINCT (product_id, party_id, packing_variant_name, version_number)` in PostgreSQL 15+ (with fallback partial indexes `WHERE party_id IS NULL` and `WHERE party_id IS NOT NULL`).
  2. Changed daily closing cardinality to `UNIQUE(daily_plan_id)`. Added `shift_code` (e.g., 'GENERAL', 'SHIFT_1', 'SHIFT_2') to `daily_plans` and `daily_closings`. Each shift/plan can close independently on the same calendar date.
- **Files Changed:** `docs/SYSTEM_DESIGN.md` (§3), `docs/ARCHITECTURE_DECISIONS.md` (ADR-015), `docs/OPEN_DECISIONS.md` (Decision 7), `docs/API_CONTRACT.yaml`, `docs/UI_UX_WALKTHROUGH.md`, `docs/MRD.md`, `docs/PRD.md`.
- **Reason for Decision:** Fixes PostgreSQL NULL uniqueness semantics and supports real-world multi-shift plant operations.
- **Validating Acceptance Test:** [Acceptance Scenario 8 & 10 in `TEST_PLAN.md`](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md#acceptance-scenario-8-historical-bom-snapshot-immutability).

---

## 3. Comprehensive File Modification Log

| File Path | Status | Key Corrections Applied |
| :--- | :--- | :--- |
| [ARCHITECTURE_DECISIONS.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/ARCHITECTURE_DECISIONS.md) | Updated | Added ADR-009 through ADR-015; updated ADR-002 signed ledger math. |
| [SYSTEM_DESIGN.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/SYSTEM_DESIGN.md) | Updated | Added `material_categories` (30 tables total); signed ledger aggregation equations; atomic `material_location_balances` projection; quarantine vs disposal movements; trusted `get_current_user_role()` RLS helper; `ON DELETE RESTRICT` anti-cascade guards; `NULLS NOT DISTINCT` BOM uniqueness; shift-aware closing. |
| [OPEN_DECISIONS.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/OPEN_DECISIONS.md) | Updated | Documented conversion provenance; loose item handling; multi-shift closing; extensible material categories & JSONB specs. |
| [API_CONTRACT.yaml](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/API_CONTRACT.yaml) | Updated | Added `/material-categories` endpoints; updated material schemas with `categoryId` and `additionalSpecs`; added `/stock/damage-quarantine` and `/stock/scrap-disposal`; updated inward receipt lines schema; added `shiftCode`. |
| [MRD.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/MRD.md) | Updated | Integrated data-driven categories; typed dimensions & JSONB specs; conversion provenance; loose stock rules; quarantine vs disposal. |
| [PRD.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/PRD.md) | Updated | Aligned all 8 modules with Phase 1.1 corrections; updated non-functional anti-cascade deletion and RLS security rules. |
| [UI_UX_WALKTHROUGH.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/UI_UX_WALKTHROUGH.md) | Updated | Added Material Categories screen; updated Materials screen with category picker and JSON editor; added Damage Quarantine & Scrap Disposal screen; updated Shift selector; updated walkthrough scenarios. |
| [TEST_PLAN.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/TEST_PLAN.md) | Updated | Added Acceptance Scenarios 11, 12, and 13 verifying category creation, quarantine vs disposal, and anti-cascade foreign keys. |
| [REQUIREMENT_TRACEABILITY.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/REQUIREMENT_TRACEABILITY.md) | Updated | Remapped requirements A through H to new tables, ADRs, endpoints, and test scenarios. |
| [IMPLEMENTATION_PLAN.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/IMPLEMENTATION_PLAN.md) | Updated | Incorporated Phase 1.1 architectural corrections into Phase 2 database migrations and Phase 4/5/6/7 backend phases. |
| [REPOSITORY_AUDIT.md](file:///c:/Users/singh/Videos/PACKING%20STCOK%20ERP/docs/REPOSITORY_AUDIT.md) | Preserved | Kept completely intact as the historical Phase 0 baseline audit record. |

---

## 4. Remaining Decisions Awaiting User Input

All nine architectural inconsistencies have been resolved with safe, production-grade defaults. The following operational preferences are fully configurable via settings and await user confirmation:

1. **Flexible Packaging Canonical Unit:** Recommended default is `KG` with calibrated `≈ PCS` secondary display. (User may choose canonical `PCS` if bags are purchased strictly by piece count).
2. **Consumption Policy Default:** Recommended default is `AUTO_BOM_THEORETICAL` with end-of-shift worker custody return and variance audit. (User may switch to `MANDATORY_ACTUAL_ENTRY` if line operators must key in physical usage).
3. **Emergency Inward Receipts without PO:** Recommended default allows direct inward receipts with `po_id = NULL` for emergency cash purchases. (User may require mandatory POs).
4. **Pending Job Rollover Mode:** Recommended default requires manual confirmation on the Daily Close screen. (User may configure automatic next-day draft rollover).
5. **Multi-Shift Plant Scheduling:** The system now natively supports multiple shifts per date via `shift_code`. (User can confirm whether single-shift or multi-shift is standard).

---

## 5. Phase 1.1 Conclusion & Implementation Readiness

With Phase 1.1 complete, the technical blueprint is mathematically explicit, security-hardened, and fully aligned with industrial manufacturing requirements.

**Next Milestone:** Phase 2 — Supabase Schema Migrations, Invariant Constraints & Row Level Security (RLS). Awaiting user approval to proceed.
