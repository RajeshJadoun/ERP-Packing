# Phase 8 Scenario Coverage Matrix

**Date:** 2026-10-20  
**Frontend CI:** https://github.com/RajeshJadoun/ERP-Packing/actions/runs/39439002128  
**Current disposition:** Automated frontend/API-contract coverage is green. Production release remains gated by real-user JWT/RLS verification and hosted frontend-to-Flask smoke testing.

## Operational scenario map

| Acceptance scenario | Phase 8 coverage | Evidence | Remaining qualification |
|---|---|---|---|
| 1. Dual-unit and estimated conversion | Partial UI coverage | MSW test previews accepted quantity, conversion factor and multiply direction for a BOX-to-PCS conversion | Actual PostgreSQL-authoritative GRN post and balance result need a seeded authenticated environment |
| 2. Theoretical BOM usage and unverified variance | Automated UI/API-contract coverage | Production completion submits AUTO_BOM_THEORETICAL with no invented physical counts; consumption verification tests cover authenticated payload and VIEWER gate | Requires live, released BOM/job and stock to confirm persisted ledger and variance |
| 3. Same party/product with distinct BOM variants | Automated UI/API-contract coverage | Plan test submits two same-party/same-product jobs with different active BOM IDs and quantities | Real BOM snapshots and reservation isolation are owned by database/API integration tests |
| 4. Quantity revision 520 → 450 | Automated UI/API-contract coverage | Job detail test checks revision request and conservation equation 450 = completed + pending + cancelled | Live reservation delta and reason audit must be verified against seeded data |
| 5. Cancellation with outstanding worker custody | Partial UI/API-contract coverage | Remaining quantity cancellation and conservation are exercised; custody issue/return have separate workflow tests | Full cross-workflow block-on-outstanding-custody then return-and-retry scenario still requires backend/live integrated execution |
| 6. Authoritative stock ledger and worker custody | Automated workflow contract coverage | Separate authenticated issue-to-worker and return-from-worker endpoint tests; the browser does not write stock_transactions | Balance/ledger arithmetic under concurrent live stock movements remains backend/database verification, not a mocked browser claim |
| 7. Idempotency, replay and concurrent requests | Layered coverage | API transport test verifies bearer token and idempotency header; backend/database suite owns owner/scope/hash, replay, concurrency and rollback invariants | No live concurrent request test through a public deployment has been run |
| 8. BOM versioning and custom jobs | Automated UI/API-contract coverage | BOM activation must call Flask; custom daily plan submits multiple material lines without inventing a master BOM | Live promotion from V1 to V2 and frozen released snapshots still require seeded-data integration validation |
| 9. RLS and hardened role resolution | Partially verified; release blocker | Live catalog confirms RLS + FORCE RLS enabled on all 33 public tables and 61 policies; frontend tests assert missing/error/inactive profiles fail closed and Viewer cannot issue/return | Linked database has zero auth.users and zero public.profiles; real JWT role matrix and forbidden PostgREST writes cannot yet run |
| 10. End-of-shift closing and discrepancies | Automated UI/API-contract coverage | Closing test submits the audited closing API request with explicit non-override disposition | Custody/unverified-consumption rejection and authorized override must be checked with real operational records |
| 11. Dynamic categories and material specifications | Automated UI/API-contract coverage | Tests create a category, create a material, parse JSON specs and assert the intended PostgREST payload | Actual write authorization depends on a provisioned ADMIN user and live RLS test |
| 12. Quarantine vs scrap | Automated UI/API-contract coverage | Tests assert separate source/destination quarantine and scrap-disposal payloads and endpoints | Live balance preservation/reduction should be confirmed after server posting on seeded inventory |
| 13. Anti-cascade history protection | Database regression coverage | Foreign-key/anti-cascade behavior belongs to the database migration and database CI suite | This is not proven by the frontend MSW tests; verify latest database CI and retain live migration regression results |
| 14. Profile role protection / fail-closed entry | Automated frontend coverage plus schema checks | App tests block missing profile, lookup errors and inactive profiles; the topbar reports real health-check results | Real Auth user/profile provisioning and role mutation attempt remain required |

## Test results (frontend CI)

The verified run completed **30 tests across 6 files**, passed strict npm audit with **0 vulnerabilities**, and passed TypeScript type-check and Vite production build. Coverage includes 13 MSW workflows plus domain, API transport, shared UI and consumption-verification tests.

## Known live-environment facts

The linked Supabase project has 33 public tables, all 33 with RLS and FORCE RLS enabled, and 61 public policies. It currently has no Auth users and no application profiles. The repo has no configured public SPA deployment or public Flask API base URL. Therefore the actual signed-in role/RLS and deployed cross-service smoke tests are explicitly **pending**, not passed.

## Release-gate checklist

- [ ] Provision authorized Supabase Auth user(s) and matching public.profiles records using the privileged bootstrap procedure.
- [ ] Run a real JWT matrix for ADMIN, STOREKEEPER, PLANNER, OPERATOR and VIEWER, including direct attempts to write stock ledger rows and mutate protected roles.
- [ ] Seed safe test masters, stock, BOM variants and jobs in an approved test project; run the complete cross-workflow scenario set.
- [ ] Configure and deploy the SPA and Flask API; set browser-safe Supabase URL/key and the actual API base URL.
- [ ] Smoke test sign-in, /api/v1/health, at least one authorized transactional flow and one forbidden role action against the deployed services.
- [ ] Archive the passing database CI run and live test evidence, then mark Phase 8 production release complete.
