import { test, expect } from "@playwright/test";

test.describe("Portal Health & Baseline E2E Smoke", () => {
  test("loads portal login screen and checks branding", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/Packing|Packwise/i);
    // Should see sign in or welcome text
    const heading = page.locator("h1, h2");
    await expect(heading.first()).toBeVisible({ timeout: 15000 });
  });
});
