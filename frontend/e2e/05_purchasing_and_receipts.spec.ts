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
    if (vendorOptions.length === 0) test.skip(true, "Staging has no active vendor fixture; backend bad-date validation is covered by test_purchasing.py.");
    await vendor.selectOption(vendorOptions[0]);

    // Required line fields must be populated so native browser validation does
    // not prevent the form's delivery-date validation from running.
    const material = authenticatedPage.getByLabel("Material");
    const materialOptions = await material.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    if (materialOptions.length === 0) test.skip(true, "Staging has no active material fixture for the required PO line.");
    await material.selectOption(materialOptions[0]);

    const unit = authenticatedPage.getByLabel("Unit");
    const unitOptions = await unit.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    if (unitOptions.length === 0) test.skip(true, "Staging has no unit fixture for the required PO line.");
    await unit.selectOption(unitOptions[0]);

    const orderDateInput = authenticatedPage.getByLabel("Order date");
    const deliveryDateInput = authenticatedPage.getByLabel("Expected delivery");
    await orderDateInput.fill("2026-11-10");
    await deliveryDateInput.fill("2026-11-01");

    await authenticatedPage.getByRole("button", { name: "Create draft PO" }).click();
    await expect(authenticatedPage.locator(".alert")).toContainText(
      "Expected delivery cannot be earlier than the order date."
    );
  });

  test("inward GRN preview rejects a rejected quantity above received quantity before master selection", async ({ authenticatedPage }) => {
    await authenticatedPage.locator(".panel-tabs button:has-text('Inward GRNs')").click();
    await authenticatedPage.getByRole("button", { name: /New inward receipt/ }).click();
    await expect(authenticatedPage.getByRole("heading", { name: "Record the supplier delivery" })).toBeVisible();

    await authenticatedPage.getByLabel("Entered quantity").fill("10");
    await authenticatedPage.getByLabel("Rejected quantity").fill("15");
    await authenticatedPage.getByRole("button", { name: "Preview dual units" }).click();

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
