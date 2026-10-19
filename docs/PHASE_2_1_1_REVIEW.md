# Phase 2.1.1 Review — Final Security and Transactional Hardening

**Repository:** `RajeshJadoun/ERP-Packing`

## Remediation included

1. Idempotency acquisition uses an atomic insert-on-conflict path, followed by row locking to classify replay/conflict.
2. Idempotency records are bound to `auth.uid()`; completion only finishes the owner's own `PROCESSING` record.
3. Eight stock/purchasing RPCs compute SHA-256 fingerprints from actual business arguments instead of trusting the client hash.
4. Release, revise and cancel job RPCs require idempotency keys and cache responses. Revision prevents impossible quantities below completed plus cancelled units.
5. Goods receipt posting stores the server-selected conversion rule, credits PO quantities in the PO line unit, and rejects over-receipt.
6. Multiple purchase-order lines can now contain the same material; GRN lines still allocate to an explicit PO line.
7. Public/anonymous execution grants are revoked from operational SECURITY DEFINER RPCs. Private helpers remain inaccessible to API roles.
8. BOM release freezes canonical quantity and conversion provenance for each BOM line.
9. Shift closings enforce non-negative quantities and planned = completed + pending + cancelled at the database constraint level.
10. Profile-role protection permits first-admin bootstrap only from a direct database-administrator session.
11. Regression pgTAP coverage was expanded for request hashing, ACLs, PO unit conversion and BOM conversion snapshots.

## Verification boundary

- GitHub Actions successfully applied all migrations to a fresh local Supabase stack and ran the full pgTAP suite: **8 test files, 173 tests, Result: PASS**.
- The successful push run is [here](https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39316427157); pull-request validation also passed on commit `461035f06fa4b446bde1c2b0739d368f870e0e6e`.
- The connected live Supabase project still reports zero public tables and zero recorded migrations. No schema was applied to the live project in this phase; the migration remains in the GitHub PR for review.
