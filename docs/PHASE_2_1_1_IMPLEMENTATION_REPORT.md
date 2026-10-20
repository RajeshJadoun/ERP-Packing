# Phase 2.1.1 Implementation Report

**Status:** Implemented, pushed to `main`, and applied to the linked Supabase project.  
**Validation:** GitHub Actions database-test run passed all 184 pgTAP assertions.

- Repository: [RajeshJadoun/ERP-Packing](https://github.com/RajeshJadoun/ERP-Packing)
- Validation run: [GitHub Actions run 39369320826](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39369320826)
- Test revision: `126e1048ee1966bda9c3acd83c565120cd341395`
- Supabase project: `PACKING ERP` (`bkyzwdaazscsiocmefbn`, `ap-south-1`)

## What changed

### Transaction and idempotency integrity
- Made idempotency acquisition safe under concurrent first requests using an atomic `INSERT ... ON CONFLICT` path.
- Preserved request key, owner, scope and payload-hash checks; completed requests replay their stored response.
- Made packing-job release, revision and cancellation retry-safe while preserving their existing RPC signatures.

### Goods receipt and unit conversions
- Added a private authoritative conversion resolver for same-unit, effective direct and inverse conversion rules.
- Recalculates accepted quantity from entered and rejected quantities after normalizing rejected units.
- Stores the conversion provenance used for the stock ledger and rejected quantity.
- Credits purchase-order received quantity in the PO line's unit and rejects over-receipt.

### Security and policy hardening
- Explicitly revoked API-role execution on private stock-posting, idempotency and trigger functions.
- Pinned trigger-function search paths.
- Kept public stock-changing RPCs accessible only to authenticated callers; RPCs check application role before applying operations.
- Corrected the daily-plan draft-only RLS correlation to compare linked jobs with the actual parent plan.
- Retained fail-closed RLS on idempotency tables.

### Performance and reconciliation
- Added 46 indexes for foreign-key lookup paths flagged by the Supabase advisor.
- Optimized the profile self-update policy's `auth.uid()` expression.
- Added the daily-closing conservation constraint requiring non-negative totals and:
  `planned = completed + pending + cancelled`.

## Database migrations

Phase 2.1.1 added these migrations under `supabase/migrations/`:

1. `20261020000001_phase_2_1_1_hardening.sql`
2. `20261020000002_performance_and_rls_indexes.sql`
3. `20261020000003_daily_plans_rls_correlation_fix.sql`
4. `20261020000004_daily_closing_conservation.sql`
5. `20261020000005_lock_down_trigger_function_privileges.sql`

They were applied to the linked Supabase project. The previous seven foundation/domain/security migrations are present as well.

## Validation

The GitHub Actions run starts a clean local Supabase stack, applies the repository migrations and runs `supabase test db`.

| Test suite | Assertions | Result |
|---|---:|---|
| `database_schema.test.sql` | 75 | PASS |
| `security_rls.test.sql` | 15 | PASS |
| `stock_ledger.test.sql` | 16 | PASS |
| `bom_and_planning.test.sql` | 13 | PASS |
| `idempotency.test.sql` | 12 | PASS |
| `purchasing.test.sql` | 12 | PASS |
| `closing_and_reconciliation.test.sql` | 10 | PASS |
| `phase_2_1_1_hardening.test.sql` | 31 | PASS |
| **Total** | **184** | **PASS** |

All eight suites also completed successfully when executed against the linked Supabase project. The test suites wrap their fixtures in transactions and roll back their test data.

## Remaining advisor notes

- No anonymous-executable `SECURITY DEFINER` function or mutable trigger search-path finding remained after the final hardening migration.
- The advisor reports two internal idempotency tables with RLS enabled and no policies. This is intentional fail-closed behavior; application access is through controlled server-side functions.
- It also reports authenticated-executable `SECURITY DEFINER` RPCs. These are intended authenticated API endpoints with server-side role checks, not anonymous RPCs.
- Unused-index notices remain on a newly initialized database because the indexes have not accumulated workload. They should be re-evaluated after real usage rather than removed prematurely.

**Scope note:** This phase covers database migrations, transactional RPCs, RLS/security and SQL tests. It does not deploy or validate a frontend/backend application release.
