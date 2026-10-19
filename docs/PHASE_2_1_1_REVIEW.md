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
9. Profile-role protection permits first-admin bootstrap only from a direct database-administrator session.
10. Regression pgTAP coverage was expanded for request hashing, ACLs, PO unit conversion and BOM conversion snapshots.

## Verification boundary

- Static migration structure and test plan counts were reviewed.
- GitHub Actions now starts a fresh local Supabase stack, applies migrations, and runs `supabase test db` on pushes and pull requests.
- Runtime PostgreSQL/pgTAP remains **pending until the GitHub Actions run completes**; no runtime pass is claimed beforehand.
- The live Supabase project still has no public tables or recorded migrations. No production migration was applied in this phase.
