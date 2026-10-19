# UI/UX Architecture & Operational Walkthrough Blueprint

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## 1. Design System & Global Layout Principles

The user interface is engineered as a responsive, modern desktop-first Single Page Application (SPA) using React 19, TypeScript, and clean Vanilla CSS design tokens.

### 1.1 Global Layout Hierarchy
- **Header Bar:** Active date and shift selector (`shift_code`: General, Shift 1, Shift 2), system status indicator (Online / Syncing), quick-search bar, notification tray (stock alerts, pending approvals), and user profile badge with role label (`ADMIN`, `STOREKEEPER`, `PLANNER`, `OPERATOR`, `VIEWER`).
- **Collapsible Navigation Sidebar:**
  1. **Dashboard** (`/`)
  2. **Master Catalogs** (`/masters/*`: Categories, Parties, Products, Materials, Vendors, Locations, Workers, Units & Conversions)
  3. **Purchasing & Inward** (`/purchasing/*`: Purchase Orders, Inward Receipts / GRN, Vendor History)
  4. **Inventory & Ledger** (`/inventory/*`: Current Stock Balances, Stock Movement Ledger, Stock Transfers, Cycle Count Adjustments, Damage Quarantine & Scrap Disposal)
  5. **Worker Custody** (`/worker-custody/*`: Issue Material, Return Material, Active Operator Balances)
  6. **BOM Management** (`/boms/*`: Master BOMs, Versioning Studio, Party-Specific Recipes)
  7. **Daily Packing Operations** (`/daily-plans/*`: Daily Schedule, Job Detail, Production Entry, Variance Console)
  8. **Closing & Reconciliations** (`/closings/*`: Shift/Daily Close, Discrepancy Reconciliation)
  9. **Reports & Analytics** (`/reports/*`: Stock by Location, Shortage Forecast, Vendor Quality, Worker Consumption Audit)
  10. **System Administration** (`/admin/*`: User Roles, System Settings, Audit Event Log)

### 1.2 UX Micro-Conventions & Visual Cues
- **Dual-Unit Clarity:** Whenever estimated secondary units are shown, they are visually distinct and prefixed with a tilde: e.g., `25.000 KG` (bold primary), `≈ 2,500 PCS (est)` (muted secondary pill).
- **5-Variable Quantity Conservation Bar:**
  On all packing job detail screens, quantity progress is visualized through a segmented 5-variable progress bar:
  - **Original Planned:** Muted reference marker (e.g., `520`).
  - **Current Revised Target:** The active authorized baseline (e.g., `450`).
  - **Completed:** Emerald segment (`100`).
  - **Pending:** Blue segment (`0`).
  - **Cancelled:** Amber striped segment (`350`).
  - **Invariant Badge:** Dynamic validation pill displaying `Balanced: 450 = 100 + 0 + 350` to assure shop-floor integrity.
- **Three-Tier Consumption & Variance Clarity:**
  - **Theoretical BOM Requirement:** Calculated dynamically ($\text{completed units} \times \text{snapshot line quantity}$) and displayed as an informational benchmark.
  - **Auto-BOM Backflush Deduction:** Badged with an amber `Backflushed (Pending Shift Audit)` pill (`is_estimated = true`, `measurement_method = 'AUTO_BOM_BACKFLUSH'`, `variance_status = 'UNVERIFIED'`). The variance column displays `Unverified`—never falsely displaying `0.00` as a measured result!
  - **Physically Confirmed Actual Consumption:** Badged with an emerald `Physical (Verified)` pill with the specific verified measurement method (`SCALE_WEIGHED`, `SEALED_BUNDLE`, `MANUALLY_COUNTED`).
  - **Verified Variance:** Computed strictly when a physical measurement is supplied: $\text{Variance} = \text{Physically Confirmed} - \text{Theoretical}$. Displays `VERIFIED_ZERO` (emerald badge `0.00`) or `VARIANCE_RECORDED` (orange/red badge with difference).
- **Stock Status Segregation Across 6 Facility Node Types:**
  Stock balances are clearly partitioned into: **Usable Store Stock** (`STORE_SHELF`), **Receiving Bay** (`RECEIVING_BAY`), **Shop-Floor Buffer** (`SHOP_FLOOR_BUFFER`), **Worker Custody** (`WORKER_CUSTODY`), **Damage Quarantine** (`DAMAGE_QUARANTINE`), and **Dispatch Staging** (`DISPATCH`).
  Total Tracked Inventory, Quarantined, Reserved, and Available-to-Promise (ATP) are explicitly computed across leaf nodes.

---

## 2. Comprehensive Screen Specifications

### Screen 1: Executive Operations Dashboard (`/`)
- **User Purpose:** High-level operational command center for Shift Leads, Planners, and Plant Managers.
- **Main Data Displayed:**
  - **KPI Metric Cards:** Shift Planned Units, Completed Units (%), Active Packing Jobs, Critical Stock Shortages, Quarantined Stock Alerts, Active Worker Custody Balance.
  - **Live Daily Plan Summary Table:** Party, Product, Packing Variant, Planned, Packed, Pending, Shift, Status, Assigned Worker.
  - **Actionable Alerts Feed:** Materials below safety threshold; unreturned worker custody; pending quarantine reviews.
- **Required Permissions:** Read access available to all roles (`OPERATOR` view is filtered to assigned jobs).

---

### Screen 2: Material Categories Catalog (`/masters/categories`) (Added in Phase 1.1)
- **User Purpose:** Manage dynamic packaging categories without code changes or database migrations.
- **Main Data Displayed:** Table of categories: Code, Name, Description, Active Materials Count, Status Toggle.
- **Fields & Form Validation:**
  - `category_code`: Alphanumeric, uppercase, required, unique.
  - `category_name`: Required, text.
  - `description`: Optional text.
- **Actions:** Add Category, Edit Category, Toggle Active Status. (Deletion is blocked if materials reference the category).
- **Permissions:** Read: All; Create/Update: `ADMIN`.

---

### Screen 3: Materials & Variants Catalog (`/masters/materials`)
- **User Purpose:** Define raw packing materials, technical specifications, and canonical inventory units.
- **Main Data Displayed:** Searchable table of material variants: Code, Name, Category (from `material_categories`), Canonical Unit, Common Specs (Gauge, $L \times W \times H$, Thread), Additional Custom Specs (JSON preview), Status.
- **Fields & Form Validation:**
  - `item_code`: Alphanumeric, unique, required.
  - `material_name`: Required, text.
  - `category_id`: Dropdown populated from `material_categories`.
  - `canonical_unit`: Dropdown from `units`.
  - `thickness_gauge`, `width_mm`, `length_mm`, `height_mm`: Numeric, $\ge 0$.
  - `diameter_thread_spec`: Text field for fasteners.
  - `additional_specs`: Key-value dynamic attribute editor (e.g., ply, bursting factor, color).
  - `min_stock_alert_level`: Numeric, $\ge 0$.
- **Actions:** Add Material, Edit Specs, Soft-Deactivate (`is_active = false`). Hard delete is blocked if transactions exist.
- **Permissions:** Read: All; Create/Update: `ADMIN`, `STOREKEEPER`.

---

### Screen 4: Inward Goods Receipt / GRN (`/purchasing/inward`)
- **User Purpose:** Receive incoming shipments of packing materials from vendors and credit the stock ledger with full provenance.
- **Main Data Displayed:** GRN Header (Vendor, PO Reference, Invoice No, Invoice Date, Received Date, Receiving Location, Status) and Line Items Table.
- **Fields & Form Validation:**
  - `vendor_id`: Dropdown, required.
  - `invoice_number`: Required, validated for duplicate vendor invoices.
  - `invoice_date` & `received_date`: Two distinct date pickers.
  - `destination_location_id`: Store receiving location.
  - Line Items:
    - `material_id`: Required.
    - `entered_qty` & `entered_unit_id`: Original measured quantity and unit from bill of lading.
    - `rejected_qty` & `rejected_unit_id`: Original defective quantity at dock ($\ge 0$) with an explicit unit; the form never subtracts differing units itself.
    - `box_count`, `weight_kg`, `pcs_count`, `batch_lot_number`: Physical packaging evidence.
    - Optional `expected_canonical_quantity`: Preview-only estimate, clearly labelled non-authoritative.
    - **Server result panel after Post:** trusted accepted quantity/unit, canonical quantity/unit, conversion rule ID, factor, direction, and exact/estimated status. These calculated values—not form values—are credited to stock.
- **Actions:** Save as Draft, Post GRN, Print GRN Slip. Posting validates/normalizes measurements and atomically creates ledger rows; posted receipts are strictly immutable.
- **Permissions:** Post GRN: `ADMIN`, `STOREKEEPER`.

---

### Screen 5: Current Stock Balances & Multi-Location Ledger (`/inventory/stock`)
- **User Purpose:** View real-time physical stock across all warehouse zones, shop-floor buffers, and operator hands, and inspect the immutable audit ledger.
- **Main Data Displayed:**
  - **Location Tree & Balance Grid:**
    - Displays stock partitioned across all **6 Facility Node Types**:
      1. **Usable Store** (`STORE_SHELF`): Primary storage shelves.
      2. **Receiving Bay** (`RECEIVING_BAY`): Staging area for incoming deliveries prior to putaway.
      3. **Shop-Floor Buffer** (`SHOP_FLOOR_BUFFER`): Line-side staging containers for packaging runs.
      4. **Worker Custody** (`WORKER_CUSTODY`): Virtual location assigned per active shop-floor operator.
      5. **Damage Quarantine** (`DAMAGE_QUARANTINE`): Segregated area for defective materials.
      6. **Dispatch Staging** (`DISPATCH`): Buffer holding finished packed kits awaiting customer vehicle loading.
    - **Inventory Metrics Aggregation (Strict Leaf Node Rollup):**
      - $\text{Total Company Physical Tracked Inventory} = \sum (\text{STORE\_SHELF} + \text{RECEIVING\_BAY} + \text{SHOP\_FLOOR\_BUFFER} + \text{WORKER\_CUSTODY} + \text{DAMAGE\_QUARANTINE} + \text{DISPATCH})$.
      - $\text{Usable Stock} = \sum (\text{STORE\_SHELF} + \text{SHOP\_FLOOR\_BUFFER})$.
      - $\text{Worker Custody} = \sum (\text{WORKER\_CUSTODY})$.
      - $\text{Quarantined Stock} = \sum (\text{DAMAGE\_QUARANTINE})$.
      - $\text{Reserved Stock} = \sum (\text{Active Job Reservations in canonical units})$.
      - $\text{Available-to-Promise (ATP)} = \text{Usable Stock} - \text{Reserved Stock}$.
  - **Transaction Ledger Tab:** Timestamp, Transaction ID, Material, Movement Type, Source $\to$ Destination, Quantity, Canonical Unit, Entered Qty & Unit, Measurement Method, Reference Entity (Strongly-typed link), Operator ID.
- **Actions:** Filter by node type, shelf, or category; drill down into transaction history.
- **Permissions:** Read: All authenticated roles.

---

### Screen 6: Damage Quarantine & Scrap Disposal (`/inventory/quarantine`)
- **User Purpose:** Manage damaged materials, segregating them in quarantine and recording authorized scrap disposal.
- **Main Data Displayed:**
  - **Active Quarantined Stock Table:** Material, Quarantine Bay, Quantity, Date Quarantined, Reason, Reported By.
- **Available Modals & Actions:**
  - `[Move to Quarantine]`: Action to transfer damaged stock from a store shelf, buffer, or worker custody to a quarantine bay (`DAMAGE_QUARANTINE`). Does not decrease total physical inventory.
  - `[Dispose of Scrap]`: Action to write off condemned quarantined stock (`SCRAP_DISPOSAL`). Requires `ADMIN` approval and permanently reduces company physical stock.
- **Permissions:** Move to Quarantine: `STOREKEEPER`, `ADMIN`; Scrap Disposal: `ADMIN`.

---

### Screen 7: Worker Custody & Material Issue (`/worker-custody/issue`)
- **User Purpose:** Hand over packing materials from warehouse shelves or shop-floor buffers to shop-floor operators.
- **Fields & Form Validation:**
  - `worker_id`: Dropdown.
  - `packing_job_id`: Dropdown of active released jobs.
  - `material_id`: Dropdown of materials in job's frozen BOM.
  - `source_location_id`: Store shelf or shop-floor buffer with available stock.
  - `entered_quantity` & `entered_unit_id`: Input quantity.
  - `measurement_method`: Dropdown (`SEALED_BUNDLE`, `SCALE_WEIGHED`, `MANUALLY_COUNTED`).
- **Permissions:** `ADMIN`, `STOREKEEPER`.

---

### Screen 8: Worker Custody & Material Return (`/worker-custody/return`)
- **User Purpose:** Return unused materials from operator custody back to warehouse shelves or buffers.
- **Fields & Form Validation:**
  - `worker_id`: Dropdown.
  - `material_id`: Dropdown of items currently held in worker custody.
  - `destination_location_id`: Warehouse shelf, shop-floor buffer (or quarantine bay if defective).
  - `quantity`: Must be $\le \text{Worker Current Custody}$.
  - `condition`: Radio (`PRISTINE_REUSABLE` $\to$ Store Shelf / Buffer, `DAMAGED` $\to$ Quarantine Bay).
- **Permissions:** `ADMIN`, `STOREKEEPER`.

---

### Screen 9: Master BOM Studio & Versioning (`/boms`)
- **User Purpose:** Author and maintain version-controlled packaging recipes for finished products.
- **Main Data Displayed:** Product, Customer Party (Optional), Packing Variant Name, Version Number, Status (`ACTIVE`, `DRAFT`, `SUPERSEDED`), Lines Count.
- **Uniqueness & Active Version Protection:** Database prevents duplicate generic master BOMs when Party is blank via `NULLS NOT DISTINCT`. At most one ACTIVE version per recipe key is enforced via `idx_boms_single_active_version`.
- **Actions:** Create Master BOM, Release New Version (atomic promotion transaction that supersedes previous active version and logs revision event), Duplicate as Party-Specific BOM.
- **Permissions:** `ADMIN`, `PLANNER`.

---

### Screen 10: Daily Packing Plan & Multi-Job Scheduler (`/daily-plans`)
- **User Purpose:** Build the daily production schedule from manually received customer packing lists.
- **Main Data Displayed:** Date picker, Shift Selector (`shift_code`), Plan Status, Total Planned Units, Jobs List.
- **Multi-Job & Custom Job Support:**
  - Explicitly permits adding the same Party + Product multiple times with distinct BOM variants, screw sizes, or quantities.
  - **Custom Job Builder Toggle:** `[x] Create Custom Packing Job (No Catalog BOM)`. Clears `masterBomId`, requires one or more material lines (material, unit, positive quantity), and labels the draft “Not releasable” until all lines validate. Release generates source-less immutable snapshot lines with `is_customized = true`, `source_bom_id = NULL`, and `bom_version = NULL`; it never creates a fake master BOM.
- **Actions:** Add Job, Customize Job BOM, Save Draft, Release Plan to Production.
- **Permissions:** `ADMIN`, `PLANNER`.

---

### Screen 11: Packing Job Detail & 5-Variable Quantity Revision (`/daily-plans/jobs/:id`)
- **User Purpose:** View complete operational state of an individual job and manage quantity revisions or cancellations with full mathematical reconciliation.
- **Main Data Displayed:**
  - **Job Header 5-Variable Quantity Status Card:**
    - **Original Planned Quantity:** e.g., `520` (Historical reference).
    - **Current Authorized Target:** e.g., `450` (Active planning baseline).
    - **Completed Quantity:** e.g., `100` (Confirmed packed units).
    - **Pending Quantity:** e.g., `0` (Remaining to pack).
    - **Cancelled Quantity:** e.g., `350` (Authorized dropped remainder).
    - **Conservation Check:** Green badge: `450 = 100 + 0 + 350 (Balanced)`.
  - **Frozen BOM Snapshot Table:** Material, Required per Unit (Canonical Unit), Total Required for Current Target, Issued to Worker, Confirmed Consumed, Returned, Remaining Custody Balance.
  - **Revisions & Events History Timeline:** Immutable chronological log of all revision reasons, actors, previous quantities, and new quantities.
- **Actions:**
  - `[Revise Planned Quantity]`: Modal to revise quantity (e.g., 520 $\to$ 450). Validates $\text{New Quantity} \ge \text{completed\_quantity}$. If the proposed quantity is lower, it blocks submission and shows: “Cannot revise below 500 completed units. Completed production cannot be changed; use the authorized overproduction exception workflow if applicable.” A valid revision recomputes pending quantity and adjusts reservations immediately.
  - `[Cancel Remainder]`: Anti-delete cancellation wizard. Calculates pending units, moves them to `cancelled_quantity`, sets `pending_quantity = 0`, updates job status to `CANCELLED`, releases reservations, and checks that worker custody is zero or flagged. Completed production history (100 units) remains completely preserved.
- **Permissions:** `ADMIN`, `PLANNER`.

---

### Screen 12: Production Output & Consumption Entry (`/daily-plans/jobs/:id/complete`)
- **User Purpose:** Record packed finished goods batches and accurately account for material consumption.
- **Fields & Form Validation:**
  - `completed_units`: Integer $> 0$, must be $\le \text{Pending Units}$.
  - `worker_id`: Operator who packed the batch.
  - **Material Consumption Breakdown Table:**
    - **Material Name & Canonical Unit.**
    - **Theoretical Requirement:** Dynamically computed ($\text{completed\_units} \times \text{snapshot line quantity}$).
    - **Consumption Policy Mode Toggle:**
      - Mode A: `[Auto-BOM Backflush]` (Default). Deducts theoretical quantity from the completing worker's custody or an explicitly authorized job buffer. Form records `posted_ledger_quantity = theoretical_quantity`, `physically_confirmed_quantity = NULL`, `variance_quantity = NULL`, `variance_status = 'UNVERIFIED'`, `measurement_method = 'AUTO_BOM_BACKFLUSH'`. Variance column shows `Unverified (Pending Audit)`.
      - Mode B: `[Enter Confirmed Physical Consumption]`. Operator provides actual measured count or weight. Form records `posted_ledger_quantity = physically_confirmed_quantity`, `is_estimated = false`, and prompts for `measurement_method` (`SCALE_WEIGHED`, `SEALED_BUNDLE`, `MANUALLY_COUNTED`).
    - **Live Variance Preview:** If Mode B is chosen, displays $\text{Variance} = \text{Actual} - \text{Theoretical}$ with status `VERIFIED_ZERO` or `VARIANCE_RECORDED`.
- **Permissions:** `ADMIN`, `STOREKEEPER`, `PLANNER`, `OPERATOR`.

---

### Screen 13: Daily Closing & Shift Reconciliation Console (`/closings`)
- **User Purpose:** Reconcile end-of-shift operations, review variances, inspect unresolved worker custody, and lock the daily schedule.
- **Main Data Displayed:**
  - **Shift Summary:** Shift Code, Total Planned vs Packed vs Pending vs Cancelled.
  - **Material Consumption & Variance Audit Table:** Material, Total Theoretical Requirement, Total Confirmed Consumption, Variance Qty, Variance %. Items in `UNVERIFIED` status are flagged for physical return reconciliation.
  - **Outstanding Worker Custody Checklist:** Lists any worker holding unreturned materials.
  - **Pending Jobs Resolution Table:** Allows Planner to choose: `[Carry Forward to Next Shift]`, `[Reschedule]`, or `[Cancel Remainder]`.
- **Closing Rules:** Quarantined stock does **not** block closing. Unreturned worker custody blocks closing unless an authorized supervisor override with mandatory reason is provided. Composite foreign key ensures closing shift matches plan shift.
- **Permissions:** `ADMIN`, `PLANNER`.

---

## 3. Operational Step-by-Step Walkthrough of Core Scenarios

### Scenario 1: Receiving 25 KG of Poly Bags with Conversion Provenance
1. Storekeeper navigates to `/purchasing/inward` and clicks **"New Inward Receipt"**.
2. Selects Vendor "Apex Polymers", Invoice "INV-4412", Invoice Date "2026-10-14", Received Date "2026-10-14", Destination "Shelf A-1".
3. Adds line: Material "Poly Bag 8x4" (Category: Poly Bags, Canonical Unit: KG).
4. Enters Received Qty: `25.000 KG`, Rejected Qty: `0.000 KG`, Accepted Qty: `25.000 KG`.
5. Enters Auxiliary Measurements: Box Count: `5 boxes`, Gross Weight: `25.000 kg`, Estimated Count: `≈ 2,500 pcs`.
6. Clicks **"Post GRN"** and confirms modal.
7. **System Result:** Transaction `PURCHASE_RECEIPT` posted with `entered_quantity = 25.000`, `canonical_quantity = 25.000`, `measurement_method = 'SCALE_WEIGHED'`. Shelf A-1 balance increases by `25.000 KG`. Total physical stock increases by `25.000 KG`.

---

### Scenario 2: Creating a Dynamic Material Category & Material Variant
1. Admin navigates to `/masters/categories` and clicks **"Add Category"**.
2. Inputs Code: `CORNER_PROTECTOR`, Name: `Cardboard Corner Protectors`. Saves category.
3. Admin navigates to `/masters/materials` and clicks **"Add Material"**.
4. Selects Category `CORNER_PROTECTOR`, Canonical Unit `PCS`, enters Code `CP-50X50-3MM`, Name `Corner Protector 50x50x3mm`.
5. Under `additional_specs`, adds dynamic attributes: `{"ply": "3-ply", "angle_degrees": 90}`.
6. Saves material.
7. **System Result:** New category and variant are fully active without any code change or schema migration.

---

### Scenario 3: Segregating Damaged Stock to Quarantine vs Final Disposal
1. Shift Lead discovers that 50 cartons on Shelf A-1 were damaged by a roof leak.
2. Storekeeper opens `/inventory/quarantine` and clicks **"Move to Quarantine"**.
3. Selects Material "Carton Box 12x8x6", Source "Shelf A-1", Destination "Quarantine Bay", Qty `50 PCS`, Reason: "Water leak damage".
4. Clicks **"Confirm Quarantine"**.
5. **System Result:** Transaction `DAMAGE_QUARANTINE` is posted. Shelf A-1 usable balance drops from 1,000 to 950 PCS. Quarantine Bay balance rises from 0 to 50 PCS. Total physical company stock remains **1,000 PCS**. Available-to-promise drops to 950 PCS.
6. The next day, QC confirms the cartons are unsalvageable. Admin opens `/inventory/quarantine` and clicks **"Dispose of Scrap"**.
7. Selects 50 PCS from Quarantine Bay, Reason: "Condemned and disposed via scrap contractor".
8. **System Result:** Transaction `SCRAP_DISPOSAL` is posted. Quarantine Bay balance drops to 0. Total company physical stock permanently decreases from 1,000 to 950 PCS.

---

### Scenario 4: Revising Planned Quantity from 520 to 450 Units
1. Planner opens Job Detail (`/daily-plans/jobs/JOB-004`). Planned Qty: 520 units. Completed: 0 units.
2. Clicks **"Revise Quantity"**, inputs New Quantity: `450`, Reason: *"Party B reduced delivery size."*
3. Clicks **"Confirm Revision"**.
4. **System Result:** `packing_job_revisions` logs revision #1. Job `current_revised_quantity` becomes 450. Material reservations for 70 units are immediately released to available stock. Anti-cascade foreign keys protect the revision record from deletion.

### Scenario 4A: Rejection Below Completed Quantity
1. Job shows `Completed = 500`, `Current Authorized Target = 520`.
2. Planner enters `450` in Revise Quantity.
3. **System Result:** The form displays the completed-quantity floor and the API returns HTTP 422. No job quantity, completion, snapshot, reservation, or ledger record is changed.

---

### Scenario 5: Job Cancellation with Anti-Delete Protection
1. Planner attempts to cancel Job `JOB-009` (Planned: 1,000, Completed: 530, Pending: 470, Worker holds 100 screws).
2. The UI blocks hard deletion: the `[Delete Job]` button does not exist; only `[Cancel Job]` is available.
3. System requires resolving the 100 screws: Operator returns screws to store counter via `[Return to Store]`.
4. Once worker custody is zero, Planner submits cancellation.
5. **System Result:** 530 completed units and past consumption records remain locked in the database. Pending 470 units are marked `CANCELLED`. Reservations for 470 units are released.

---

### Scenario 6: 5-Variable Quantity Lifecycle Accounting (520 $\to$ 450 $\to$ 100 Packed $\to$ 350 Cancelled)
1. **Initial Release:** Job `JOB-020` is released with `original_planned_quantity = 520`, `current_revised_quantity = 520`, `completed_quantity = 0`, `pending_quantity = 520`, `cancelled_quantity = 0`. UI displays `520 = 0 + 520 + 0 (Balanced)`.
2. **Revision:** Customer calls requesting a reduction to 450 units. Planner clicks **"Revise Quantity"**, inputs `450`, reason: *"Party request reduction"*.
   - System updates `current_revised_quantity = 450`, `pending_quantity = 450`.
   - UI status card displays: Original: `520`, Current: `450`, Completed: `0`, Pending: `450`, Cancelled: `0`. Check: `450 = 0 + 450 + 0`.
3. **Partial Production:** Operator packs 100 units. Enters completion on `/daily-plans/jobs/JOB-020/complete`.
   - System updates `completed_quantity = 100`, `pending_quantity = 350`.
   - UI displays: Current: `450`, Completed: `100`, Pending: `350`, Cancelled: `0`. Check: `450 = 100 + 350 + 0`.
4. **Cancellation of Remainder:** Line supervisor informs planner that finished components are out of stock and the remaining 350 units must be cancelled. Planner clicks **"Cancel Remainder"**.
   - System updates `cancelled_quantity = 350`, `pending_quantity = 0`, job status to `CANCELLED`.
   - UI displays: Original: `520`, Current: `450`, Completed: `100`, Pending: `0`, Cancelled: `350`. Check: `450 = 100 + 0 + 350 (Balanced)`.
   - **System Result:** Completed 100 units and consumption history are preserved; reservations for 350 units are freed; original 520 target remains visible in audit log.

---

### Scenario 7: Multi-Location Staging and Idempotent Network Replay
1. **Buffer Staging:** Storekeeper moves 200 corrugated cartons from `STORE_SHELF` (Shelf B-2) to `SHOP_FLOOR_BUFFER` (Packaging Line 1 Staging).
   - System posts `LOCATION_TRANSFER`. Both endpoints are active inventory-bearing leaf nodes; any parent display total remains descendant-derived. Total tracked physical stock remains unchanged at 1,500 PCS.
2. **Operator Issue:** Shift Lead issues 50 cartons from `SHOP_FLOOR_BUFFER` to Operator Ramesh (`WORKER_CUSTODY`).
   - Transaction `ISSUE_TO_WORKER` posted. Total company stock remains 1,500 PCS; Usable stock drops from 1,500 to 1,450 PCS; Worker custody rises from 0 to 50 PCS.
3. **Network Timeout & Idempotent Replay:** Operator Ramesh posts a completion batch with `Idempotency-Key: e1a3f5b0-...`.
   - The browser experiences a network interruption while waiting for the response.
   - The React frontend automatically retries the identical POST with the same `Idempotency-Key`.
   - **System Result:** PostgreSQL detects the existing key in `idempotency_keys` with `status = 'COMPLETED'`. The stored HTTP 201 response payload is replayed immediately without posting duplicate ledger movements or incrementing completed quantities twice.
