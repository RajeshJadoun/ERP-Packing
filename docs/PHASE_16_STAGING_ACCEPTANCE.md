# Phase 16 — Staging Acceptance Gate

**Date:** 2026-10-22  
**Status:** Acceptance baseline established; full release acceptance is still blocked.  
**Scope:** Staging-only readiness and workflow validation. Keep Supabase Auth/PostgreSQL; no production writes.

## 1. What is verified

- PR #19 fixes an ambiguous Playwright locator in the purchase-order date validation scenario and is merged to `main`: https://github.com/RajeshJadoun/ERP-Packing/pull/19
- On the exact PR head commit `1efa38be32cab012e1fa235fdb40566c3d7822c2`, the authenticated staging E2E workflow completed with **47 passed**: https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39788818783
- The same PR head passed React frontend tests, Supabase database tests, and container build validation.
- Phase 15's read-only operational invariant audit had previously returned 7/7 checks with zero violations in both the production and staging projects. Run it again after acceptance transactions, before any release.

These results establish automated regression health; they are not proof that every real transactional workflow or every role has been tested against live staging data.

## 2. Readiness query

Run `scripts/staging_acceptance_readiness.sql` **only after confirming the Supabase Dashboard shows PACKING ERP STAGING** (project ref `pcrttrimxeoiabncnfan`). It contains SELECT statements only. It checks:

- one active profile for each required role: ADMIN, STOREKEEPER, PLANNER, OPERATOR and VIEWER
- minimally available active master data and workflow records to support staging acceptance

Expected output is 17 rows with `PASS` for each row. `BLOCKED` means the relevant staging user or fixture prerequisite is missing. The query never creates accounts, edits profiles, posts transactions, or deletes records.

### Baseline observed on 2026-10-22

The readiness query was executed read-only against staging:

| Area | Observed | Status |
|---|---:|---|
| Active ADMIN profile | 1 | PASS |
| Active STOREKEEPER profile | 0 | BLOCKED |
| Active PLANNER profile | 0 | BLOCKED |
| Active OPERATOR profile | 0 | BLOCKED |
| Active VIEWER profile | 0 | BLOCKED |
| Active vendors | 1 | PASS |
| Active materials | 2 | PASS |
| Active products | 1 | PASS |
| Active BOMs | 1 | PASS |
| Units | 8 | PASS |
| Active leaf locations | 4 | PASS |
| Active workers | 1 | PASS |
| Purchase orders | 1 | PASS |
| Goods receipts | 1 | PASS |
| Daily plans | 1 | PASS |
| Packing jobs | 1 | PASS |
| Production completions | 1 | PASS |

**Current blocker:** the staging project has one active ADMIN profile and no active profile for the other four roles. Do not infer role-level authorization from the passing E2E run: it uses the available staging admin credentials. Complete the role matrix before claiming all-role acceptance.

## 3. Acceptance procedure

1. **Provision role users safely.** Create or invite staging-only Auth users through the approved Supabase Auth/admin process and assign their application roles using the approved, audited application flow. Do not insert directly into `auth.users`, bypass role-protection triggers, or edit role fields using unreviewed SQL.
2. **Verify the five-role authorization matrix.** For each role, test at least one allowed operation and one forbidden operation. Confirm that VIEWER cannot perform writes and that protected profile-role changes and direct PostgREST stock-ledger writes are rejected for non-authorized clients.
3. **Exercise the business lifecycle in staging.** Use clearly identifiable staging-only test records and preserve their IDs in the evidence log:
   - purchase order validation and draft creation
   - GRN preview, posting and canonical unit conversion
   - stock ledger movement and balance reconciliation
   - BOM activation/versioning, planning and immutable job snapshots
   - production completion and consumption verification
   - worker issue/return and custody reconciliation
   - daily closing, unresolved discrepancy handling and authorized override
   - duplicate idempotency replay, payload-mismatch rejection and rollback behavior
4. **Prove persisted results.** Check the returned API result, corresponding transaction/history rows, audit event, and final balance/quantity equations. Do not treat a rendered UI or a mocked frontend test as proof of a committed database transaction.
5. **Run the Phase 15 read-only operational invariant audit again** against staging after the workflow exercises. Save the query output and the GitHub Actions links. Check that test records and historical audit/ledger records reconcile before any approved cleanup.
6. **Keep production untouched.** Do not replay mutation tests, insert fixtures, run cleanup SQL, or change auth/profile roles in the production project.

## 4. Release gate

Phase 16 acceptance is complete only when all of the following evidence is recorded:

- [ ] Readiness query returns `PASS` for all 17 checks in staging.
- [ ] Authenticated positive/negative tests pass for all five roles.
- [ ] PO-to-GRN-to-stock and BOM-to-planning-to-production-to-closing workflows pass using staging-only data.
- [ ] Duplicate requests do not duplicate ledger movement; a mismatched idempotency payload is rejected.
- [ ] Ledger/projection and quantity-conservation audits remain at zero violations after the acceptance run.
- [ ] Backup/restore and rollback procedure has been tested and recorded for the selected hosting arrangement.
- [ ] Final main-branch CI and authenticated staging E2E runs are green on the same release commit.

Until then, status remains **staging regression green; full production acceptance not yet certified**.
