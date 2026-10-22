import { createClient } from "@supabase/supabase-js";
import { test, expect } from "@playwright/test";

const STAGING_PROJECT_REF = "pcrttrimxeoiabncnfan";
const STAGING_SUPABASE_URL = `https://${STAGING_PROJECT_REF}.supabase.co`;
const STAGING_API_URL = "https://packing-erp-staging-api.onrender.com/api/v1";
const STAGING_VIEWER_PROFILE_ID = "99a50dce-8d90-4421-a9dc-502546613c00";
// Role-matrix execution is enabled only by the GitHub staging environment variable.
const matrixEnabled = process.env.E2E_ROLE_MATRIX_ENABLED?.toLowerCase() === "true";

type AppRole = "ADMIN" | "STOREKEEPER" | "PLANNER" | "OPERATOR" | "VIEWER";
type RoleAccount = { role: AppRole; email?: string; password?: string };

const roleAccounts: RoleAccount[] = [
  { role: "ADMIN", email: process.env.E2E_EMAIL, password: process.env.E2E_PASSWORD },
  { role: "STOREKEEPER", email: process.env.E2E_STOREKEEPER_EMAIL, password: process.env.E2E_STOREKEEPER_PASSWORD },
  { role: "PLANNER", email: process.env.E2E_PLANNER_EMAIL, password: process.env.E2E_PLANNER_PASSWORD },
  { role: "OPERATOR", email: process.env.E2E_OPERATOR_EMAIL, password: process.env.E2E_OPERATOR_PASSWORD },
  { role: "VIEWER", email: process.env.E2E_VIEWER_EMAIL, password: process.env.E2E_VIEWER_PASSWORD },
];

const roleProtectedPosts: Array<{ path: string; allowed: AppRole[] }> = [
  { path: "/boms", allowed: ["ADMIN", "PLANNER"] },
  { path: "/daily-plans", allowed: ["ADMIN", "PLANNER"] },
  { path: "/purchase-orders", allowed: ["ADMIN", "STOREKEEPER"] },
  { path: "/production/completions", allowed: ["ADMIN", "OPERATOR", "PLANNER"] },
  { path: "/closings", allowed: ["ADMIN", "STOREKEEPER"] },
  { path: "/stock/scrap-disposal", allowed: ["ADMIN"] },
  { path: `/admin/users/${STAGING_VIEWER_PROFILE_ID}/access`, allowed: ["ADMIN"] },
];

const apiBase = (process.env.E2E_API_URL || "").replace(/\/+$/, "");
const supabaseUrl = process.env.VITE_SUPABASE_URL || "";
const anonKey = process.env.VITE_SUPABASE_ANON_KEY || "";

if (matrixEnabled) {
  if (apiBase !== STAGING_API_URL) {
    throw new Error("Role-matrix E2E is locked to the dedicated staging API.");
  }
  if (supabaseUrl !== STAGING_SUPABASE_URL) {
    throw new Error("Role-matrix E2E is locked to the dedicated staging Supabase project.");
  }
  if (!anonKey) {
    throw new Error("Role-matrix E2E requires STAGING_SUPABASE_ANON_KEY.");
  }
  const missingRoles = roleAccounts
    .filter((account) => !account.email || !account.password)
    .map((account) => account.role);
  if (missingRoles.length) {
    throw new Error(`Role-matrix E2E is enabled but credentials are missing for: ${missingRoles.join(", ")}.`);
  }
}

test.describe("Phase 16 — Staging role authorization matrix", () => {
  for (const account of roleAccounts) {
    test(`${account.role} can sign in and is subject to server-side role checks`, async ({ request }) => {
      test.skip(
        !matrixEnabled,
        "Set staging environment variable E2E_ROLE_MATRIX_ENABLED=true and configure role-specific staging secrets to enable this suite."
      );

      const client = createClient(supabaseUrl, anonKey, {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false,
        },
      });

      const { data, error } = await client.auth.signInWithPassword({
        email: account.email!,
        password: account.password!,
      });
      expect(error, `${account.role} staging account must be able to sign in`).toBeNull();
      expect(data.session?.access_token, `${account.role} must receive an access token`).toBeTruthy();
      const authorization = { Authorization: `Bearer ${data.session!.access_token}` };

      try {
        // This endpoint is read-only and ADMIN-only.
        const adminRead = await request.get(
          `${apiBase}/admin/users/${STAGING_VIEWER_PROFILE_ID}`,
          { headers: authorization, timeout: 15000 }
        );
        expect(
          adminRead.status(),
          `${account.role} access to ADMIN-only profile endpoint`
        ).toBe(account.role === "ADMIN" ? 200 : 403);

        // Each POST uses an intentionally invalid empty payload. Permitted roles
        // reach Pydantic validation (422); disallowed roles are rejected earlier
        // (403). No valid business command is submitted.
        for (let index = 0; index < roleProtectedPosts.length; index += 1) {
          const action = roleProtectedPosts[index];
          const response = await request.post(`${apiBase}${action.path}`, {
            headers: {
              ...authorization,
              "Content-Type": "application/json",
              "Idempotency-Key": `phase16-${account.role.toLowerCase()}-${index}-${Date.now()}`,
            },
            data: {},
            timeout: 15000,
          });

          const roleIsAllowed = action.allowed.includes(account.role);
          expect(
            response.status(),
            `${account.role} ${roleIsAllowed ? "must reach validation for" : "must be denied before validation on"} ${action.path}`
          ).toBe(roleIsAllowed ? 422 : 403);
        }
      } finally {
        await client.auth.signOut();
      }
    });
  }
});
