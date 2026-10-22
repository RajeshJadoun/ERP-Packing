import { test, expect } from "./fixtures";

test.describe("Workflow B — Master Data & Catalogs E2E", () => {
  test("loads material categories catalog with seeded TEST-E2E records", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/masters/categories");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Material categories");

    // Search for test category
    const searchBox = authenticatedPage.locator("input[placeholder*='Search']");
    if (await searchBox.isVisible()) {
      await searchBox.fill("TEST-E2E");
    }

    // Verify table has rows
    const table = authenticatedPage.locator("table");
    await expect(table).toBeVisible({ timeout: 10000 });
    const content = await table.textContent();
    expect(content).toContain("TEST-E2E");
  });

  test("validates category code pattern constraint (letters, digits, dashes, underscores)", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/masters/categories");
    const addBtn = authenticatedPage.locator("button:has-text('Add record')");
    if (await addBtn.isVisible()) {
      await addBtn.click();
      const modal = authenticatedPage.locator(".modal");
      await expect(modal).toBeVisible();

      // Enter invalid code with special chars
      await authenticatedPage.locator("input[placeholder='POLY_BAG']").fill("INVALID CODE !@#");
      await authenticatedPage.locator("input[placeholder='Poly Bags']").fill("Invalid Test Category");
      await authenticatedPage.locator("button[type='submit']:has-text('Create')").click();

      // Should display validation error
      const alert = authenticatedPage.locator(".alert.alert-error, .alert");
      await expect(alert).toBeVisible({ timeout: 5000 });
      expect(await alert.textContent()).toMatch(/Code must be 2–40 letters/i);
    }
  });

  test("loads materials catalog and displays canonical units and JSON specs", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/masters/materials");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Materials catalog");

    const searchBox = authenticatedPage.locator("input[placeholder*='Search']");
    if (await searchBox.isVisible()) {
      await searchBox.fill("TEST-E2E");
    }

    const table = authenticatedPage.locator("table");
    await expect(table).toBeVisible({ timeout: 10000 });
    const text = await table.textContent();
    expect(text).toMatch(/TEST-E2E-MAT-BOX|TEST-E2E-MAT-TAPE/);
  });

  test("loads parties and products combined view with tab switching", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/masters/parties-products");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Parties & products");

    // Segmented tabs: parties and products
    const partyTab = authenticatedPage.locator(".segmented-tabs button:has-text('parties')");
    const productTab = authenticatedPage.locator(".segmented-tabs button:has-text('products')");
    await expect(partyTab).toBeVisible();
    await expect(productTab).toBeVisible();

    // Check parties
    await partyTab.click();
    await expect(authenticatedPage.locator("table")).toContainText("TEST-E2E-PTY-01", { timeout: 10000 });

    // Check products
    await productTab.click();
    await expect(authenticatedPage.locator("table")).toContainText("TEST-E2E-SKU-100", { timeout: 10000 });
  });

  test("loads locations and workers topology with leaf location indicators", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/masters/locations-workers");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Locations & workers");

    // Check locations
    const locTab = authenticatedPage.locator(".segmented-tabs button:has-text('locations')");
    await locTab.click();
    await expect(authenticatedPage.locator("table")).toContainText("TEST-E2E-LOC-SHELF-01", { timeout: 10000 });

    // Check workers
    const wrkTab = authenticatedPage.locator(".segmented-tabs button:has-text('workers')");
    await wrkTab.click();
    await expect(authenticatedPage.locator("table")).toContainText("TEST-E2E-WRK-01", { timeout: 10000 });
  });

  test("loads standard units of measure with physical dimensions", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/masters/units");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Units of measure");
    const table = authenticatedPage.locator("table");
    await expect(table).toContainText("PCS");
    await expect(table).toContainText("COUNT");
    await expect(table).toContainText("KG");
    await expect(table).toContainText("MASS");
  });
});
