# Phase 11 — Production Deployment & Live Integration

**Project:** Packing Material Inventory & BOM Management ERP  
**Status:** In progress — deployment packaging and container CI are staged on `phase-11-production-readiness`; live cloud deployment is not yet complete.  
**Supabase:** Retained as the authentication and hosted PostgreSQL/PostgREST platform. No Supabase removal or destructive schema change is in scope.

## 1. Phase objective

Move the existing, tested React + Flask + Supabase application toward repeatable deployment while preserving existing business logic and database protections. This phase begins with container packaging and local production-like integration; cloud rollout remains gated on the chosen hosting target and its credentials.

## 2. Work implemented in this phase branch

- Added a multi-stage React/Vite build served by an unprivileged Nginx container, including SPA route fallback, health endpoint and basic response security headers.
- Added a Flask API image running under a non-root OS account with Gunicorn, bounded worker configuration and a health check.
- Added a Docker Compose stack for local integration with frontend on `http://localhost:8080` and API on `http://localhost:5000`.
- Added root `.env.example` for frontend build-time public configuration and root `.gitignore` protections for local secrets and generated artifacts.
- Added CI that validates Compose configuration and builds both images without pushing them to a registry or requiring live credentials.
- Added Gunicorn to backend requirements and permitted the Compose frontend origin in the example CORS allow-list.

These are packaging changes only. They do not create Auth users, change live Supabase tables, run migrations against the hosted project or deploy a public service.

## 3. Local environment setup

From the repository root, make local environment files:

```bash
cp .env.example .env
cp backend/.env.example backend/.env
```

Edit root `.env` and set:

- `VITE_SUPABASE_URL`: the project's Supabase URL.
- `VITE_SUPABASE_ANON_KEY`: its publishable/anon key only.
- `VITE_API_BASE_URL`: keep `http://localhost:5000/api/v1` for local Compose testing.

Edit `backend/.env` and set the matching `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Set `SUPABASE_JWT_ISSUER` to that project's Auth issuer. For asymmetric signing keys, use the project's JWKS endpoint or leave the JWKS override blank so the backend derives it from `SUPABASE_URL`. For legacy HS256 signing, set the signing secret only in backend environment/secrets and leave the JWKS URL blank. Keep `SUPABASE_JWT_AUDIENCE=authenticated`.

For the local Compose stack, CORS should include `http://localhost:8080`; the sample file also permits the Vite development origin `http://localhost:5173`.

**Never** put a Supabase service-role key, JWT signing secret or PostgreSQL password into root `.env`, any `VITE_*` variable, the frontend image or Git. The frontend's anon/publishable key is intentionally public and must rely on RLS for authorization.

## 4. Build and run locally

```bash
docker compose config
docker compose up --build -d
docker compose ps
```

Open the frontend at `http://localhost:8080`. The API health endpoint is `http://localhost:5000/api/v1/health`. Check logs with:

```bash
docker compose logs --tail=100 api frontend
```

Stop the containers with `docker compose down`. The stack does not automatically provision an admin account or seed business data; use the existing Supabase Auth and initial-admin procedure in `docs/SYSTEM_WALKTHROUGH.md`.

Because Vite values are baked into the built static bundle, rebuild the frontend after changing `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` or `VITE_API_BASE_URL`:

```bash
docker compose build --no-cache frontend
docker compose up -d
```

## 5. Cloud deployment gates

The real hosting provider is not configured in this repository yet. Before public rollout:

1. Select a frontend host and a Flask container host, or a single platform that can host both.
2. Configure production secrets in the hosting provider's secret/environment settings rather than committing them.
3. Set the frontend `VITE_API_BASE_URL` to the public HTTPS Flask API URL **at build time**.
4. Set backend `CORS_ALLOWED_ORIGINS` to the exact frontend HTTPS origin(s).
5. Confirm Supabase Auth redirect/site URLs, allowed origins, RLS grants and signing-key mode for the real domain.
6. Create the first real Auth user and promote it using the guarded, documented one-time bootstrap procedure; do not invent profile UUIDs or bypass Auth provisioning.
7. Run a live smoke test for sign-in, role resolution, master data, PO/GRN, stock ledger, BOM planning, production completion, shift closing, and all reports.
8. Verify backup/restore, logs, error handling, rate limiting and performance with representative test data before release.

## 6. Acceptance criteria

- [ ] Docker Compose configuration validates using example environment files.
- [ ] Both containers build successfully in CI with placeholders (no secrets and no registry push).
- [ ] Local frontend and API health checks become healthy with valid Supabase project configuration.
- [ ] A real Supabase Auth account signs in and its server-resolved role is enforced.
- [ ] A complete browser-to-Flask-to-Supabase smoke test passes against a deployed HTTPS environment.
- [ ] No service-role key, signing secret or database password is exposed in browser assets, Git or logs.
- [ ] Backup/restore and operational handover are documented.

## 7. Current limitations

This branch does not claim that the Docker images have already passed CI, that a local environment has been configured, that an Auth user has been provisioned, or that anything has been deployed. The first two items will be verified by the GitHub Actions run for this phase. Cloud provisioning and live smoke tests require a selected hosting target and owner-provided credentials; those actions are intentionally not simulated.
