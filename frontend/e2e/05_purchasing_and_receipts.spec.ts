import { test, expect } from "./fixtures";

test.describe("Workflow E — Purchasing & Inward Receipts E2E", () => {
  test.beforeEach(async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/purchasing");
  });

  test("loads purchasing page with purchase orders and inward GRN tabs", async ({ authenticatedPage }) => {
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Purchasing & inward receipts");
    await expect(authenticatedPage.locator(".panel-tabs button:has-text('Purchase orders')")).toBeVisible();
    await expect(authenticatedPage.locator(".panel-tabs button:has-text('Inward GRNs')")).toBeVisible();
  });

  test("validates delivery date constraint before creating a purchase order", async ({ authenticatedPage }) => {
    await authenticatedPage.getByRole("button", { name: /New purchase order/ }).click();
    await expect(authenticatedPage.getByRole("heading", { name: "Order materials from a vendor" })).toBeVisible();

    const vendor = authenticatedPage.getByLabel("Vendor");
    const vendorOptions = await vendor.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    expect(vendorOptions.length).toBeGreaterThan(0);
    await vendor.selectOption(vendorOptions[0]);

    const orderDateInput = authenticatedPage.getByLabel("Order date");
    const deliveryDateInput = authenticatedPage.getByLabel("Expected delivery");
    await orderDateInput.fill("2026-11-10");
    await deliveryDateInput.fill("2026-11-01");

    await authenticatedPage.getByRole("button", { name: "Create draft PO" }).click();
    await expect(authenticatedPage.locator(".alert")).toContainText(
      "Expected delivery cannot be earlier than the order date."
    );
  });

  test("inward GRN form previews quantities and rejects quantities above received quantity", async ({ authenticatedPage }) => {
    await authenticatedPage.locator(".panel-tabs button:has-text('Inward GRNs')").click();
    await authenticatedPage.getByRole("button", { name: /New inward receipt/ }).click();
    await expect(authenticatedPage.getByRole("heading", { name: "Record the supplier delivery" })).toBeVisible();

    await expect(authenticatedPage.getByLabel("Vendor")).toBeVisible();
    await expect(authenticatedPage.getByLabel("Receiving location")).toBeVisible();
    await expect(authenticatedPage.getByLabel("Invoice number")).toBeVisible();

    const material = authenticatedPage.getByLabel("Material");
    const materialOptions = await material.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    expect(materialOptions.length).toBeGreaterThan(0);
    await material.selectOption(materialOptions[0]);

    await authenticatedPage.getByLabel("Entered quantity").fill("10");
    await authenticatedPage.getByLabel("Rejected quantity").fill("15");
    await authenticatedPage.getByRole("button", { name: "Save draft GRN" }).click();

    await expect(authenticatedPage.locator(".alert")).toContainText(
      "Rejected quantity cannot exceed entered quantity."
    );
  });

  test("shows the authoritative server-recomputation note in a draft GRN", async ({ authenticatedPage }) => {
    await authenticatedPage.locator(".panel-tabs button:has-text('Inward GRNs')").click();
    await authenticatedPage.getByRole("button", { name: /New inward receipt/ }).click();
    await expect(authenticatedPage.locator(".form-note")).toContainText(
      "Posted canonical quantities are recalculated by PostgreSQL"
    );
  });
});
