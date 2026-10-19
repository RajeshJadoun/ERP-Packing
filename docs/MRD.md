# Material Requirements Document (MRD)

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## 1. Material Catalog & Physical Variant Taxonomy

In finished goods packing, small dimensional differences fundamentally change material suitability. Treating distinct sizes or gauges under generic item codes leads to packaging failure, stock discrepancies, and line stoppages.

### 1.1 Data-Driven Material Categories
Rather than hardcoding material categories into database constraints or application enums, material categories are dynamically defined in `material_categories`:
- Administrators can register new categories (e.g., *Cartons*, *Poly Bags*, *Fasteners/Screws*, *Foam Bags*, *Bubble Bags*, *Corner Protectors*, *Desiccants*, *BOPP Tapes*, *Strapping Bands*) via the UI at any time without database migrations or code changes.
- Each category possesses a unique code, descriptive name, and active toggle.

### 1.2 Material Variant Granularity & Extensible Specifications
Every materially distinct item is maintained as an **independent variant/SKU** in `materials`:
- **Common Strongly-Typed Physical Columns:**
  - `thickness_gauge`: Numeric (e.g., 150 for poly bags, 2.0 for foam sheets).
  - `width_mm`, `length_mm`, `height_mm`: Numeric millimeter dimensions.
  - `diameter_thread_spec`: Text specification for fasteners (e.g., 'M4x10mm Pan Phillips Zinc').
- **Extensible Custom Specifications (`additional_specs`):**
  - Stored as a validated `jsonb` object to accommodate category-specific attributes without future schema migrations.
  - Examples:
    - Cartons: `{"ply": "5-ply", "bursting_factor": 16, "flute": "B-flute", "paper_gsm": "180/150/150"}`
    - Tape: `{"microns": 45, "adhesive": "acrylic", "core_diameter_mm": 76}`
    - Fasteners: `{"drive_type": "cross_recessed", "tensile_grade": "4.8", "plating": "yellow_zinc"}`

---

## 2. Measurement Dimensions, Canonical Units & Conversion Rules

### 2.1 The Canonical Stock Unit Principle
Each material variant possesses exactly **one authoritative Canonical Stock Unit** (`canonical_unit_id`):
- Canonical unit is selected per material variant:
  - Weighed bulk packaging (film rolls, continuous bubble sheet, bulk tape): Canonical Unit = **KG**.
  - Counted, pre-formed packaging (cartons, pre-cut poly bags, fasteners, corner protectors): Canonical Unit = **PCS**.
  - Pre-packaged supplies: **BOX** or **ROLL**.
- All entries in the authoritative stock ledger (`stock_transactions`) and balance projections (`material_location_balances`) are denominated and summed in this canonical unit.
- The canonical unit is database-immutable once the variant has any stock transaction, reservation, or released BOM snapshot line. Correcting a post-activity unit requires a replacement variant; it never changes historical meaning.

### 2.2 Conversion Direction, Provenance & Immutability
To reconcile purchasing, stocking, and shop-floor consumption, conversion formulas are explicitly classified into two mutually exclusive types:

```mermaid
graph LR
    UnitA[Entered Unit: KG / BOX] --> ConvEngine{Conversion Engine}
    ConvEngine -->|Mathematically Fixed| Exact[EXACT: 1 BOX = 100 PCS]
    ConvEngine -->|Empirically Calibrated| Est[ESTIMATED: 1 KG ≈ 100 PCS]
    Exact --> UIExact[UI: Authoritative Count]
    Est --> UIEst[UI: Informational Count with ~ prefix]
```

1. **`EXACT` Conversions:**
   - Derived from packaging geometry or fixed mathematical definitions (e.g., 1 BOX = 100 PCS).
2. **`ESTIMATED` Conversions:**
   - Derived from weight-to-count sampling calibrations (e.g., 1 KG ≈ 100 PCS).
   - **Audit Provenance Rule:** Every estimated conversion records `provenance_note` (e.g., "100 samples weighed on 2026-10-01, avg weight 10.0g").
3. **Ledger Provenance Immutability:**
   - Every conversion-dependent receipt and ledger transaction records:
     - `entered_quantity` and `entered_unit_id`.
     - `canonical_quantity` and `canonical_unit_id`.
     - selected immutable `conversion_rule_id` when applicable, `conversion_factor_applied`, `conversion_direction` (`MULTIPLY`, `DIVIDE`, `NONE`), and exact/estimated classification.
     - `measurement_method` and physical measurement evidence where applicable.
   - Released BOM snapshots freeze source and canonical unit, `canonical_qty_per_unit`, rule ID, factor, direction, and classification at release time. Master calibration changes later **never retroactively modify historical stock movements, requirements, or snapshots**.
   - Direct same-unit operations record no rule, factor `1`, direction `NONE`, and classification `EXACT`.
4. **No Mixed Unit Arithmetic:** The database strictly prevents adding or subtracting numbers across different units without an explicit conversion factor.

### 2.3 Loose Item Handling & Configurable Bundle Rules
> [!IMPORTANT]
> **The Ground Rule on Loose Stock:**
> The software must never fabricate or invent unknown piece counts when loose materials are handled on the shop floor.
- Bundle rules are configurable per material:
  - `enforce_bundle_multiples` (boolean) and `standard_bundle_size` (numeric).
- Every issuance records the exact physical measurement method:
  1. `SCALE_WEIGHED`: Weighed on an electronic counting scale.
  2. `SEALED_BUNDLE`: Pre-packaged standard pack (e.g., manufacturer packet of 200).
  3. `MANUALLY_COUNTED`: Counted by hand by the storekeeper.
  4. `AUTO_BOM_BACKFLUSH`: Backflushed deduction based on finished units packed.
- The UI explicitly marks backflushed or estimated quantities as approximations, never claiming they were physically measured.

---

## 3. Bill of Materials (BOM) Requirements

### 3.1 Reusable BOM Header & Lines
A Bill of Materials defines the standard packaging material recipe required to pack **one finished product unit**.
- **Header:** Product SKU, Optional Party/Customer, Packing Variant Name (e.g., "Domestic Standard", "Heavy Export"), Version Number, Status (`ACTIVE`, `DRAFT`, `SUPERSEDED`, `ARCHIVED`).
- **Uniqueness Invariants:**
  - `UNIQUE NULLS NOT DISTINCT (product_id, party_id, packing_variant_name, version_number)` prevents duplicate version numbers.
  - Partial Unique Index `idx_boms_single_active_version` on `(product_id, party_id, packing_variant_name) NULLS NOT DISTINCT WHERE (status = 'ACTIVE')` guarantees that at most one ACTIVE version exists per recipe key.
- **Lines:** Material Variant SKU, Quantity per Unit ($> 0$), Unit, Frozen Canonical Quantity per Unit, Optional Flag (Yes/No), Application Notes.

### 3.2 Party-Specific Packing Configurations
Different customers specify distinct packaging standards for the same finished product:
- **Party A (Domestic Retail):** Requires 1 poly bag (150 gauge) + 4 zinc screws M4x10mm.
- **Party B (Industrial Export):** Requires 1 heavy-duty poly bag (250 gauge) + 1 foam bag + 4 stainless steel screws M4x16mm + 4 corner protectors.
- Party-specific overrides are linked to `party_id`. The scheduler defaults to the approved customer BOM.

### 3.3 BOM Versioning, Promotion & Customized Snapshots
- Modifying a master BOM increments its version number and logs a `bom_revision_event`.
- Promoting a new version to `ACTIVE` executes atomically: locks current active BOM, supersedes it, activates the new version, and logs revision events in a single transaction.
- **Support for Customized Ad-hoc Snapshots:**
  - While standard jobs derive from a catalog BOM (`master_bom_id` and `source_bom_id` non-null), the system fully supports completely custom or one-off packing jobs (`master_bom_id`, `source_bom_id`, and `bom_version` all null; `is_customized = true`).
  - Regardless of source, release atomically validates and freezes a non-empty, complete immutable snapshot header and detail lines. A revision must be at least `completed_quantity`; a smaller target is rejected rather than rewriting completed production. Released jobs are **never altered** by future master BOM revisions.

---

## 4. Operational Packing Jobs & Quantity Accounting

### 4.1 Daily Plan Multi-Job & Shift Grouping
- A single daily packing plan groups multiple independent packing jobs for an operating date and `shift_code` (e.g., 'GENERAL', 'SHIFT_1', 'SHIFT_2').
- Multiple jobs for the same Party and Product can exist on the same date with distinct BOMs, screw sizes, or packaging specifications.
- Composite uniqueness on `daily_plans(id, shift_code)` guarantees unambiguous shift identity.

### 4.2 Explicit Five-Variable Quantity Conservation Model
Every packing job tracks five explicit quantity variables governed by a database check constraint:

$$\text{current\_revised\_quantity} = \text{completed\_quantity} + \text{pending\_quantity} + \text{cancelled\_quantity}$$

- `original_planned_quantity`: Frozen initial target at job release.
- `current_revised_quantity`: Active authorized target after revisions.
- `completed_quantity`: Packed finished units confirmed.
- `pending_quantity`: Units remaining to be packed.
- `cancelled_quantity`: Units formally cancelled from the authorized target.

### 4.3 Quantity Revision Protocol (520 $\to$ 450 Units)
- In-shift quantity revisions are logged in `packing_job_revisions` with user ID, timestamp, and mandatory reason.
- Enforces constraint: $\text{revised\_quantity} \ge \text{completed\_quantity}$.
- Material reservations are immediately updated:
  $$\Delta\text{Reservation} = (\text{revised\_quantity} - \text{completed\_units}) \times \text{snapshot\_canonical\_qty}$$

### 4.4 Cancellation Protocol
- When a job remainder is cancelled:
  - `cancelled_quantity` is set to the remaining `pending_quantity`.
  - `pending_quantity` becomes 0.
  - Completed production and past consumption are permanently preserved.
  - Active reservations for cancelled units are released.
  - Any materials remaining with the worker must be formally returned (`RETURN_FROM_WORKER`) or quarantined/scrapped.

---

## 5. Material Issue, Custody, Consumption & Quarantine

### 5.1 Custody Transfer vs Consumption
- Issuing materials to a worker is an **internal custody transfer** (`ISSUE_TO_WORKER`), not consumption. Total physical stock is unchanged.
- Consumption (`CONSUMPTION`) occurs only when finished goods are packed or scrap is reported.

### 5.2 Theoretical BOM Usage vs Confirmed Physical Usage & Unverified Variance
For every completed batch of finished goods (e.g., 530 units packed):
1. **Theoretical Requirement (BOM Calculation):**
   $$\text{Theoretical Qty} = \text{Completed Units} \times \text{Snapshot Canonical Qty per Unit}$$
2. **Auto-BOM Backflush Deduction (If Configured):**
   Generates a ledger deduction with `measurement_method = 'AUTO_BOM_BACKFLUSH'`, `is_estimated = true`.
   - In `material_consumption_records`, `physically_confirmed_quantity = NULL`, `variance_quantity = NULL`, and `variance_status = 'UNVERIFIED'`.
   - **Crucial Rule:** The system does NOT claim zero variance during automated backflush.
3. **Confirmed Actual Consumption (If Keyed):**
   Physical count recorded by operator with `is_physically_measured = true` and `measurement_method` specified.
   - When `physically_confirmed_quantity` is entered, `variance_quantity = physically_confirmed_quantity - theoretical_quantity`.
   - `variance_status` is updated to `'VERIFIED_ZERO'` (if variance = 0) or `'VARIANCE_RECORDED'` (if variance != 0).
4. **Shift Closing Reconciliation:**
   Shift close inspects worker custody balances, returns, and variances. Unresolved discrepancies require supervisor override notes.

### 5.3 Segregation of Damage Quarantine from Permanent Disposal
1. **`DAMAGE_QUARANTINE`:**
   - Moves defective stock from store/custody/buffer to `DAMAGE_QUARANTINE` leaf location.
   - Usable store stock decreases; quarantine balance increases. **Total physical inventory is unchanged.**
2. **`SCRAP_DISPOSAL`:**
   - Disposes of condemned quarantined materials strictly originating from a `DAMAGE_QUARANTINE` leaf node.
   - Quarantine balance decreases; **total physical company stock decreases permanently**.
