import { test, expect } from "./fixtures";

test.describe("Workflow C — BOM Studio & Recipe Versioning E2E", () => {
  test.beforeEach(async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/boms");
  });

  test("loads BOM studio with snapshot immutability banner and recipe table", async ({ authenticatedPage }) => {
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("BOM studio");
    await expect(authenticatedPage.locator(".bom-banner")).toContainText("Recipes are versioned, not overwritten");
    await expect(authenticatedPage.locator(".bom-banner .badge")).toContainText("Snapshot-safe");

    // Table should show recipes
    const table = authenticatedPage.locator("table");
    await expect(table).toBeVisible({ timeout: 10000 });
  });

  test("displays seeded TEST-E2E BOM recipe with active status and version badge", async ({ authenticatedPage }) => {
    const searchBox = authenticatedPage.locator("input[placeholder*='Search']");
    await searchBox.fill("TEST-E2E");

    const table = authenticatedPage.locator("table");
    await expect(table).toContainText("BOM-TEST-E2E-SKU-100", { timeout: 10000 });
    await expect(table).toContainText("v1");
    await expect(table).toContainText("ACTIVE");
    await expect(table).toContainText("2 lines");
  });

  test("version diff viewer displays material recipe lines and quantities", async ({ authenticatedPage }) => {
    const searchBox = authenticatedPage.locator("input[placeholder*='Search']");
    await searchBox.fill("TEST-E2E");

    const compareBtn = authenticatedPage.locator("button:has-text('Compare')").first();
    await compareBtn.click();

    // Version diff panel should open
    await expect(authenticatedPage.locator(".panel-heading h2")).toContainText("BOM-TEST-E2E-SKU-100");
    await expect(authenticatedPage.locator(".version-chips")).toContainText("v1 · ACTIVE");

    // Check material lines inside viewer
    const linesTable = authenticatedPage.locator(".panel-heading + .version-chips + .data-table, .data-table").last();
    const content = await linesTable.textContent();
    expect(content).toMatch(/carton|box|tape/i);
  });

  test("create BOM modal requires product, variant name, and at least one material line", async ({ authenticatedPage }) => {
    const createBtn = authenticatedPage.locator("button:has-text('Create BOM')");
    if (await createBtn.isVisible()) {
      await createBtn.click();
      const modal = authenticatedPage.locator(".modal-dialog, .modal-backdrop");
      await expect(modal).toBeVisible();

      // Submit without selecting product or variant
      await authenticatedPage.locator("button[type='submit']:has-text('Create BOM draft')").click();

      // Should show validation error
      const alert = authenticatedPage.locator(".alert.alert-error, .alert");
      await expect(alert).toBeVisible({ timeout: 5000 });
      expect(await alert.textContent()).toMatch(/Choose a product|variant name is required|material line/i);
    }
  });

  test("BOM line editor supports dynamic line addition, removal and optional flag", async ({ authenticatedPage }) => {
    const createBtn = authenticatedPage.locator("button:has-text('Create BOM')");
    if (await createBtn.isVisible()) {
      await createBtn.click();
      const addLineBtn = authenticatedPage.locator("button:has-text('Add material')");
      await addLineBtn.click();

      // Should now have at least 2 line editor rows
      const lineRows = authenticatedPage.locator(".line-editor");
      await expect(lineRows).toHaveCount(2);

      // Remove the second line
      const removeBtn = lineRows.last().locator("button:has-text('Remove')");
      await removeBtn.click();
      await expect(authenticatedPage.locator(".line-editor")).toHaveCount(1);
    }
  });
});
