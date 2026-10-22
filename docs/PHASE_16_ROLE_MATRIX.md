# Phase 16.2 — Staging Role Authorization Matrix

**Scope:** Dedicated staging only. This suite sends intentionally invalid requests to prove server-side role gates. It does not post purchase orders, receive goods, move stock, complete production, close shifts, or change user roles.

## Current baseline

- Staging readiness query: 17/17 checks passed after all five active roles were provisioned.
- Operational invariant audit: 7/7 checks passed with zero violations.
- Full role-by-role HTTP authorization still needs to be executed using distinct login credentials for each of the five accounts.

## Enable the role matrix

In GitHub, open **Settings → Environments → staging**.

Keep the existing staging secrets and add these four email/password pairs as **environment secrets**:

- `E2E_STOREKEEPER_EMAIL` / `E2E_STOREKEEPER_PASSWORD`
- `E2E_PLANNER_EMAIL` / `E2E_PLANNER_PASSWORD`
- `E2E_OPERATOR_EMAIL` / `E2E_OPERATOR_PASSWORD`
- `E2E_VIEWER_EMAIL` / `E2E_VIEWER_PASSWORD`

The existing `E2E_EMAIL` / `E2E_PASSWORD` pair is used for the ADMIN test account. Do not put passwords in source control, test data, or chat.

After all five account credentials work, add the environment variable `E2E_ROLE_MATRIX_ENABLED=true` to the staging environment and run **Actions → Authenticated Staging E2E → Run workflow**. Keep the workflow's locked staging project and API URLs unchanged. Environment values are read when a run starts; if an existing run logged `E2E_ROLE_MATRIX_ENABLED=false`, start a fresh run after changing it.

When disabled, the role matrix is intentionally skipped so existing regression CI does not require additional secrets. When enabled, missing credentials or a non-staging target fail the suite.

## What the test verifies

Each role signs in using Supabase Auth and sends only invalid/empty POST payloads:

| Endpoint | Roles allowed to reach validation |
|---|---|
| `POST /boms` | ADMIN, PLANNER |
| `POST /daily-plans` | ADMIN, PLANNER |
| `POST /purchase-orders` | ADMIN, STOREKEEPER |
| `POST /production/completions` | ADMIN, OPERATOR, PLANNER |
| `POST /closings` | ADMIN, STOREKEEPER |
| `POST /stock/scrap-disposal` | ADMIN |
| `POST /admin/users/{staging-viewer-id}/access` | ADMIN |

Expected result: permitted roles get HTTP 422 due to deliberately missing required fields; forbidden roles get HTTP 403 before validation. The read-only ADMIN profile endpoint returns HTTP 200 only for ADMIN and HTTP 403 for other roles. The workflow is locked to the dedicated staging API and Supabase project.

If the staging VIEWER account is replaced, update the profile UUID constant in `frontend/e2e/11_role_authorization_matrix.spec.ts`.
