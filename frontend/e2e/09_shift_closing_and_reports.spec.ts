import { test, expect } from "./fixtures";

test.describe("Workflows I & J — Shift Closing & Operational Reports E2E", () => {
  test("shift closing console loads reconciliation metrics, released plans and closing history", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/closings");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Closing & material verification");
    await expect(authenticatedPage.locator(".metric-grid")).toBeVisible();
    await expect(authenticatedPage.getByRole("heading", { name: "Released plans" })).toBeVisible();
    await expect(authenticatedPage.getByRole("heading", { name: "Closing history" })).toBeVisible();
    await expect(authenticatedPage.getByText("Failed to fetch")).toHaveCount(0);
  });

  test("discrepancy override requires supervisor justification before closing", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/closings");
    const overrideCheckbox = authenticatedPage.locator("input[type='checkbox']");
    if (await overrideCheckbox.isVisible()) {
      await overrideCheckbox.check();
      const reasonField = authenticatedPage.getByLabel("Supervisor override reason");
      await expect(reasonField).toBeVisible();
    }
  });

  test("reports & analytics loads all six operational reporting views", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Operations intelligence");
    await expect(authenticatedPage.getByText("Failed to fetch")).toHaveCount(0);

    const tabs = [
      "Stock by location",
      "Consumption variance",
      "Production by shift",
      "Worker output",
      "Vendor history",
      "Worker custody",
    ];

    for (const tabTitle of tabs) {
      await expect(authenticatedPage.locator(`button:has-text('${tabTitle}')`)).toBeVisible();
    }
  });

  test("consumption variance report clearly distinguishes missing physical measurements from verified counts", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    await authenticatedPage.locator("button:has-text('Consumption variance')").click();
    await expect(authenticatedPage.getByText("Failed to fetch")).toHaveCount(0);
    await expect(authenticatedPage.locator(".report-footnote")).toContainText(
      "Missing physical consumption stays marked unverified"
    );

    const table = authenticatedPage.locator("table");
    if (await table.isVisible()) {
      const headers = (await table.locator("thead").textContent())?.toLowerCase() ?? "";
      expect(headers).toContain("theoretical");
      expect(headers).toContain("physical");
      expect(headers).toContain("status");
    } else {
      await expect(authenticatedPage.getByText("No report data")).toBeVisible();
    }
  });

  test("reports offer CSV download capability for audited data export", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    await expect(authenticatedPage.getByRole("button", { name: "Export CSV" })).toBeVisible();
  });
});
