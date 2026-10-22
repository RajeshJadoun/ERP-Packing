# Operational Invariant Audit

**Purpose:** A repeatable, read-only pre-release check for the Packing ERP's two Supabase environments.

## How to run

1. Open the Supabase Dashboard for the environment you intend to inspect.
2. Open **SQL Editor** and create a new query.
3. Copy the contents of [`scripts/operational_invariant_audit.sql`](../scripts/operational_invariant_audit.sql) into the editor and run it.
4. Expect seven rows. Each should have `violations = 0` and `status = PASS`.
5. Save the result alongside the release record. Run it separately against staging and production.

**Safety:** The query is read-only. It uses `SELECT` statements against application tables and PostgreSQL catalog metadata. It does not create, update, or delete data. Never change it into a cleanup or repair query without a separate review.

## What it checks

| Check | Expected result |
|---|---|
| Stock ledger vs balance projection | Every material/location balance agrees with the signed stock-transaction ledger. |
| Packing-job quantity conservation | Revised target equals completed + pending + cancelled units. |
| Daily-closing quantity conservation | Closing planned units equal completed + pending + cancelled units. |
| Consumption variance state consistency | Unverified consumption is not accidentally presented as a verified zero variance. |
| Active BOM uniqueness | No product/party/packing-variant combination has multiple active BOMs. |
| Purchase-order over-receipt | Received quantity does not exceed the ordered quantity on a PO line. |
| RLS coverage | All 33 canonical application tables have both RLS and FORCE ROW LEVEL SECURITY enabled. |

## Latest baseline — 22 October 2026

The audit was run directly against both the production and staging Supabase projects. All seven checks returned **zero violations** in each environment.

| Environment | Checks | Violations found |
|---|---:|---:|
| Production Supabase | 7 | 0 |
| Staging Supabase | 7 | 0 |

This is a point-in-time integrity check, not proof of end-to-end readiness. It does not verify sign-in from every role, external hosting reliability, backup restoration, or every business workflow. Run it again after material schema changes and immediately before a production release.
