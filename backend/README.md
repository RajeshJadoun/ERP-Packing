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
