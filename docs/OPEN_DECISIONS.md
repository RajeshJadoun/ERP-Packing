# Open Operational Decisions & Configurable Policy Framework

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## 1. Document Authority & Archival Status Notice

> [!IMPORTANT]
> **Canonical Document Status:** The root `/docs` directory is the sole, authoritative technical blueprint and specification for the system.
> Any other duplicate files or legacy design packages—specifically `Packing_Inventory_Codex_Package/` and `Packing_Inventory_System_Plan.docx` in the repository root—are designated as **archival, non-canonical references**. They are preserved strictly for historical audit tracing and must never override or contradict the specifications in `/docs`.
> The historical baseline audit `docs/REPOSITORY_AUDIT.md` (Phase 0) remains permanently intact.

In industrial inventory operations, rigid hardcoded assumptions create friction between software and physical factory workflows. Where business operational policies have multiple viable paths, the system **must not invent unverified facts**. 

Instead, this document captures each operational policy, analyzes its trade-offs, specifies a **safe recommended default**, and outlines the **configurable settings design** so that policies can be adjusted without rewriting core business logic.

---

## 2. Evaluation of Core Operational Decisions

### Decision 1: Canonical Stock Unit Selection per Material Variant
- **Current Requirement:** Materials like poly bags, foam, bubble wrap, and cartons are purchased and consumed in varying units. Conversions can be exact or estimated. Never sum KG and PCS together without conversion.
- **Unresolved Question:** Should flexible packaging always use KG as its canonical stock unit?
- **Configurable Architecture & Recommended Default:** 
  - **No Global Hardcoding:** Canonical unit is strictly configured **per material variant** (`materials.canonical_unit_id`).
  - **Recommended Default:**
    - Bulk flexible packaging (film rolls, continuous bubble wrap, extruded foam rolls): Canonical Unit = **KG**.
    - Pre-formed, counted bags (e.g., zip-lock bags, pre-cut foam pockets, cartons, fasteners): Canonical Unit = **PCS**.
  - Where a weighed material (KG) is consumed per unit (PCS), the conversion rule in `material_conversions` is tagged `ESTIMATED` with an audited calibration factor and `provenance_note`.
  - Every transaction and frozen BOM snapshot freezes the exact conversion factor used at posting time, guaranteeing that future calibration changes do not alter historical records.
- **Impact of Decision:** Accommodates supplier packaging diversity without distorting ledger precision.
- **Configurable Setting:** `materials.canonical_unit_id` and `material_conversions.conversion_type` (`EXACT` vs `ESTIMATED`).
- **Immutability Guard:** `canonical_unit_id` is configurable only before inventory activity. Once a transaction, reservation, or released snapshot exists, a database trigger rejects changes; the approved correction path is a replacement material variant, not reinterpretation of history.

---

### Decision 2: Loose Material Handling & Bundle Rules per Category/Material
- **Current Requirement:** The software must not pretend to know how many loose items a worker took without a measurement, weighing, or fixed-bundle process.
- **Unresolved Question:** Does the shop floor globally enforce scale weighing, sealed manufacturer bundles, or manual counts?
- **Configurable Architecture & Recommended Default:**
  - **Configurable per Material / Category:**
    - Fasteners / Screws: Configured to support `SEALED_BUNDLE` (e.g., standard bags of 100/500 PCS) or `SCALE_WEIGHED` (for counting scales).
    - Poly bags / Cartons: Configured to support `SEALED_BUNDLE` (packs of 50/100) or `MANUALLY_COUNTED`.
  - Every issuance records the explicit `measurement_method` (`SCALE_WEIGHED`, `SEALED_BUNDLE`, `MANUALLY_COUNTED`, `AUTO_BOM_BACKFLUSH`).
- **Impact of Decision:** Allows different shop-floor areas to apply appropriate counting methods without arbitrary global constraints.
- **Configurable Setting:** `materials.enforce_bundle_multiples` (boolean), `materials.standard_bundle_size` (numeric, nullable).

---

### Decision 3: Material Consumption Policy & Unverified Variance Status
- **Current Requirement:** Keep theoretical requirements separate from actual measured or confirmed consumption. Never falsely present theoretical auto-backflush deductions as confirmed zero variance.
- **Unresolved Question:** When finished goods are packed, should materials be automatically backflushed or keyed manually by operators?
- **Configurable Architecture & Recommended Default:**
  - **Configurable Policy Toggle:**
    - **Policy A (`AUTO_BOM_THEORETICAL` - Recommended Default):**
      - Completed finished units automatically calculate theoretical requirements and post a backflush deduction from worker custody.
      - Deduction is tagged `measurement_method = 'AUTO_BOM_BACKFLUSH'` and `is_estimated = true`.
      - In `material_consumption_records`, `physically_confirmed_quantity` is `NULL`, `variance_quantity` is `NULL`, and `variance_status = 'UNVERIFIED'`.
      - At shift close, the worker returns unused materials (`RETURN_FROM_WORKER`) or reports scrap (`DAMAGE_QUARANTINE`). Any difference is logged as variance.
    - **Policy B (`CONFIRMED_ACTUAL_ENTRY`):**
      - The completion screen requires the operator or storekeeper to enter the exact physical quantity consumed.
      - Variance is calculated immediately at completion time (`variance_status` is `'VERIFIED_ZERO'` or `'VARIANCE_RECORDED'`).
- **Impact of Decision:** Supports high-speed automated packing lines as well as high-precision manual packing stations without falsifying inventory audits.
- **Configurable Setting:** `system_settings.consumption_policy` (`AUTO_BOM_THEORETICAL` vs `CONFIRMED_ACTUAL_ENTRY`).

---

### Decision 4: Purchase Orders Requirement for Inward Goods Receipts
- **Current Requirement:** Vendor purchase history must be tracked. Creating a PO must not increase physical stock. Only posted inward goods receipts credit stock.
- **Unresolved Question:** Must every Goods Receipt Note (GRN) link to an existing approved Purchase Order (`purchase_orders`), or can direct inward receipts without a prior PO be created (e.g., emergency local purchases)?
- **Configurable Architecture & Recommended Default:**
  - **Support Both with Optional PO Reference:**
    - `goods_receipts.po_id` is **nullable**.
    - If a PO is selected, lines auto-populate with ordered quantities and validate against over-receipt thresholds.
    - If no PO exists (emergency cash purchase), the storekeeper can post a direct GRN by specifying the vendor, invoice number, received date, and materials directly.
- **Impact of Decision:** Ensures store operations are never halted when suppliers deliver emergency packing materials without prior paperwork.
- **Configurable Setting:** `system_settings.allow_direct_inward_without_po` (boolean, default `true`).

---

### Decision 5: Daily Planning & Pending Job Rollover Policy
- **Current Requirement:** When a daily job of 1,000 units only completes 530 units, the remaining 470 pending units must be explicitly carried forward, rescheduled, or cancelled.
- **Unresolved Question:** Should the daily closing engine automatically roll over pending jobs, or require human planner confirmation?
- **Configurable Architecture & Recommended Default:**
  - **Manual Confirmation with Suggested Rollover (Recommended Default):**
    - The Daily Closing screen displays a "Pending Jobs Resolution Table".
    - Planner chooses per job: `[Roll Over to Next Shift/Plan]`, `[Reschedule for Specific Date]`, or `[Cancel Remainder]`.
    - No automatic silent rollover occurs without human confirmation.
  - **Automatic Rollover Mode (Configurable):** Automatically schedules remaining pending quantities into tomorrow's draft plan.
- **Impact of Decision:** Prevents unwanted phantom production jobs from piling up in future schedules if a customer order was trimmed or discontinued.
- **Configurable Setting:** `system_settings.pending_job_rollover_mode` (`MANUAL_CONFIRMATION` vs `AUTOMATIC_NEXT_DAY_DRAFT`).

---

### Decision 6: Role-Based Authorization Matrix for Critical Overrides
- **Current Requirement:** Maintain audit trails and protect stock invariants across roles.
- **Configurable Architecture & Recommended Default:**

| Action | `OPERATOR` | `STOREKEEPER` | `PLANNER` | `ADMIN` |
| :--- | :---: | :---: | :---: | :---: |
| Revise Job Quantity | ❌ | ❌ | ✅ | ✅ |
| Cancel Released Job | ❌ | ❌ | ✅ (Requires custody return) | ✅ |
| Post Material Issue/Return | ❌ | ✅ | ❌ | ✅ |
| Move Stock to Quarantine | ❌ | ✅ | ❌ | ✅ |
| Post Scrap Disposal | ❌ | Initiate only | ❌ | Approve only |
| Post Stock Adjustment | ❌ | Initiate only | ❌ | Approve only |
| Execute Daily Close | ❌ | ❌ | ✅ | ✅ |
| Reopen Closed Day | ❌ | ❌ | ❌ | ✅ (Mandatory reason) |

- **Security Implementation:** Enforced in PostgreSQL RLS via hardened `public.get_current_user_role()` (`IS DISTINCT FROM 'ADMIN'`) and in Flask decorators (`@require_role`).

---

### Decision 7: Single-Shift vs Multi-Shift Plant Scheduling
- **Current Requirement:** Daily close must summarize plan quantities, expected vs actual usage, variance, and worker custody.
- **Unresolved Question:** Does the plant run a single daily shift or multiple rotating shifts?
- **Configurable Architecture & Recommended Default:**
  - **Shift-Aware Scheduling & Composite Plan Alignment:**
    - `daily_plans.shift_code` supports arbitrary shift identifiers (e.g., `'GENERAL'`, `'SHIFT_1'`, `'SHIFT_2'`, `'SHIFT_3'`).
    - Composite uniqueness on `daily_plans(id, shift_code)`.
    - `daily_closings` enforces `FOREIGN KEY (daily_plan_id, shift_code) REFERENCES daily_plans(id, shift_code)`, ensuring shift codes cannot conflict.
    - Plants operating a single shift use `'GENERAL'`. Plants operating multiple shifts close each shift independently.
- **Impact of Decision:** Fully scalable to 24/7 continuous industrial manufacturing with zero data discrepancies.
- **Configurable Setting:** `daily_plans.shift_code`, `system_settings.active_shifts_per_day` (integer, default 1).

---

### Decision 8: Extensible Material Categories & Custom Specification Attributes
- **Current Requirement:** Administrator must be able to add new material categories without code or schema changes.
- **Configurable Architecture & Recommended Default:**
  - Master table `material_categories` for dynamic category management.
  - Common physical dimensions as strongly typed columns on `materials`.
  - Extensible `additional_specs` JSONB column with check constraint `CHECK (jsonb_typeof(additional_specs) = 'object')`.
- **Impact of Decision:** Maximum catalog flexibility with zero schema migration overhead.

---

### Decision 9: Completely Customized Packing Snapshots vs Master BOM Reference
- **Current Requirement:** Production frequently executes custom or ad-hoc packing jobs that do not derive from any catalog BOM.
- **Configurable Architecture & Recommended Default:**
  - `packing_jobs.master_bom_id` and `packing_job_bom_snapshots.source_bom_id` are nullable only for source-less custom jobs.
  - Constrained by `CHECK ((is_customized = false AND source_bom_id IS NOT NULL AND bom_version IS NOT NULL) OR (is_customized = true AND source_bom_id IS NULL AND bom_version IS NULL))`.
  - Every release transaction MUST validate and freeze a header and at least one complete, positive snapshot line before creating reservations or making the job releasable. Fake master BOMs are not permitted.

---

### Decision 10: Single Active BOM Version Promotion Policy
- **Current Requirement:** Prevent ambiguous active recipe versions while supporting draft iterations and historical audits.
- **Configurable Architecture & Recommended Default:**
  - At most one ACTIVE version per recipe key `(product_id, party_id, packing_variant_name)` enforced via partial unique index `idx_boms_single_active_version`.
  - Version releases execute as an atomic transaction: lock existing active BOM, update status to `SUPERSEDED`, update new draft to `ACTIVE`, and record an immutable entry in `bom_revision_events`.

---

## 3. Genuinely Unresolved Decisions Awaiting User Confirmation

The following business operational parameters are intentionally designed as configurable settings and await business owner sign-off:

1. **Plant Operating Schedule:** Confirm whether the facility operates on a **Single Shift** (General Shift only) or **Multiple Rotating Shifts** (Shift 1, Shift 2, Shift 3). Default is configured to support multi-shift via `shift_code`.
2. **Default Flexible Film Stocking Unit:** Confirm whether bulk flexible packaging is stocked in **KG** or **PCS** for standard inventory reports. Default is set to **KG** with calibrated `≈ PCS` secondary display.
3. **Emergency PO Requirement:** Confirm whether storekeepers are permitted to post inward shipments without a prior PO (`allow_direct_inward_without_po = true`). Default permits direct receipts with mandatory vendor and invoice data.
4. **Shift Close Override Authorization:** Confirm whether `PLANNER` role can approve exception closes with unreturned custody, or if this override is strictly restricted to `ADMIN`. Default allows `PLANNER` and `ADMIN` with mandatory justification note.
