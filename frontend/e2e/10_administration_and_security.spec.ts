import { test, expect } from "./fixtures";

const E2E_API_BASE_URL = (() => {
  const value = (process.env.E2E_API_URL || "http://127.0.0.1:5000/api/v1").replace(/\/+$/, "");
  const hostname = new URL(value).hostname.toLowerCase();
  const allowedHosts = new Set(["127.0.0.1", "localhost", "packing-erp-staging-api.onrender.com"]);
  if (!allowedHosts.has(hostname)) {
    throw new Error(
      `E2E safety guard: refusing API host "${hostname}". Use localhost or the dedicated staging API.`
    );
  }
  return value;
})();

test.describe("Workflow J & Security — System Administration & Audit E2E", () => {
  test("administration console loads profiles, access controls and audit event log", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/admin");
    await expect(authenticatedPage.locator(".page-header h1")).toContainText("System administration");

    // Guardrail badges and banner
    await expect(authenticatedPage.locator(".admin-banner")).toContainText("Administrator session verified");
    await expect(authenticatedPage.locator(".security-list")).toContainText("Role is verified on the server");
    await expect(authenticatedPage.locator(".security-list")).toContainText("Access changes are audited");

    // Profiles table
    const profilesTable = authenticatedPage.locator(".data-table").first();
    await expect(profilesTable).toBeVisible({ timeout: 10000 });

    // Audit logs table
    const auditTable = authenticatedPage.locator(".data-table").last();
    await expect(auditTable).toBeVisible({ timeout: 10000 });
  });

  test("user role change form enforces minimum 10-character reason for audit traceability", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/admin");
    const targetUuidInput = authenticatedPage.locator("input[placeholder*='profile UUID']");
    const reasonInput = authenticatedPage.locator("textarea[placeholder*='training']");
    const saveBtn = authenticatedPage.locator("button:has-text('Save access change')");

    if (await targetUuidInput.isVisible() && await reasonInput.isVisible()) {
      await targetUuidInput.fill("00000000-0000-0000-0000-000000000001");
      await reasonInput.fill("short");
      await saveBtn.click();

      // Alert should report reason constraint
      const alert = authenticatedPage.locator(".alert.alert-error, .alert");
      await expect(alert).toBeVisible({ timeout: 5000 });
      expect(await alert.textContent()).toMatch(/Reason must contain at least 10 characters/i);
    }
  });

  test("staging or local API health endpoint confirms backend and database connectivity", async ({ request }) => {
    const response = await request.get(`${E2E_API_BASE_URL}/health`);
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body.status).toBe("HEALTHY");
    expect(body.database).toBe("CONNECTED");
    expect(body.timestamp).toBeDefined();
  });

  test("protected API endpoints reject unauthenticated requests with HTTP 401 UNAUTHORIZED", async ({ request }) => {
    // These endpoints are deliberately unauthenticated; no production host is allowed by the guard above.
    const getEndpoints = [
      "/stock/balances",
      "/stock/ledger",
      "/stock/worker-custody",
      "/reports/stock",
    ];
    for (const ep of getEndpoints) {
      const response = await request.get(`${E2E_API_BASE_URL}${ep}`);
      expect(response.status()).toBe(401);
      const json = await response.json();
      expect(json.error.code).toBe("UNAUTHORIZED");
    }

    // Authenticated POST endpoints; empty payload should fail before any write.
    const postEndpoints = [
      "/boms",
      "/daily-plans",
    ];
    for (const ep of postEndpoints) {
      const response = await request.post(`${E2E_API_BASE_URL}${ep}`, {
        data: {},
      });
      expect(response.status()).toBe(401);
      const json = await response.json();
      expect(json.error.code).toBe("UNAUTHORIZED");
    }
  });
});
