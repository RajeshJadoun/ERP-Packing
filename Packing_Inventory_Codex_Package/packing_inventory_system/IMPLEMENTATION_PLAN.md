# Implementation Plan
1. Inspect repository and report current stack, risks and existing code.
2. Add PRD, MRD, system design, UI/UX walkthrough and test plan.
3. Build Supabase migrations, constraints, indexes and RLS.
4. Build Flask config, auth, error handling, services and tests.
5. Implement masters and purchase/inward.
6. Implement ledger, locations, worker custody, returns, transfers, damage and adjustment.
7. Implement BOM versioning and immutable snapshots.
8. Implement daily plans/jobs, revision/cancellation, reservation and shortages.
9. Implement completion, consumption, variance and closing.
10. Build React UI and reports.
11. Run tests, lint, build, security checks; fix failures and document walkthrough.

Do not call the system production-ready until migrations run cleanly, tests actually execute, RLS is verified, stock commands are atomic/idempotent and acceptance scenarios pass.
