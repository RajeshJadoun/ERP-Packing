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
npm install
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
- All business mutations use the Flask API with the authenticated bearer token and an `Idempotency-Key`.
- The browser never writes to authoritative stock balances or stock ledger tables directly.
- Draft GRN preview values are provisional; server-side posting recomputes quantities and conversion provenance.

## Known rollout boundary
Frontend source is committed to the repository, but availability to users depends on configuring environment values and deploying the SPA and Flask API. CI validates tests/build; it does not publish a hosted site automatically.
