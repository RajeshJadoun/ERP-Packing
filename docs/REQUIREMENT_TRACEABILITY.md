# Requirement Traceability Matrix (RTM)

**Project:** Packing Material Inventory & BOM Management System  
**Document Version:** 1.10.0  
**Status:** Revised architectural blueprint — Phase 1.10 final schema/API alignment, protected operation accounting, and camelCase error reference alignment applied  
**Date:** 2026-10-19  

---

## 1. Overview & Verification Methodology

This matrix establishes bidirectional traceability between approved business requirements (Sections 3.A through 3.H), architectural decisions (ADRs), database schema entities across all 33 canonical tables, Flask REST API endpoints, user interface screens, and quality assurance acceptance tests.

---

## 2. Comprehensive Traceability Matrix

| Req ID | Requirement Description | Database Entities & Columns | API Endpoints | UI Screens | Test Scenarios | Architecture Ref |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **A.1** | Master Parties / Customers catalog | `parties` (`party_code`, `party_name`, `is_active`) | Direct PostgREST `/rest/v1/parties` | `/masters/parties` | Scenario 3 | ADR-001 |
| **A.2** | Finished Products catalog | `products` (`sku`, `product_name`, `default_party_id`) | Direct PostgREST `/rest/v1/products` | `/masters/products` | Scenarios 2, 3 | ADR-001 |
| **A.3** | Materials & Variant Specifications | `materials` (`category_id`, `canonical_unit_id`, typed dimensions, `additional_specs`) | Direct PostgREST `/rest/v1/materials` | `/masters/materials` | Scenarios 1, 11 | ADR-005, ADR-009, ADR-024 |
| **A.4** | Dynamic Admin Material Categories without code/schema changes | `material_categories` (`category_code`, `category_name`, `is_active`) | Direct PostgREST `/rest/v1/material_categories` | `/masters/categories` | Scenario 11 | ADR-009, ADR-015 |
| **A.5** | Vendors catalog & profile metadata | `vendors` (`vendor_code`, `vendor_name`, `tax_id_gstin`) | Direct PostgREST `/rest/v1/vendors` | `/masters/vendors` | Scenario 1 | ADR-001 |
| **A.6** | Hierarchical Locations & Strict Leaf-Only Movement Validation | `locations`, topology trigger, ledger posting validator (active leaf/type/history rules) | Direct PostgREST `/rest/v1/locations` | `/masters/locations` | Scenarios 6, 16, 21 | ADR-003, ADR-017, ADR-020, ADR-026 |
| **A.7** | Shop-floor Workers & linked virtual locations | `workers` (`worker_code`, `assigned_location_id`) | Direct PostgREST `/rest/v1/workers` | `/masters/workers` | Scenarios 2, 6, 7 | ADR-003 |
| **A.8** | Units of Measure & Exact vs Estimated Conversions | `units`, `material_conversions` (`conversion_factor`, `conversion_type`, `provenance_note`) | Direct PostgREST `/rest/v1/units`, `/material_conversions` | `/masters/conversions` | Scenario 1 | ADR-005, ADR-025 |
| **A.9** | User Accounts, Roles (RBAC), and Trusted Role Verification | `profiles`, `get_current_user_role()`, `admin_update_profile_access` RPC | `POST /api/v1/admin/users/{targetId}/access` | `/admin/users` | Scenario 20 | ADR-007, ADR-012, ADR-021 |
| **A.10** | Fail-Closed Profile Column Protection (`IS DISTINCT FROM 'ADMIN'`) | `profiles`, `trg_protect_profile_role`, `get_current_user_role()` (`SET search_path = ''`) | `PATCH /rest/v1/profiles` (Denied for role change) | `/admin/users` | Scenarios 14, 20 | ADR-012, ADR-021 |
| **A.11** | Multi-Location Stock Balance Accounting (6 Node Types) | `material_location_balances`, `locations` (`STORE_SHELF`, `RECEIVING_BAY`, `SHOP_FLOOR_BUFFER`, `WORKER_CUSTODY`, `DAMAGE_QUARANTINE`, `DISPATCH`) | `GET /api/v1/stock/balances` | `/inventory/stock` | Scenario 16 | ADR-017 |
| **B.1** | Vendor Purchase Orders & History | `purchase_orders`, `purchase_order_lines` (`status`, `ordered_quantity`) | `POST /api/v1/purchase-orders`, `GET /api/v1/purchase-orders/{id}` | `/purchasing/orders` | Scenario 1 | PRD Module 2 |
| **B.2** | Inward Goods Receipt (GRN) posting with Anti-Cascade Protection | `goods_receipts`, `goods_receipt_lines` (`ON DELETE RESTRICT`) | `POST /api/v1/goods-receipts/post`, `GET /api/v1/goods-receipts/{id}` | `/purchasing/inward` | Scenarios 1, 13 | ADR-002, ADR-013, ADR-023 |
| **B.3** | Separate Purchase Date, Invoice Date & Received Date | `goods_receipts.invoice_date` vs `received_date`, `purchase_orders.order_date` | `POST /api/v1/goods-receipts/post` | `/purchasing/inward` (Distinct date inputs) | Scenario 1 | PRD Module 2 |
| **B.4** | Inward Packaging Units, Scale Weight, PCS & Provenance | `goods_receipt_lines` original measurement, rule IDs, frozen factor/direction/classification, canonical result | `POST /api/v1/goods-receipts/post` request/response | `/purchasing/inward` (Server Result panel) | Scenarios 1, 22 | ADR-023, ADR-025 |
| **B.5** | Trusted Rejected & Accepted Quantity Calculation | server-calculated `accepted_qty`; explicit `rejected_unit_id`; no client canonical authority | `POST /api/v1/goods-receipts/post` | `/purchasing/inward` | Scenario 1 | PRD Module 2, ADR-023 |
| **B.6** | Purchase Order does not increase stock; only GRN does | `purchase_orders` (No stock transaction linked) | `POST /api/v1/purchase-orders` | `/purchasing/orders` | Unit Test `test_po_no_stock_effect` | ADR-002 |
| **C.1** | Canonical Stock Units per material variant | `materials.canonical_unit_id` plus post-activity immutability trigger | `GET /api/v1/stock/balances` | `/inventory/stock` | Scenarios 1, 22 | ADR-005, ADR-024 |
| **C.2** | Exact vs Estimated Conversions (25 KG ≈ 2500 PCS) | append-only `material_conversions`; frozen rule ID/factor/direction/classification | `GET /api/v1/stock/balances` | `/inventory/stock` (Dual-unit display with `≈`) | Scenarios 1, 22 | ADR-005, ADR-025 |
| **C.3** | Strict Prevention of Cross-Unit Addition | `stock_transactions` (Enforces canonical unit FK) | `POST /api/v1/stock/...` | Frontend Validation Engine | Scenario 1 | ADR-005 |
| **C.4** | Loose Material Ground Rule: Capture measurement method | `stock_transactions.measurement_method`, `conversion_factor` | `POST /api/v1/stock/issue-to-worker` | `/worker-custody/issue` (Method dropdown) | Scenario 6 | MRD Sec 2.3, ADR-014 |
| **C.5** | Signed Stock Ledger Aggregation & Atomic Projections | `stock_transactions`, `material_location_balances` | `GET /api/v1/stock/ledger`, `/balances` | `/inventory/stock` (Balances & Ledger tabs) | Scenario 6 | ADR-002, ADR-010 |
| **C.6** | Material Reservations (Affects available, not physical) | `stock_reservations` (`reserved_quantity`, `status`) | `POST /api/v1/daily-plans/{id}/release` | `/inventory/stock` (Reserved column) | Scenarios 3, 4 | SYSTEM_DESIGN Sec 4.1 |
| **C.7** | Worker Material Custody Tracking | `stock_transactions` (`movement_type = 'ISSUE_TO_WORKER'`) | `POST /api/v1/stock/issue-to-worker` | `/worker-custody/issue` | Scenario 6 | ADR-003 |
| **C.8** | Unused Stock Return & Segregated Quarantine / Disposal | `stock_transactions` (`RETURN_FROM_WORKER`, `DAMAGE_QUARANTINE`, `SCRAP_DISPOSAL`) | `POST /api/v1/stock/return-from-worker`, `/damage-quarantine`, `/scrap-disposal` | `/worker-custody/return`, `/inventory/quarantine` | Scenarios 6, 12 | ADR-003, ADR-011 |
| **C.9** | Cycle Count Adjustments with Single-Direction FK | `stock_adjustments`, `stock_transactions.stock_adjustment_id` | `POST /api/v1/stock/adjustments` | `/inventory/adjustments` | Scenarios 6, 17 | ADR-002, ADR-018 |
| **C.10** | Exhaustive movement references, directions & origins | `chk_stock_movement_reference_integrity`, posting trigger/procedure | All `/api/v1/stock/*` commands | Stock movement forms | Scenarios 17, 21 | ADR-020 |
| **D.1** | Single Active BOM Version per Recipe Key | `boms`, partial unique index `idx_boms_single_active_version` | `POST /api/v1/boms`, `/boms/{id}/activate` | `/boms` | Scenarios 2, 8 | PRD Module 5, ADR-015 |
| **D.2** | Party-Specific BOM Overrides | `boms.party_id` (Nullable FK to `parties`) | `POST /api/v1/boms` | `/boms` (Party selector) | Scenario 3 | MRD Section 3.2 |
| **D.3** | Master BOM Versioning with Revision Audit Event | `boms.version_number`, `bom_revision_events` | `POST /api/v1/boms/{id}/new-version` | `/boms` (Release Version modal) | Scenario 8 | ADR-004 |
| **D.4** | Immutable BOM Snapshots on Released Jobs | `packing_job_bom_snapshots`, `snapshot_lines` (`ON DELETE RESTRICT`) | `POST /api/v1/daily-plans/{id}/release` | `/daily-plans/jobs/:id` (Snapshot table) | Scenarios 8, 13 | ADR-004, ADR-013 |
| **D.5** | Completely Customized & Ad-hoc Packing Snapshots | nullable `packing_jobs.master_bom_id`; source-less snapshot and complete immutable lines | `POST /api/v1/daily-plans`, release | `/daily-plans` (Custom Job Builder) | Scenarios 8, 19 | MRD Sec 3.3, ADR-019 |
| **E.1** | Manual Daily Packing Plan with Shift Grouping | `daily_plans` (`shift_code`, `status`), `packing_jobs` | `POST /api/v1/daily-plans`, `GET /api/v1/daily-plans/{id}` | `/daily-plans` (Scheduler) | Scenario 3 | PRD Module 6, ADR-015 |
| **E.2** | Repeated Party and Product with Different BOMs/Specs | `packing_jobs` (No unique constraint on party+product+plan) | `POST /api/v1/daily-plans` | `/daily-plans` (Multi-row grid) | Scenario 3 | MRD Section 4.1 |
| **E.3** | In-Shift Quantity Revision (520 $\to$ 450 Units) | revision procedure rejects `revised_quantity < completed_quantity` | `POST /api/v1/packing-jobs/{id}/revise-quantity` (422 floor violation) | `/daily-plans/jobs/:id` (Revise modal) | Scenarios 4, 15 | ADR-022 |
| **E.4** | 5-Variable Quantity Conservation Invariant | `packing_jobs` (`original_planned_quantity`, `current_revised_quantity`, `completed_quantity`, `pending_quantity`, `cancelled_quantity`) | `POST /api/v1/packing-jobs/{id}/revise-quantity`, `GET /api/v1/packing-jobs/{id}` | `/daily-plans/jobs/:id` (Quantity Status Card) | Scenario 15 | ADR-016 |
| **F.1** | Safe Job Cancellation Reconciling Custody & Output | `packing_jobs.status = 'CANCELLED'`, `packing_job_events` | `POST /api/v1/packing-jobs/{id}/cancel` | `/daily-plans/jobs/:id` (Cancel Wizard) | Scenarios 5, 15 | SYSTEM_DESIGN Sec 5.1, ADR-016 |
| **F.2** | Partial Production Completion (1,000 $\to$ 530 Packed) | `production_completions` (`completed_units`), `packing_jobs.pending_quantity` | `POST /api/v1/production/completions`, `GET /api/v1/production/completions/{id}` | `/daily-plans/jobs/:id/complete` | Scenario 2 | PRD Module 7 |
| **F.3** | Anti-Cascade Deletion Protection on Production History | Foreign keys use `ON DELETE RESTRICT` across all operational tables | Database Schema Constraint | Application UI | Scenario 13 | ADR-013 |
| **F.4** | Theoretical Backflush with Unverified Variance Status | `material_consumption_records` (`theoretical_quantity`, `posted_ledger_quantity`, nullable `variance_quantity`, `variance_status = 'UNVERIFIED'`) | `POST /api/v1/production/completions` | `/daily-plans/jobs/:id/complete` (Consumption Breakdown) | Scenario 2 | MRD Sec 5.2, ADR-014 |
| **F.5** | Two-Tier Replay-Safe Idempotency & Ephemeral Response Retention | `idempotency_keys` (permanent header), `idempotency_responses` (ephemeral cache), JWT `owner_id`, normalized `operation_scope`, canonical SHA-256 hash, HTTP 410 expiry | All transactional write endpoints with `Idempotency-Key` header | Frontend API Client | Scenarios 7, 23–40 | ADR-018, ADR-027, ADR-028, ADR-029, ADR-030, ADR-031 |
| **G.1** | Material Issue as Custody Transfer, not Consumption | `stock_transactions` (`movement_type = 'ISSUE_TO_WORKER'`) | `POST /api/v1/stock/issue-to-worker` | `/worker-custody/issue` | Scenario 6 | ADR-003 |
| **G.2** | Separate Theoretical BOM Usage from Confirmed Usage | `material_consumption_records` (`theoretical_quantity`, `posted_ledger_quantity`, `consumption_policy`) | `POST /api/v1/production/completions` | `/daily-plans/jobs/:id/complete` (Theoretical vs Actual) | Scenario 2 | MRD Sec 5.2, ADR-014 |
| **G.3** | Material Consumption Variance Tracking | `material_consumption_records.variance_quantity` (Nullable until physical verification) | `POST /api/v1/production/completions` | `/daily-plans/variance` | Scenario 2 | PRD Module 7 |
| **H.1** | Shift-Aware Daily Closing Summary & Composite Alignment | `daily_closings`, `FOREIGN KEY (daily_plan_id, shift_code) REFERENCES daily_plans(id, shift_code)` | `POST /api/v1/closings`, `GET /api/v1/closings/{id}` | `/closings` | Scenarios 10, 18 | PRD Module 8, ADR-015 |
| **H.2** | Discrepancy Detection & Authorized Supervisor Override | `daily_closings.override_reason`, `unresolved_discrepancies_count` | `POST /api/v1/closings` (With override payload) | `/closings` (Override Modal) | Scenario 10 | OPEN_DECISIONS #7 |
| **H.3** | Comprehensive Operational Reports & Ledger Audits | Views: `vw_stock_by_location`, `vw_worker_custody`, `vw_variance_summary` | `GET /api/v1/reports/*` | `/reports/*` | Scenarios 1, 6, 10, 16 | PRD Module 8, ADR-017 |
