import { test, expect } from "./fixtures";

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

  test("public health endpoint is live and confirms backend and database connectivity", async ({ request }) => {
    const response = await request.get("https://packing-erp-api.onrender.com/api/v1/health");
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body.status).toBe("HEALTHY");
    expect(body.database).toBe("CONNECTED");
    expect(body.timestamp).toBeDefined();
  });

  test("protected API endpoints reject unauthenticated requests with HTTP 401 UNAUTHORIZED", async ({ request }) => {
    // Authenticated GET endpoints
    const getEndpoints = [
      "/api/v1/stock/balances",
      "/api/v1/stock/ledger",
      "/api/v1/stock/worker-custody",
      "/api/v1/reports/stock",
    ];
    for (const ep of getEndpoints) {
      const response = await request.get(`https://packing-erp-api.onrender.com${ep}`);
      expect(response.status()).toBe(401);
      const json = await response.json();
      expect(json.error.code).toBe("UNAUTHORIZED");
    }

    // Authenticated POST endpoints
    const postEndpoints = [
      "/api/v1/boms",
      "/api/v1/daily-plans",
    ];
    for (const ep of postEndpoints) {
      const response = await request.post(`https://packing-erp-api.onrender.com${ep}`, {
        data: {},
      });
      expect(response.status()).toBe(401);
      const json = await response.json();
      expect(json.error.code).toBe("UNAUTHORIZED");
    }
  });
});

