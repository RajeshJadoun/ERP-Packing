# Phase 6 BOM & Planning Implementation Report

**Status:** Merged to `main`, applied to the linked Supabase project, and post-migration verified.
**Date:** 2026-10-20

- Repository: [RajeshJadoun/ERP-Packing](https://github.com/RajeshJadoun/ERP-Packing)
- Pull request: [#5 — Phase 6 BOM versioning, daily planning and reservations](https://github.com/RajeshJadoun/ERP-Packing/pull/5)
- Backend CI: [Flask Backend Tests](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39424400581) — 78 pytest tests passed; Ruff passed.
- Database CI: [Supabase Database Tests](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39424400662) — 260 pgTAP assertions across 11 suites passed.

## What was implemented

### BOM versioning
- Added atomic RPCs to create a draft BOM, create a new recipe version and activate a version.
- Activation supersedes the existing active recipe version inside the same transaction before promoting the new version.
- BOM recipes reject empty/duplicate lines, inactive materials, unknown units, invalid quantities and unavailable unit conversions.
- A recipe-key transaction lock serializes version changes. Existing uniqueness on the active recipe is preserved.

### Daily plans and custom jobs
- Added atomic daily-plan creation with multiple master-derived jobs, repeated party/product combinations and source-less custom jobs.
- Custom jobs create their own frozen, conversion-aware BOM snapshot without inventing a source master BOM.
- Released master-derived jobs receive immutable recipe snapshots with frozen conversion provenance.

### Plan release and reservations
- Plan release validates every draft job and recipe snapshot, locks material/location keys in a consistent order, checks available stock after existing reservations and allocates material reservations atomically.
- Insufficient unreserved stock causes the transaction to roll back rather than partially release a plan.
- Stock ledger posting is hardened so ordinary outward movements cannot consume inventory held by active reservations.
- Job-specific worker issuance consumes only matching reservations for the selected job, material and source location.

### Revisions and cancellation
- Added idempotent API RPC wrappers for job revision and cancellation.
- Reservation changes are reconciled when a released job quantity changes.
- Revisions below completed production are rejected; cancellation preserves completed output and enforces:
  `current_revised_quantity = completed_quantity + pending_quantity + cancelled_quantity`.

### Flask API
- Added authenticated BOM routes for create, detail, new version and activation.
- Added daily-plan create/detail/release routes and packing-job detail/revise/cancel routes.
- Requests are schema-validated; mutations use the verified caller JWT and transactional RPCs. No service-role credential was added.

## Database migration and tests

Migration: `supabase/migrations/20261020080000_phase_6_bom_planning.sql`

New test suite: `supabase/tests/phase_6_bom_planning.test.sql`

The clean local database test workflow applied this migration and passed all 11 pgTAP test files (260 assertions), including BOM activation/supersession, multi-job plan creation, custom recipes, reservations, job quantity conservation, and proof that activating a later BOM version does not rewrite a released job's frozen snapshot. The same tested migration was then applied to the linked hosted Supabase project and recorded as `phase_6_bom_planning`.

## Post-migration verification

The linked Supabase project records migration `phase_6_bom_planning` (version `20261020124710`). Read-only verification returned:

- Four Phase 6 lifecycle columns on `daily_plans`.
- Nine expected Phase 6 RPC/helper functions present.
- Zero direct `INSERT` / `UPDATE` / `DELETE` policies left on `boms`, `bom_lines`, `daily_plans`, and `packing_jobs`.
- RLS enabled on all 33 core public tables.
- Existing `idx_boms_single_active_version` index present.
- `authenticated` can call the approved BOM-create and plan-release RPCs, but cannot execute the private BOM JSON helper.

**Deployment boundary:** This phase's database migration is applied. The Flask server itself has not been deployed or configured with runtime secrets; no claim is made that the operational HTTP routes are live on a public URL.
