# Phase 12 — Deployment Preflight & Live Integration Readiness

**Project:** Packing Material Inventory & BOM Management ERP  
**Branch:** `phase-12-deployment-preflight`  
**Status:** Preflight tooling and CI coverage proposed; live public deployment remains gated on owner-selected hosting and credentials.  
**Supabase:** Retained as the Auth and PostgreSQL/PostgREST platform. No schema reset, destructive migration, or Supabase removal is in scope.

## 1. Objective

Make deployment configuration safer and repeatable before public rollout. Phase 11 introduced container packaging and local Compose orchestration. Phase 12 adds a provider-neutral preflight checker, a Render Free functional-testing Blueprint, and dedicated CI coverage. Render is a temporary test environment; after functional acceptance, the intended deployment target is a VPS. This does not claim a Render service has already been created or live credentials configured.

## 2. Included in this slice

- `scripts/deployment_preflight.py` checks frontend/backend environment files for required settings, placeholder values, Supabase project URL alignment, JWT issuer/audience consistency, production HTTPS, exact CORS origins, API base path, and forbidden backend-only secrets in the frontend environment.
- The checker never prints environment values, API keys, JWT secrets, or database URLs. It understands basic `KEY=value` files with optional matching quotes; it intentionally does not perform shell interpolation.
- `scripts/test_deployment_preflight.py` covers valid production/local configuration, placeholders, insecure production URLs, project mismatch, wildcard CORS, privileged frontend keys, backend-secret separation, and safe parsing.
- `.github/workflows/deployment-preflight.yml` runs the isolated tests on relevant pull requests/pushes and supports manual execution.

## 3. Run it locally

Copy the sample files first:

```bash
cp .env.example .env
cp backend/.env.example backend/.env
```

Edit the files locally with the actual project URL and **publishable/anon key only** in the root `.env`; keep signing secrets and database credentials in `backend/.env` or the selected host's backend-only secret store. Then run:

```bash
python scripts/deployment_preflight.py --mode local
```

For production, use the exact deployed URLs and frontend origin:

```bash
python scripts/deployment_preflight.py --mode production --frontend-origin https://your-actual-frontend-domain.example --frontend-env .env --backend-env backend/.env
```

Do not put the example domain above into a real deployment. The checker requires the supplied public frontend origin to appear exactly in `CORS_ALLOWED_ORIGINS` and requires production URLs to use HTTPS.

## 4. Security boundaries

- Supabase remains the identity provider and hosted database. The app's existing RLS and transactional RPC boundaries remain authoritative.
- `VITE_*` values are compiled into browser assets. Only `VITE_SUPABASE_URL`, the publishable/anon key, and the public Flask API base URL belong in the frontend environment.
- Never pass `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_SECRET_KEY`, `SUPABASE_JWT_SECRET`, or a database password to the frontend or commit real `.env` files.
- `SUPABASE_JWT_AUDIENCE` must be `authenticated`. An unset JWKS URL and issuer are allowed where the backend's documented derivation from `SUPABASE_URL` applies; a legacy HS256 signing secret must remain backend-only.
- Passing the preflight is necessary but not sufficient: it cannot prove that credentials are valid, the Supabase project is reachable, policies are correct, an administrator has been provisioned, or the cloud host is healthy.

## 5. Render Free functional-testing deployment

The repository's render.yaml defines two services:
- packing-erp-frontend: free Render Static Site built from the React/Vite frontend.
- packing-erp-api: free Docker-based Flask/Gunicorn web service in the Singapore region.

Supabase remains the authentication and database platform. Do not create a Render Postgres instance for this phase. Prefer a separate Supabase staging/test project for test transactions, so test purchase orders, receipts, stock movements, BOMs, and production records do not pollute real operational data.

### Configure and deploy

1. After this PR is merged, open Render Dashboard and create a new Blueprint using this repository's render.yaml from main.
2. Enter the staging Supabase project URL and its publishable/anon key for the frontend and API environment prompts. Set VITE_API_BASE_URL to the API service's actual public HTTPS URL followed by /api/v1.
3. Set backend CORS_ALLOWED_ORIGINS to the exact public HTTPS origin of the frontend static site. If Render assigns a different hostname, correct both values in the Render Dashboard and redeploy.
4. With modern asymmetric Supabase signing, the backend derives the JWKS URL and issuer from SUPABASE_URL. If the project explicitly uses legacy HS256, configure SUPABASE_JWT_SECRET only as a backend secret in Render; never place it in a Vite variable or Git.
5. Confirm API /api/v1/health returns HTTP 200 with HEALTHY and CONNECTED after staging schema and permissions are ready.

### Render Free limits that affect test results

- Free web services spin down after 15 minutes without inbound traffic; a cold request can take about a minute to wake.
- A free web instance has 0.1 CPU and 512 MB RAM, can restart, and has an ephemeral filesystem. Do not use local files for persistence or use these services for production workloads.
- Free instance hours are shared at workspace level (750 per calendar month). Static sites are free but still count toward applicable shared usage limits.
- Treat slow first requests after idle as cold-start behavior, not automatically as an application bug. Do not run sustained or high-volume load tests on free instances.
- This is functional staging only. It does not establish production reliability or meaningful performance capacity.

### Acceptance test sequence

1. Verify frontend loads over HTTPS, API health is connected, and Supabase sign-in works with a staging Auth user.
2. Validate each role's permitted and denied actions against real staging RLS policies.
3. Exercise master catalogs, purchase order creation, GRN posting, stock movements and ledger reconciliation, BOM versioning, daily planning, production completion, consumption verification, shift closing, and reports.
4. Replay selected idempotent POST requests and confirm retries do not duplicate stock movements.
5. Test missing/expired/tampered tokens, inactive users, forbidden direct writes, invalid query parameters, and API errors.
6. After idle, verify the first API request wakes the free instance and the UI handles delay/retry feedback.
7. Record workflow results, service logs, test records, and known issues before starting the VPS migration.

Do not run destructive tests against real operational data. Automated pgTAP/pytest/Vitest CI remains complementary; a passing Render smoke test does not replace it.

## 6. VPS migration after testing

After Render functional testing passes, migrate the application hosting to a user-managed Linux VPS while keeping Supabase Auth and PostgreSQL hosted. Provision Docker Engine/Compose, domain DNS, an HTTPS reverse proxy, firewall rules, and server-side secrets; deploy the same verified commit; then repeat health, authentication, role/RLS, business workflow, backup/restore, and rollback checks. Do not migrate the database itself to the VPS during this first move; database-hosting migration is a separate approved project.

No Render or VPS resource is provisioned by the repository changes alone.
## 7. Remaining owner-dependent gates

Before live rollout, the project owner must choose the frontend/API hosting provider(s), supply provider-side environment settings, set Supabase Auth site/redirect URLs, provision a real Auth user and matching authorized profile through the approved procedure, and perform browser-to-API-to-Supabase smoke tests. No cloud service is provisioned, no secrets are requested in chat, and no live database change is part of this phase slice.

## 8. Acceptance criteria

- [ ] Unit tests pass in the `Deployment Preflight Checks` workflow.
- [ ] Preflight rejects placeholder production config, non-HTTPS production URLs, wildcard CORS, mismatched Supabase projects, and apparent privileged frontend keys.
- [ ] Preflight does not echo secret values in errors.
- [ ] Root frontend env and backend env remain separated.
- [ ] Render Free frontend and Flask API services are created with staging credentials.
- [ ] Real staging sign-in, RLS role matrix, and business workflow smoke tests pass on Render.
- [ ] Render cold-start and restart behavior is documented; no production load capacity is inferred from free-tier results.
- [ ] The same reviewed commit is deployed to a VPS with HTTPS, firewall, backup/restore, rollback, and secrets checks.
- [ ] Production launch remains blocked until the intended production environment and owner-controlled secrets are explicitly approved.

All requirements needing Render Dashboard or VPS access remain pending until the project owner configures those environments.
