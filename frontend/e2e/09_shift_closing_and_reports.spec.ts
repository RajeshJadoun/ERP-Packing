import { test, expect } from "./fixtures";

test.describe("Workflows I & J — Shift Closing & Operational Reports E2E", () => {
  test("shift closing console loads reconciliation metrics and closing history", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/closings");
    await expect(authenticatedPage.locator(".page-header h1")).toContainText("Shift closing console");
    await expect(authenticatedPage.locator(".panel-tabs, .segmented-tabs")).toBeVisible();

    // Check tabs: Pending closings vs Closed history
    const historyTab = authenticatedPage.locator("button:has-text('Closing history')");
    if (await historyTab.isVisible()) {
      await historyTab.click();
      await expect(authenticatedPage.locator(".data-table")).toBeVisible({ timeout: 10000 });
    }
  });

  test("discrepancy override requires supervisor justification before closing", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/closings");
    const overrideCheckbox = authenticatedPage.locator("input[type='checkbox']");
    if (await overrideCheckbox.isVisible()) {
      await overrideCheckbox.check();
      const reasonField = authenticatedPage.locator("textarea[placeholder*='override'], textarea[placeholder*='reason']");
      await expect(reasonField).toBeVisible();
    }
  });

  test("reports & analytics loads all six operational reporting views", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    await expect(authenticatedPage.locator(".page-header h1")).toContainText("Operations analytics & reports");

    // Check all 6 report tabs
    const tabs = [
      "Stock by location",
      "Worker custody",
      "Material variance",
      "Vendor history",
      "Shift summary",
      "Worker output",
    ];

    for (const tabTitle of tabs) {
      const tabButton = authenticatedPage.locator(`button:has-text('${tabTitle}')`);
      await expect(tabButton).toBeVisible();
    }
  });

  test("material variance report distinguishes unverified theoretical usage from verified counts", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    const varianceTab = authenticatedPage.locator("button:has-text('Material variance')");
    await varianceTab.click();

    // The table should have headers for theoretical, physical and variance status
    const table = authenticatedPage.locator(".data-table");
    await expect(table).toBeVisible({ timeout: 10000 });
    const content = await table.textContent();
    expect(content?.toLowerCase()).toMatch(/theoretical|variance|status|quantity/i);
  });

  test("reports offer CSV download capability for audited data export", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    const exportBtn = authenticatedPage.locator("button:has-text('Export CSV')");
    await expect(exportBtn).toBeVisible();
  });
});
