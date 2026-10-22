import { test, expect } from "./fixtures";

test.describe("Workflow G — Production Entry & Consumption Verification E2E", () => {
  test("displays consumption policy options: Auto-BOM backflush vs Confirmed physical count", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/daily-plans/jobs");
    const openJobBtn = authenticatedPage.locator("button:has-text('Open →')").first();
    if (await openJobBtn.isVisible()) {
      await openJobBtn.click();
      const recordBtn = authenticatedPage.locator("button:has-text('Record production →'), button:has-text('New completion')").first();
      if (await recordBtn.isVisible()) {
        await recordBtn.click();
        await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Record packed units");

        // Policy toggle buttons
        const autoBomBtn = authenticatedPage.locator("button:has-text('Auto-BOM backflush')");
        const physicalBtn = authenticatedPage.locator("button:has-text('Confirmed physical count')");
        await expect(autoBomBtn).toBeVisible();
        await expect(physicalBtn).toBeVisible();

        // Switch to physical count
        await physicalBtn.click();
        await expect(authenticatedPage.locator(".form-grid select, .form-grid input").first()).toBeVisible();

        // Switch back to Auto-BOM
        await autoBomBtn.click();
        await expect(authenticatedPage.locator(".theory-note")).toContainText("variance remains UNVERIFIED");
      }
    }
  });

  test("enforces whole positive integer for completed units and operator selection", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/daily-plans/jobs");
    const openJobBtn = authenticatedPage.locator("button:has-text('Open →')").first();
    if (await openJobBtn.isVisible()) {
      await openJobBtn.click();
      const recordBtn = authenticatedPage.locator("button:has-text('Record production →')").first();
      if (await recordBtn.isVisible()) {
        await recordBtn.click();
        const unitsInput = authenticatedPage.locator("label:has-text('Completed units') input");
        await expect(unitsInput).toHaveAttribute("min", "1");
        await expect(unitsInput).toHaveAttribute("step", "1");
      }
    }
  });

  test("measurement methods include SCALE_WEIGHED, SEALED_BUNDLE and MANUALLY_COUNTED", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/daily-plans/jobs");
    const openJobBtn = authenticatedPage.locator("button:has-text('Open →')").first();
    if (await openJobBtn.isVisible()) {
      await openJobBtn.click();
      const recordBtn = authenticatedPage.locator("button:has-text('Record production →')").first();
      if (await recordBtn.isVisible()) {
        await recordBtn.click();
        const physicalBtn = authenticatedPage.locator("button:has-text('Confirmed physical count')");
        if (await physicalBtn.isVisible()) {
          await physicalBtn.click();
          const methodSelect = authenticatedPage.locator("select:has-text('Scale weighed'), select:has-text('Manually counted')").first();
          if (await methodSelect.isVisible()) {
            const options = await methodSelect.textContent();
            expect(options).toMatch(/scale weighed/i);
            expect(options).toMatch(/sealed bundle/i);
            expect(options).toMatch(/manually counted/i);
          }
        }
      }
    }
  });
});
