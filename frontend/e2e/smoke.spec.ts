import { test, expect } from "@playwright/test";

test.describe("Portal Health & Baseline E2E Smoke", () => {
  test("loads portal login screen and checks branding", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/Packing|Packwise/i);
    const heading = page.locator("h1, h2");
    await expect(heading.first()).toBeVisible({ timeout: 15000 });
    await expect(page.locator("input[type='email']")).toBeVisible({ timeout: 15000 });
  });

  test("serves a nested React route directly and after refresh", async ({ page }) => {
    const directResponse = await page.goto("/daily-plans");
    expect(directResponse, "direct navigation should return an HTTP response").not.toBeNull();
    expect(directResponse!.status(), "nested route must not return 404").toBeLessThan(400);
    await expect(page.locator("input[type='email']")).toBeVisible({ timeout: 15000 });

    const reloadResponse = await page.reload();
    expect(reloadResponse, "refresh should return an HTTP response").not.toBeNull();
    expect(reloadResponse!.status(), "refresh of nested route must not return 404").toBeLessThan(400);
    await expect(page.locator("input[type='email']")).toBeVisible({ timeout: 15000 });
  });
});
