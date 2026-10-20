# ERP-Packing Operational Walkthrough & System Acceptance Matrix

**Date:** 2026-10-20  
**Project:** Packing Material Inventory & BOM Management ERP  
**Scope:** Phase 8 Closure Audit, Phase 9 Reporting Verification, and Phase 10 End-to-End Acceptance  
**Frontend Suite:** Vitest (35 passed, 7 test suites, 0 vulnerabilities)  
**Backend Suite:** Pytest (101 passed, 21 test suites, Ruff 0 errors)  
**Database Test Suite:** pgTAP (13 test suites, 33 tables with RLS + FORCE RLS, 6 security-invoker views)  
**Authoritative Invariant Gates:**
- Quantity Conservation: `current_revised_quantity = completed_quantity + pending_quantity + cancelled_quantity`
- Available Inventory: `available_quantity = on_hand_quantity - reserved_quantity` (strictly leaf-only, usable locations)
- Unverified Variance: Theoretical backflush preserves variance as `UNVERIFIED` / `NULL`, never fabricated zero
- Two-Tier Idempotency: Permanent `idempotency_keys` with atomic request hashes; expired replays return HTTP 410
- Profile Protection: Server-resolved JWT subject; fail-closed trigger forbids non-admin mutation of role and status

---

## 1. Executive Summary & Verification Disposition

This document provides the authoritative acceptance matrix for all 18 core operational scenarios across the Packing Material Inventory & BOM Management ERP. Every scenario is evaluated against automated test fixtures, static contracts, database constraints, and actual system execution.

### Verification Status Classification:
- **PASS:** Fully verified through automated unit, integration, and end-to-end tests across the real Flask API contract, frontend React 19 SPA, and PostgreSQL relational invariants.
- **BLOCKED (Environment Dependency):** Functionality is verified through automated test suites and database migrations, but live end-to-end cloud validation against Supabase project `bkyzwdaazscsiocmefbn` is blocked pending external administrative provisioning of real Auth users and production cloud hosting deployment credentials.

---

## 2. 18 Operational Scenarios Acceptance Matrix

| Scenario ID | Business Goal & Workflow | User Role & Prerequisites | Steps & Expected Result | Automated Test Evidence | Actual Result | Status | Corrective Action / Resolution Runbook |
|---|---|---|---|---|---|---|---|
| **SC-01** | **User Authentication & Session Lifecycle**<br>Reject invalid/expired tokens, validate active profile. | Any Role<br>*Prereq:* Supabase Auth & JWT verifier configured. | 1. Access unauthenticated `/api/v1/health` → 200 OK.<br>2. Submit request with missing, expired, or tampered JWT → 401 UNAUTHORIZED.<br>3. Submit request with inactive profile → 403 FORBIDDEN. | `backend/tests/test_auth.py`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_a_authentication_and_access_control` | Health check returns `HEALTHY`. Missing/tampered/expired JWTs return 401. Inactive profile returns 403. | **PASS** | Cloud test against `bkyzwdaazscsiocmefbn` requires running the user provisioning runbook in Section 4. |
| **SC-02** | **Role-Based Access Control & Profile Protection**<br>Enforce strict RBAC and prevent self-promotion. | Non-Admin (`STOREKEEPER`, `OPERATOR`, `VIEWER`) | 1. Non-admin calls `POST /api/v1/admin/users/<id>/access` → 403 FORBIDDEN.<br>2. Direct PostgREST update to `public.profiles.role` → Rejected by `trg_protect_profile_role` (SQLSTATE 42501). | `backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_a_authentication_and_access_control`<br>`supabase/tests/security_rls.test.sql` | Non-admin role modification rejected with HTTP 403. Trigger enforces fail-closed role protection. | **PASS** | None. Handled by server RBAC and PostgreSQL fail-closed trigger. |
| **SC-03** | **Zero Secret Leakage in Client & Error Payloads**<br>Ensure `service_role` key and DB passwords never leak. | Any Caller | 1. Inspect client environment variables and build artifacts.<br>2. Trigger API errors and verify error JSON contains no DB credentials or service-role keys. | `frontend/src/lib/api.test.ts`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_a_authentication_and_access_control` | Vite build outputs zero secrets. Error responses conform to standardized `{error: {code, message}}`. | **PASS** | Strict CI gate enforces zero secrets in Git or client builds. |
| **SC-04** | **Master Catalog Management & Dynamic Specifications**<br>Manage material categories and JSON specifications. | `ADMIN` / `STOREKEEPER`<br>*Prereq:* Valid category exists. | 1. Create material category with custom specifications schema.<br>2. Create material with structured JSON specifications.<br>3. Verify canonical unit and validation. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("creates a dynamic material category")<br>`backend/tests/test_masters.py` | Category and material created. Specs JSON persisted without schema corruption. | **PASS** | None. PostgREST and Flask API enforce schema constraints. |
| **SC-05** | **Purchase Order Creation (Zero Stock Mutation)**<br>Create POs without altering inventory balances. | `STOREKEEPER`<br>*Prereq:* Active vendor and material. | 1. Submit `POST /api/v1/purchasing/orders` with line items.<br>2. Verify PO status is `OPEN`.<br>3. Verify stock balances remain unchanged. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("creates a purchase order")<br>`backend/tests/test_purchasing.py` | PO created in draft/open state. Querying `material_location_balances` confirms zero stock mutation. | **PASS** | None. POs are financial/contractual commitments, not stock ledger transactions. |
| **SC-06** | **Dual-Unit Receipt & GRN Posting**<br>Receive items with dual-unit conversion and accepted/rejected breakdown. | `STOREKEEPER`<br>*Prereq:* Open PO line. | 1. Preview dual-unit conversion (e.g. 50 BOX × 100 = 5000 PCS).<br>2. Post GRN with 4800 accepted and 200 rejected.<br>3. Verify ledger receives exactly 4800 canonical units. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("previews dual-unit receipt quantities")<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_b_purchasing_and_grn_posting` | Trusted RPC computes accepted quantity and credits stock ledger. Provenance stored. | **PASS** | None. Unit conversion provenance is immutable on the receipt record. |
| **SC-07** | **Idempotent GRN Replay & Concurrency Protection**<br>Prevent duplicate stock credits on request retries. | `STOREKEEPER`<br>*Prereq:* Existing GRN post. | 1. Send GRN post with `Idempotency-Key: X`.<br>2. Re-send identical request with `Idempotency-Key: X` → Returns cached 200 OK.<br>3. Verify inventory is NOT credited twice. | `backend/tests/test_idempotency.py`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_b_purchasing_and_grn_posting` | Replay returns identical response payload without re-executing ledger credit. | **PASS** | Handled by Table 31 `idempotency_keys` and Table 32 `idempotency_responses`. |
| **SC-08** | **Leaf-Only Location Topology & Balance Calculation**<br>Ensure stock exists only in leaf locations and parent nodes never hold stock. | `STOREKEEPER`<br>*Prereq:* Location hierarchy. | 1. Query stock balances across location tree.<br>2. Verify parent locations report 0 on-hand.<br>3. Verify available quantity equals `on_hand - reserved`. | `backend/tests/test_stock_engine.py`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_c_inventory_custody_and_movements` | Leaf-only check constraint rejects postings to non-leaf locations. Available balance matches formula. | **PASS** | Database trigger forbids converting locations with inventory into parent nodes. |
| **SC-09** | **Worker Material Custody Issue & Return**<br>Track materials issued to floor workers separately from warehouse stock. | `STOREKEEPER`<br>*Prereq:* Usable stock available. | 1. Post `ISSUE_TO_WORKER` for 100 units → Deducts warehouse, credits worker custody.<br>2. Post `RETURN_FROM_WORKER` for 15 unused units → Deducts custody, credits warehouse. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("issues material to worker custody")<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_c_inventory_custody_and_movements` | Balances updated atomically. Worker custody is segregated from available warehouse inventory. | **PASS** | None. Dedicated `vw_worker_custody_balance` reports current balances. |
| **SC-10** | **Quarantine Isolation & Scrap Disposal**<br>Segregate defective material from usable stock and record disposal. | `STOREKEEPER`<br>*Prereq:* Usable stock exists. | 1. Post `MOVE_TO_QUARANTINE` → Deducts usable, moves to quarantine location.<br>2. Post `SCRAP_DISPOSAL` with authorized reason → Deducts quarantine stock permanently. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("keeps quarantine moves and scrap disposal as distinct")<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_c_inventory_custody_and_movements` | Quarantined material excluded from usable available stock. Scrap disposal requires mandatory reason. | **PASS** | None. Quarantine locations have classification `QUARANTINE` with zero usable availability. |
| **SC-11** | **BOM Versioning & Single Active Version Index**<br>Support multiple versions; enforce single active version per party/product. | `PLANNER`<br>*Prereq:* Product & Party masters. | 1. Create BOM V1 (status `ACTIVE`).<br>2. Create BOM V2 (status `DRAFT`).<br>3. Attempt to activate V2 without superseding V1 → Enforced single active version partial index. | `backend/tests/test_boms.py`<br>`supabase/tests/bom_and_planning.test.sql` | Activating second active version is rejected by partial unique index `idx_boms_single_active_version`. | **PASS** | Transition procedure atomically deactivates V1 when promoting V2. |
| **SC-12** | **Daily Plan Creation & Frozen Job Snapshots**<br>Release daily plans and freeze BOM specifications into jobs. | `PLANNER`<br>*Prereq:* Active BOMs. | 1. Create daily plan with master-derived and custom recipe jobs.<br>2. Release plan → Creates reservations and freezes BOM lines into `packing_job_bom_snapshots`. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("creates a shift plan with repeated product/party jobs")<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_d_bom_planning_production_closing` | Snapshots frozen at release time. Subsequent changes to master BOM do not alter released jobs. | **PASS** | Anti-cascade foreign keys (`ON DELETE RESTRICT`) prevent deleting released plans. |
| **SC-13** | **Job Quantity Revision (520 → 450) & Conservation**<br>Enforce 5-variable quantity conservation equation on revisions. | `PLANNER`<br>*Prereq:* Active released job. | 1. Job initially: planned=520, completed=100, pending=420, cancelled=0.<br>2. Revise to 450 → pending becomes 350.<br>3. Conservation check: 450 = 100 + 350 + 0.<br>4. Attempt revision below completed (e.g. 90) → 422 Unprocessable Entity. | `frontend/src/pages/OperationsWorkflows.test.tsx` ("revises a job from 520 to 450")<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_d_bom_planning_production_closing` | Revision succeeds; reservations adjusted by -70. Revision below completed quantity rejected. | **PASS** | Enforced by PostgreSQL CHECK `chk_packing_jobs_quantity_conservation`. |
| **SC-14** | **Job Curtailment & Cancellation**<br>Cancel uncompleted job quantities without affecting completed units. | `PLANNER`<br>*Prereq:* Active released job. | 1. Submit `POST /api/v1/packing-jobs/<id>/cancel` with mandatory reason.<br>2. Completed units preserved; pending becomes 0; cancelled becomes remaining.<br>3. Reservations released. | `backend/tests/test_planning.py`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_d_bom_planning_production_closing` | Status updated to `CANCELLED`. Conservation equation holds: `revised = completed + 0 + cancelled`. | **PASS** | Audit trail logs reason, timestamp, and user ID. |
| **SC-15** | **Production Output & Consumption Verification Mode**<br>Distinguish theoretical auto-deduction from verified physical counts. | `OPERATOR` / `STOREKEEPER`<br>*Prereq:* Released packing job. | 1. Post completion with `AUTO_BOM_THEORETICAL` → Consumption variance remains `UNVERIFIED` / `NULL`.<br>2. Post completion with `CONFIRMED_ACTUAL_ENTRY` and scale measurements → Variance recorded. | `frontend/src/pages/reports/ReportsAnalytics.test.tsx` ("renders unverified physical consumption as Not verified")<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_d_bom_planning_production_closing` | Unverified consumption is NEVER converted to zero. UI renders "Not verified (Auto BOM)" badge. | **PASS** | Prevents false accounting reconciliation. Variance status enum: `UNVERIFIED`, `EXACT`, `OVER_CONSUMPTION`, `UNDER_CONSUMPTION`. |
| **SC-16** | **Shift Closing, Discrepancy Gate & Reopening**<br>Close shifts with audit checklist; require supervisor override for discrepancies. | `STOREKEEPER` / `ADMIN`<br>*Prereq:* Open shift with jobs. | 1. Submit shift close without override when discrepancies exist → 422 Unprocessable.<br>2. Submit shift close with supervisor override and reasons → Status `CLOSED`.<br>3. Reopen shift (Admin only) → Status `REOPENED` with audit entry. | `backend/tests/test_closing.py`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_d_bom_planning_production_closing` | Discrepancy gate blocks close until resolved or overridden. Reopen audited and restricted. | **PASS** | Enforced by `rpc_close_daily_plan` and `rpc_reopen_daily_closing`. |
| **SC-17** | **Operational Reporting Views & PostgREST Filtering**<br>Query 6 analytics views with strict parameter validation and export. | Any Authenticated Role<br>*Prereq:* Active JWT. | 1. Query `/api/v1/reports/stock` with `locationId` filter → 200 OK.<br>2. Pass unsupported parameter (e.g. `fromDate` to snapshot) → 400 Bad Request.<br>3. Conjunction date range filters (`fromDate` + `toDate`) filter correctly.<br>4. Export CSV with proper escaping. | `frontend/src/pages/reports/ReportsAnalytics.test.tsx`<br>`backend/tests/test_reports.py`<br>`backend/tests/test_phase10_e2e_verification.py::test_phase10_pillar_e_reporting_and_analytics` | Parameter validation rejects unsupported keys. Date conjunctions apply cleanly. CSV correctly quoted. | **PASS** | Views execute with `security_invoker=true`. Underlying table RLS remains authoritative. |
| **SC-18** | **Live Production Cloud Deployment & Smoke Test**<br>End-to-end verification of deployed SPA and Flask API against Supabase Cloud. | All Roles<br>*Prereq:* Cloud hosting credentials & provisioned Auth users. | 1. Deploy Vite SPA to hosting provider (e.g. Vercel, Netlify, Cloudflare).<br>2. Deploy Flask API to cloud container (e.g. Cloud Run, Render, Fly.io).<br>3. Log in with real Auth user, verify `/health`, execute one write and one report. | *Pending Cloud Credentials* | Automated tests PASS; cloud deployment blocked pending provider access and user creation. | **BLOCKED** | Follow Section 4 runbook to provision test users in Supabase and deploy containerized services. |

---

## 3. Operational Invariant Verification Summary

### 1. Quantity Conservation Invariant
```
Current Revised Quantity = Completed Quantity + Pending Quantity + Cancelled Quantity
```
- **Validation:** Tested in `test_phase10_pillar_d_bom_planning_production_closing` and frontend `OperationsWorkflows.test.tsx`.
- **Database Enforcement:** PostgreSQL table check constraint `chk_packing_jobs_quantity_conservation` on `packing_jobs`.

### 2. Available Stock Invariant
```
Available Quantity = On Hand Quantity - Reserved Quantity
```
- **Validation:** Tested in `test_phase10_pillar_c_inventory_custody_and_movements`.
- **Database Enforcement:** Calculated dynamically in `vw_stock_by_location` and stored procedures. `CHECK (on_hand_quantity >= 0)` ensures non-negative inventory balances.

### 3. Consumption Variance Preservation Invariant
```
If completion_policy == 'AUTO_BOM_THEORETICAL' THEN
  physical_quantity = NULL
  variance_quantity = NULL
  variance_status = 'UNVERIFIED'
```
- **Validation:** Tested in `ReportsAnalytics.test.tsx` and `test_phase10_pillar_e_reporting_and_analytics`. Unverified variance is never defaulted or converted to 0.00.

### 4. Idempotency Lock and Replay Invariant
```
Header: Idempotency-Key
Hash: SHA-256(canonical_request_body)
Owner: JWT.sub
Scope: METHOD:/api/v1/path
```
- **Validation:** Tested in `test_idempotency.py` and `test_phase10_pillar_b_purchasing_and_grn_posting`. Repeated submissions return cached HTTP response; mismatched payloads or owners return HTTP 409 conflict.

---

## 4. Runbook: Unblocking Live Cloud Environment (SC-18)

When production hosting credentials and administrative Supabase access are provided, execute the following steps to achieve full live cloud verification:

### Step 1: Provision Initial Administrator & Test Users in Supabase
Run the following SQL snippet using the Supabase SQL Editor or `psql` connection to project `bkyzwdaazscsiocmefbn`:
```sql
-- 1. Create auth user in auth.users (or use Supabase Dashboard > Authentication > Add User)
-- Replace with the real user UUID generated by Supabase Auth:
-- INSERT INTO auth.users (id, email, ...) VALUES ('00000000-0000-0000-0000-000000000001', 'admin@packing-erp.local', ...);

-- 2. Insert corresponding profile in public.profiles:
INSERT INTO public.profiles (id, full_name, role, is_active)
VALUES 
  ('00000000-0000-0000-0000-000000000001', 'System Administrator', 'ADMIN', true),
  ('00000000-0000-0000-0000-000000000002', 'Storekeeper User', 'STOREKEEPER', true),
  ('00000000-0000-0000-0000-000000000003', 'Production Planner', 'PLANNER', true),
  ('00000000-0000-0000-0000-000000000004', 'Floor Operator', 'OPERATOR', true),
  ('00000000-0000-0000-0000-000000000005', 'Auditor Viewer', 'VIEWER', true)
ON CONFLICT (id) DO UPDATE 
SET role = EXCLUDED.role, is_active = EXCLUDED.is_active;
```

### Step 2: Deploy Backend Flask API
```bash
cd backend
# Build container:
docker build -t packing-erp-backend:latest .

# Deploy to Google Cloud Run / AWS ECS / Render with required environment variables:
# APP_ENV=production
# SUPABASE_URL=https://bkyzwdaazscsiocmefbn.supabase.co
# SUPABASE_ANON_KEY=<anon_key>
# SUPABASE_JWT_SECRET=<jwt_secret>
# DATABASE_URL=<postgres_connection_string>
# CORS_ALLOWED_ORIGINS=https://app.packing-erp.local
```

### Step 3: Deploy Frontend React SPA
```bash
cd frontend
# Build production bundle:
npm run build

# Deploy dist/ directory to Vercel / Cloudflare Pages / AWS S3 + CloudFront with:
# VITE_SUPABASE_URL=https://bkyzwdaazscsiocmefbn.supabase.co
# VITE_SUPABASE_ANON_KEY=<anon_key>
# VITE_API_BASE_URL=https://api.packing-erp.local/api/v1
```

### Step 4: Execute Live Smoke Test
1. Open deployed web URL in a browser.
2. Sign in with `admin@packing-erp.local`.
3. Verify top navigation bar displays `Backend: Connected` and user role `ADMIN`.
4. Navigate to Reports > Stock By Location and verify empty/seed balances load.
5. Post a draft PO and verify status is `OPEN`.
