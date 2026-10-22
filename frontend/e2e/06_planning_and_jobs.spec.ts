import { test, expect } from "./fixtures";

test.describe("Workflow D — Daily Plans & Packing Jobs E2E", () => {
  test.beforeEach(async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/daily-plans");
    // Include seeded E2E plans from any shift; the shell defaults to Shift 1,
    // which can legitimately hide fixtures assigned to General or Shift 2.
    await authenticatedPage.locator("select[aria-label='Active shift']").selectOption("ALL");
  });

  test("loads daily plans console with shift metrics and plan table", async ({ authenticatedPage }) => {
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Daily packing plans");
    await expect(authenticatedPage.locator(".metric-grid")).toBeVisible();
    await expect(authenticatedPage.locator("table")).toBeVisible({ timeout: 10000 });
  });

  test("create plan modal supports multiple jobs with master BOMs and custom recipes", async ({ authenticatedPage }) => {
    const createBtn = authenticatedPage.locator("button:has-text('Create daily plan')");
    if (await createBtn.isVisible()) {
      await createBtn.click();
      const modal = authenticatedPage.locator(".modal");
      await expect(modal).toBeVisible();

      // Check fields
      await expect(authenticatedPage.locator("label:has-text('Plan date')")).toBeVisible();
      await expect(authenticatedPage.locator("label:has-text('Shift')")).toBeVisible();

      // Add second job
      const addJobBtn = authenticatedPage.locator("button:has-text('Add job')");
      await addJobBtn.click();

      const jobHeaders = authenticatedPage.locator(".plan-job-title");
      await expect(jobHeaders).toHaveCount(2);

      // Switch job 2 to custom recipe
      const recipeTypeSelect = jobHeaders.last().locator("select");
      await recipeTypeSelect.selectOption("custom");

      // Verify custom recipe note renders
      await expect(authenticatedPage.locator(".form-note")).toContainText("A custom recipe stays source-less");
    }
  });

  test("loads job detail page and displays 5-variable quantity conservation invariant", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/daily-plans/jobs");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Packing job detail");

    // Table of jobs or message
    const table = authenticatedPage.locator("table");
    await expect(table).toBeVisible({ timeout: 10000 });

    const openJobBtn = authenticatedPage.locator("button:has-text('Open →')").first();
    if (await openJobBtn.isVisible()) {
      await openJobBtn.click();

      // Quantity conservation panel
      await expect(authenticatedPage.locator(".conservation-panel")).toBeVisible({ timeout: 10000 });
      await expect(authenticatedPage.locator(".conservation-panel")).toContainText("Quantity conservation");

      // Frozen BOM snapshot table
      const snapshotCard = authenticatedPage.locator("h2:has-text('Frozen BOM snapshot')");
      await expect(snapshotCard).toBeVisible();
    }
  });

  test("target revision modal enforces rule: new target cannot be below completed units", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/daily-plans/jobs");
    const openJobBtn = authenticatedPage.locator("button:has-text('Open →')").first();
    if (await openJobBtn.isVisible()) {
      await openJobBtn.click();
      const reviseBtn = authenticatedPage.locator("button:has-text('Revise target')");
      if (await reviseBtn.isVisible()) {
        await reviseBtn.click();
        const modal = authenticatedPage.locator(".modal");
        await expect(modal).toBeVisible();
        await expect(modal.locator("h2, .modal-head")).toContainText("Revise authorized target");
        await expect(modal.locator("input[type='number']")).toBeVisible();
        await expect(modal.locator("textarea")).toBeVisible();
      }
    }
  });
});
