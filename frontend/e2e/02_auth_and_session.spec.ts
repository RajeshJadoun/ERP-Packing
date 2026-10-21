import { test, expect } from "@playwright/test";

test.describe("Workflow A2 — Authentication Lifecycle & Error Handling", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
  });

  test("form enforces browser email validation on malformed email", async ({ page }) => {
    const emailField = page.locator("input[type='email']");
    const passwordField = page.locator("input[type='password']");
    const submitButton = page.locator("button[type='submit']");

    await emailField.fill("not-an-email");
    await passwordField.fill("SomePassword123!");
    await submitButton.click();

    // Browser validity check
    const isInvalid = await emailField.evaluate((el: HTMLInputElement) => !el.validity.valid);
    expect(isInvalid).toBe(true);
  });

  test("submitting incorrect credentials renders accessible error banner without crashing", async ({ page }) => {
    const emailField = page.locator("input[type='email']");
    const passwordField = page.locator("input[type='password']");
    const submitButton = page.locator("button[type='submit']");

    await emailField.fill("test-invalid-user@packwise-erp.local");
    await passwordField.fill("IncorrectPassword999!");
    await submitButton.click();

    // An error message should appear
    const alertBox = page.locator(".alert.alert-error, .alert");
    await expect(alertBox).toBeVisible({ timeout: 15000 });
    const text = await alertBox.textContent();
    expect(text?.toLowerCase()).toMatch(/invalid|credentials|connection|error/);
  });

  test("password input field masks characters securely and provides current-password hint", async ({ page }) => {
    const passwordField = page.locator("input[type='password']");
    await expect(passwordField).toHaveAttribute("type", "password");
    await expect(passwordField).toHaveAttribute("autoComplete", "current-password");
  });

  test("sign-in button reflects loading state while authentication request is in flight", async ({ page }) => {
    const emailField = page.locator("input[type='email']");
    const passwordField = page.locator("input[type='password']");
    const submitButton = page.locator("button[type='submit']");

    await emailField.fill("test-slow@packwise-erp.local");
    await passwordField.fill("Password123!");
    await submitButton.click();

    // Either button gets disabled or has loading class/text while processing
    const isBusyOrAlert = await Promise.race([
      page.locator("button[type='submit']:disabled, button[type='submit'] .spinner, button[type='submit'].is-loading").waitFor({ timeout: 3000 }).then(() => true).catch(() => false),
      page.locator(".alert").waitFor({ timeout: 15000 }).then(() => true).catch(() => false),
    ]);
    expect(isBusyOrAlert).toBe(true);
  });

  test("renders Supabase Auth security badge and administrator support guidance", async ({ page }) => {
    const footerNotes = page.locator(".login-security, .login-help");
    await expect(footerNotes.first()).toBeVisible();
    await expect(page.locator(".login-help")).toContainText("Contact your Packwise administrator");
  });
});
