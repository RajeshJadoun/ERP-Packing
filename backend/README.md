# Flask backend — Phase 3 foundation

This folder contains the initial Flask API foundation for the Packing Material
Inventory & BOM Management System. It implements app configuration, request IDs,
Supabase JWT verification, active-profile checks, role authorization helpers,
JSON error envelopes, request validation, idempotency request normalization,
and the idempotency response-cache retention worker.

Business endpoints are intentionally introduced in later phases. At this stage,
`GET /api/v1/health` is the only business-facing endpoint and is explicitly
unauthenticated; it returns HTTP 200 only when the configured PostgreSQL/Supabase
REST health check succeeds. Other routes added under the `/api/v1` blueprint
are protected by the blueprint request hook.

## Local setup

Use Python 3.11 or newer:

```bash
cd backend
python -m venv .venv
# Windows PowerShell: .venv\Scripts\Activate.ps1
# Linux/macOS: source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
copy .env.example .env
# Edit .env and set SUPABASE_URL, SUPABASE_ANON_KEY, and JWT verification values.
python run.py
```

The runtime can verify legacy HS256 JWTs with `SUPABASE_JWT_SECRET` or verify
asymmetric Supabase JWTs through the project's JWKS endpoint. If both are set,
JWKS verification is preferred. Do not commit project signing secrets, direct
database URLs, or service-role keys.

The API checks the caller's active `public.profiles` row using the original
verified user JWT and the public/publishable Supabase key. It does not trust
client-supplied roles or user metadata, and it does not use a service-role key
for request authorization. PostgreSQL business mutations remain inside the
database RPC transaction; the HTTP middleware calculates the operation scope
and canonical request hash but does not create an idempotency header in a
separate transaction.

## Phase 4 purchasing endpoints

The first purchasing slice is implemented in `app/routes/purchasing.py`:

- `POST /api/v1/purchase-orders` — ADMIN/STOREKEEPER only; requires a validated
  `Idempotency-Key`. The database RPC creates the PO header and all lines in a
  single transaction. New POs start in `DRAFT`; PO creation never changes stock.
- `GET /api/v1/purchase-orders/{id}` — retrieves the PO and its persisted lines
  through PostgREST, filtered by ID and protected by the caller's JWT/RLS.
- `POST /api/v1/goods-receipts/post` — ADMIN/STOREKEEPER only; requires a draft
  `goodsReceiptId` and `Idempotency-Key`. The existing transactional GRN RPC
  recalculates accepted and canonical quantities, applies conversion provenance,
  updates PO receipt totals, and appends purchase-receipt ledger rows atomically.
- `GET /api/v1/goods-receipts/{id}` — retrieves the receipt calculations and
  per-line stock transaction references.

Draft GRN headers and lines are staged through the caller-authenticated Supabase
REST/RLS path. Header checks require an active vendor, an active leaf receiving
bay or shelf, invoice date not later than the receipt date, and a vendor matching
the linked PO. Direct REST inserts can only create DRAFT receipt headers; posting
to stock is restricted to the transactional RPC.

The Phase 4 migration adds `purchase_order_lines.unit_price`, which is required
by the API contract's `unitPrice` field. Authenticated direct write privileges
on purchase-order headers/lines are revoked; those records are created by the
atomic RPC. Do not apply `20261020000006_phase_4_purchasing_rpc.sql` to a remote
Supabase project until CI is green and the PR is approved/merged.

## Master catalogs

Master data remains data-driven and RLS-protected. The `master_service.py`
helpers use the original verified caller JWT and a public/publishable API key,
with an allow-list for master tables. The frontend may use Supabase PostgREST
directly for permitted catalog CRUD; PostgreSQL RLS and triggers remain the
authorization and integrity boundary. No service-role credential is used here.

## API health

`GET http://127.0.0.1:5000/api/v1/health` returns the health state, database
connectivity state, and UTC timestamp. An unconfigured or unreachable database
returns HTTP 503 and never claims the service is healthy.

## Automated tests

```bash
cd backend
pytest -q
ruff check app tests run.py
```

## Retention worker

Expired HTTP response-cache rows are ephemeral; permanent
`public.idempotency_keys` rows must never be pruned. Run the maintenance worker
as a separate server-side process only after placing a restricted PostgreSQL
connection URL in the backend runtime secret store:

```bash
python -m app.tasks.pruning
```

This worker uses direct PostgreSQL access because the two idempotency tables
intentionally deny direct PostgREST access. Do not expose its database credential
to the frontend or to untrusted users.
