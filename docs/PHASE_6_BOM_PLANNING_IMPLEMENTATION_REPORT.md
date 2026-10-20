# Phase 6 BOM & Planning Implementation Report

**Status:** Implemented on `phase-6/bom-planning`; local CI validation passed. The hosted Supabase migration has not yet been applied.
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

The clean local database test workflow applied this migration and passed all 11 pgTAP test files (260 assertions), including BOM activation/supersession, multi-job plan creation, custom recipes, reservations, job quantity conservation, and proof that activating a later BOM version does not rewrite a released job's frozen snapshot.

## Rollout boundary

CI validates a fresh local Supabase database. It does **not** mean the linked hosted project or backend deployment has been changed. Merge this PR first, then apply the tested migration to the linked Supabase project and run post-migration checks before treating Phase 6 as live.
