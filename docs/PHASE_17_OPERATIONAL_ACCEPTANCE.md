# Phase 17 — Staging Operational Workflow Acceptance

**Status:** Harness prepared; the transactional acceptance run requires an explicit manual dispatch.  
**Environment:** Dedicated staging only — Supabase project ref `pcrttrimxeoiabncnfan`; API `https://packing-erp-staging-api.onrender.com/api/v1`.

## Latest pre-test baseline

- Staging readiness: 17/17 checks PASS.
- Phase 15 data invariants: the six transactional checks most recently executed returned PASS with zero violations; the separate RLS coverage audit had previously passed as part of the 7/7 audit.
- Phase 16.2 authorization matrix: 52/52 Playwright tests passed, including ADMIN, STOREKEEPER, PLANNER, OPERATOR and VIEWER role checks.
- Main-branch frontend, database, container and authenticated staging E2E CI all passed on merge commit `d2f7d4b0ec4fd2302a7ee21640a79347c571b7a8`.

This baseline does **not** mean the real persisted business transaction chain has been accepted yet.

## What the Phase 17 runner does

The dedicated manual workflow executes one isolated scenario using the existing `TEST-E2E-` staging master fixtures. It does not use normal factory materials, vendors, products, workers or production data.

1. Sign in as the staging ADMIN and verify the exact staging project/API.
2. Create a uniquely named test purchase order with two test materials.
3. Verify same-key idempotent replay returns the same PO and a payload-mismatched reuse is rejected.
4. Create a draft GRN in the test shelf, post it through the transactional API, verify authoritative line calculations/stock transaction IDs, replay the same posting request and confirm the balance delta was applied exactly once.
5. Create and release a new test-only daily plan from the known active TEST-E2E BOM.
6. Issue the required test materials to the test worker's dedicated custody location.
7. Record a production completion with physical quantities matching the frozen BOM; verify the persisted completion/consumption detail.
8. Close the test plan and verify completed/pending/cancelled quantity conservation.

## Explicit safety gate

The workflow is **manual-only**. It runs only when the operator selects `confirm_staging_mutations=true` on the GitHub Actions dispatch form. Its environment variables hard-lock the staging Supabase ref and staging API URL, and it fails closed if credentials or test fixtures are missing.

All created business records use a `TEST-E2E` naming/notes prefix where the schema allows. Posted stock transactions, completion history and audit rows are intentionally retained because the authoritative ledger is append-only. Do not run the acceptance workflow against production; do not attempt to delete immutable ledger history. If a clean staging environment is required afterward, reset/recreate the **staging project only** through the approved platform procedure.

## Running it

1. Merge the reviewed Phase 17 pull request after the ordinary frontend/database/container/staging CI is green.
2. Open **Actions → Staging Operational Acceptance → Run workflow**.
3. Choose the `main` branch and explicitly set `confirm_staging_mutations` to **true**.
4. Inspect the workflow report for the generated PO, GRN, plan, packing job, stock transactions, completion and closing IDs.
5. After success, rerun `scripts/operational_invariant_audit.sql` against the staging project and preserve the query output alongside the GitHub run link.

A passing run provides evidence for this exact seeded scenario, not a blanket certification for all manufacturing paths. Expand with conversion-edge, discrepancy, rollback and alternate-role transactional cases before any production rollout.
