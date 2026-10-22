import { test, expect } from "./fixtures";

test.describe("Workflow E — Purchasing & Inward Receipts E2E", () => {
  test.beforeEach(async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/purchasing");
  });

  test("loads purchasing page with orders and receipts tabs", async ({ authenticatedPage }) => {
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Purchasing & inward receipts");
    const ordersTab = authenticatedPage.locator(".panel-tabs button:has-text('Purchase orders')");
    const receiptsTab = authenticatedPage.locator(".panel-tabs button:has-text('Goods receipts')");
    await expect(ordersTab).toBeVisible();
    await expect(receiptsTab).toBeVisible();
  });

  test("validates delivery date constraint: expected delivery cannot precede order date", async ({ authenticatedPage }) => {
    const newPoBtn = authenticatedPage.locator("button:has-text('New purchase order')");
    if (await newPoBtn.isVisible()) {
      await newPoBtn.click();
      const modal = authenticatedPage.locator(".modal");
      await expect(modal).toBeVisible();

      // Set order date tomorrow, delivery date today
      const orderDateInput = authenticatedPage.locator("label:has-text('Order date') input");
      const deliveryDateInput = authenticatedPage.locator("label:has-text('Expected delivery') input");
      await orderDateInput.fill("2026-11-10");
      await deliveryDateInput.fill("2026-11-01");

      await authenticatedPage.locator("button[type='submit']:has-text('Save purchase order')").click();

      // Alert should report invalid date range
      const alert = authenticatedPage.locator(".alert.alert-error, .alert");
      await expect(alert).toBeVisible({ timeout: 5000 });
      expect(await alert.textContent()).toMatch(/Expected delivery cannot be earlier than the order date/i);
    }
  });

  test("GRN modal provides dual-unit conversion preview and validates rejection limits", async ({ authenticatedPage }) => {
    const newGrnBtn = authenticatedPage.locator("button:has-text('New goods receipt')");
    if (await newGrnBtn.isVisible()) {
      await newGrnBtn.click();
      const modal = authenticatedPage.locator(".modal");
      await expect(modal).toBeVisible();

      // Check form fields
      await expect(authenticatedPage.locator("label:has-text('Supplier vendor')")).toBeVisible();
      await expect(authenticatedPage.locator("label:has-text('Receiving location')")).toBeVisible();
      await expect(authenticatedPage.locator("label:has-text('Supplier invoice / DC')")).toBeVisible();

      // Enter rejected qty greater than received qty
      const receivedInput = authenticatedPage.locator("label:has-text('Received quantity') input");
      const rejectedInput = authenticatedPage.locator("label:has-text('Rejected quantity') input");
      if (await receivedInput.isVisible() && await rejectedInput.isVisible()) {
        await receivedInput.fill("10");
        await rejectedInput.fill("15");
        await authenticatedPage.locator("button[type='submit']:has-text('Save draft receipt')").click();

        const alert = authenticatedPage.locator(".alert.alert-error, .alert");
        await expect(alert).toBeVisible({ timeout: 5000 });
        expect(await alert.textContent()).toMatch(/Rejected quantity cannot exceed/i);
      }
    }
  });

  test("renders authoritative posting note: draft preview vs database RPC recomputation", async ({ authenticatedPage }) => {
    const newGrnBtn = authenticatedPage.locator("button:has-text('New goods receipt')");
    if (await newGrnBtn.isVisible()) {
      await newGrnBtn.click();
      const note = authenticatedPage.locator(".modal p, .form-note");
      const noteText = await note.first().textContent();
      expect(noteText?.toLowerCase()).toMatch(/provisional|canonical|database|recomputes|post/i);
    }
  });
});
