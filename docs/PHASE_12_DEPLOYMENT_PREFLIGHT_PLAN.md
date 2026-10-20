# Phase 12 — Deployment Preflight & Live Integration Readiness

**Project:** Packing Material Inventory & BOM Management ERP  
**Branch:** `phase-12-deployment-preflight`  
**Status:** Preflight tooling and CI coverage proposed; live public deployment remains gated on owner-selected hosting and credentials.  
**Supabase:** Retained as the Auth and PostgreSQL/PostgREST platform. No schema reset, destructive migration, or Supabase removal is in scope.

## 1. Objective

Make deployment configuration safer and repeatable before any public rollout. Phase 11 introduced container packaging and local Compose orchestration. Phase 12 adds a provider-neutral preflight checker that catches common environment mistakes without printing secrets, plus a dedicated test workflow. It does not claim to deploy or authenticate against a live project.

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

## 5. Remaining owner-dependent gates

Before live rollout, the project owner must choose the frontend/API hosting provider(s), supply provider-side environment settings, set Supabase Auth site/redirect URLs, provision a real Auth user and matching authorized profile through the approved procedure, and perform browser-to-API-to-Supabase smoke tests. No cloud service is provisioned, no secrets are requested in chat, and no live database change is part of this phase slice.

## 6. Acceptance criteria

- [ ] Unit tests pass in the `Deployment Preflight Checks` workflow.
- [ ] Preflight rejects placeholder production config, non-HTTPS production URLs, wildcard CORS, mismatched Supabase projects, and apparent privileged frontend keys.
- [ ] Preflight does not echo secret values in errors.
- [ ] Root frontend env and backend env remain separated.
- [ ] Actual hosting target and production secrets are configured outside Git before public deployment.
- [ ] Real authenticated smoke tests and backup/restore checks pass before release.

The final two criteria intentionally remain blocked until the hosting target and owner-controlled production environment are configured.
