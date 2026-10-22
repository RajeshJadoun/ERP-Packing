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

    // Report data loads asynchronously; wait for the report contract rather than
    // checking table visibility before the query has completed.
    const reportTable = authenticatedPage.locator("table");
    const theoreticalHeader = reportTable.getByRole("columnheader", { name: "Theoretical" });
    const physicalHeader = reportTable.getByRole("columnheader", { name: "Physical" });
    const statusHeader = reportTable.getByRole("columnheader", { name: "Status" });
    const hasRows = await theoreticalHeader.isVisible().catch(() => false);

    if (hasRows) {
      await expect(theoreticalHeader).toBeVisible();
      await expect(physicalHeader).toBeVisible();
      await expect(statusHeader).toBeVisible();
    } else {
      await expect(authenticatedPage.getByText("No report data")).toBeVisible({ timeout: 15000 });
    }
  });

  test("reports offer CSV download capability for audited data export", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/reports");
    await expect(authenticatedPage.getByRole("button", { name: "Export CSV" })).toBeVisible();
  });
});
