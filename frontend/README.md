# Packwise ERP frontend — Phase 8

React 19 + Vite + TypeScript operator workspace for Packing Material Inventory & BOM Management System.

## Prerequisites
- Node.js 22 LTS.
- A Supabase project with Phase 7 migrations applied.
- The Phase 7 Flask API running and reachable from the browser.

## Local setup
From the repository root:

```bash
cd frontend
npm install --legacy-peer-deps
cp .env.example .env.local
```

Set the following values in `.env.local`:
- `VITE_SUPABASE_URL`: project URL
- `VITE_SUPABASE_ANON_KEY`: publishable/anon public key
- `VITE_API_BASE_URL`: Flask API base URL, e.g. `http://localhost:5000/api/v1`

Then run `npm run dev`, `npm run test`, and `npm run build`.

Only browser-safe public Supabase credentials belong in Vite environment variables. Never set a service-role key in `VITE_*` variables.

## Screens included
Dashboard; master catalogs; procurement and inward receipts; stock balances and immutable ledger; worker custody issue/return; quarantine and scrap disposal; BOM version studio; daily planning and job quantity conservation; production completion with theoretical vs physical consumption; daily closing and discrepancy review; operations reports; administrator access and audit views.

## Data and mutation boundaries
- Supabase Auth handles session/password sign-in.
- Caller-scoped PostgREST + database RLS supports catalog and operational reads.
- Transactional mutations (purchase orders, BOM version promotion, planning/job controls, stock movements, production/consumption verification and shift closing) go through the Flask API with the authenticated bearer token and an `Idempotency-Key`.
- Catalog CRUD uses the caller's Supabase session and is bounded by table RLS/policies. Creating a draft GRN and its detail line is an explicitly permitted Storekeeper/Admin PostgREST staging flow; posting that draft is a Flask API operation.
- The browser never writes to authoritative stock balances or `stock_transactions` directly. GRN preview values are provisional; the database posting function recomputes accepted/canonical quantities and conversion provenance.

## First-user provisioning and release checklist

1. In Supabase Dashboard → Authentication → Users, create the intended administrator login (or invite the person using your organisation's normal process).
2. Create the matching row in `public.profiles` using that Auth user's exact UUID, a non-empty `full_name`, `role = 'ADMIN'`, and `is_active = true`. Use the project's approved privileged bootstrap/SQL Editor procedure; never expose a service-role key in the browser. Then sign in and confirm the Admin page shows the actual caller profile.
3. Configure `.env.local` with the public Supabase URL/publishable key and the real deployed Flask API base URL. Verify `GET /api/v1/health` reports `HEALTHY` and `CONNECTED`.
4. Run `npm install --legacy-peer-deps`, `npm run test`, `npm run build`; sign in with each required role and test allowed and forbidden actions against the actual project before opening the application to operators.

## Known rollout boundary

The source and automated browser/API-contract tests are committed, but this repository currently has no configured public SPA/API deployment target. The linked Supabase database currently has zero Auth users and zero application profiles; real JWT/RLS workflows therefore cannot be exercised until an owner provisions a test/admin login. GitHub CI validates the tests, strict dependency audit, TypeScript and production build; it does not deploy the application automatically.
