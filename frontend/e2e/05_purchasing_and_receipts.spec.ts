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

    // The master-data request is asynchronous. Wait for real staging options
    // instead of silently skipping this acceptance check during a slow load.
    const vendor = authenticatedPage.getByLabel("Vendor");
    await expect.poll(
      async () => (await vendor.locator("option").evaluateAll(options =>
        options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
      )).length,
      { message: "Active staging vendor options should finish loading.", timeout: 15000 }
    ).toBeGreaterThan(0);
    const vendorOptions = await vendor.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    await vendor.selectOption(vendorOptions[0]);

    // Required line fields must be populated so native browser validation does
    // not prevent the form's delivery-date validation from running.
    const material = authenticatedPage.getByLabel("Material");
    await expect.poll(
      async () => (await material.locator("option").evaluateAll(options =>
        options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
      )).length,
      { message: "Active staging material options should finish loading.", timeout: 15000 }
    ).toBeGreaterThan(0);
    const materialOptions = await material.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    await material.selectOption(materialOptions[0]);

    const unit = authenticatedPage.locator("label.field").filter({ hasText: /^Unit \*/ }).locator("select");
    await expect.poll(
      async () => (await unit.locator("option").evaluateAll(options =>
        options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
      )).length,
      { message: "Unit options should finish loading for the purchase-order line.", timeout: 15000 }
    ).toBeGreaterThan(0);
    const unitOptions = await unit.locator("option").evaluateAll(options =>
      options.map(option => (option as HTMLOptionElement).value).filter(Boolean)
    );
    await unit.selectOption(unitOptions[0]);

    const orderDateInput = authenticatedPage.getByLabel("Order date");
    const deliveryDateInput = authenticatedPage.getByLabel("Expected delivery");
    const orderDate = new Date(Date.now() + 14 * 86400000).toISOString().slice(0, 10);
    const earlierDeliveryDate = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);
    await orderDateInput.fill(orderDate);
    await deliveryDateInput.fill(earlierDeliveryDate);

    const purchaseOrderPosts: string[] = [];
    authenticatedPage.on("request", request => {
      if (request.method() === "POST" && request.url().includes("/purchase-orders")) {
        purchaseOrderPosts.push(request.url());
      }
    });

    await authenticatedPage.getByRole("button", { name: "Create draft PO" }).click();
    await expect(authenticatedPage.locator(".alert")).toContainText(
      "Expected delivery cannot be earlier than the order date."
    );
    // Invalid dates must be rejected in the UI without posting a draft PO.
    expect(purchaseOrderPosts).toHaveLength(0);
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
