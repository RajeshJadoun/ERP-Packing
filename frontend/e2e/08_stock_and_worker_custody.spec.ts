import { test, expect } from "./fixtures";

test.describe("Workflows F & H — Stock Ledger, Worker Custody & Quarantine E2E", () => {
  test("stock page renders inventory balances and append-only ledger tabs", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/inventory/stock");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Stock & immutable ledger");

    // 4 metric cards
    await expect(authenticatedPage.locator(".metric-card")).toHaveCount(4);
    await expect(authenticatedPage.locator(".metric-card").first()).toContainText("Tracked inventory");
    await expect(authenticatedPage.locator(".metric-card").nth(1)).toContainText("Available to promise");

    // Tab buttons
    const balancesTab = authenticatedPage.locator(".panel-tabs button:has-text('Current balances')");
    const ledgerTab = authenticatedPage.locator(".panel-tabs button:has-text('Transaction ledger')");
    await expect(balancesTab).toBeVisible();
    await expect(ledgerTab).toBeVisible();

    // Leaf node footnote
    await expect(authenticatedPage.locator(".info-footnote")).toContainText("Balances are shown from active leaf nodes only");
  });

  test("facility type filter supports leaf classification topology", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/inventory/stock");
    const filterSelect = authenticatedPage.locator("select[aria-label='Facility type filter']");
    await expect(filterSelect).toBeVisible();

    const text = await filterSelect.textContent();
    expect(text).toMatch(/store shelf/i);
    expect(text).toMatch(/receiving bay/i);
    expect(text).toMatch(/shop floor buffer/i);
    expect(text).toMatch(/worker custody/i);
    expect(text).toMatch(/damage quarantine/i);
  });

  test("worker custody page manages issue and return flows with active worker check", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/worker-custody");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Worker custody");

    // Form tabs
    const issueTab = authenticatedPage.locator(".panel-tabs button:has-text('Issue to worker')");
    const returnTab = authenticatedPage.locator(".panel-tabs button:has-text('Return from worker')");
    await expect(issueTab).toBeVisible();
    await expect(returnTab).toBeVisible();

    // Check issue form inputs
    await issueTab.click();
    await expect(authenticatedPage.locator("label:has-text('Worker') select")).toBeVisible();
    await expect(authenticatedPage.locator("label:has-text('Packing job') select")).toBeVisible();
    await expect(authenticatedPage.locator("label:has-text('Material') select")).toBeVisible();
  });

  test("quarantine console segregates damaged lots and protects scrap disposal", async ({ authenticatedPage }) => {
    await authenticatedPage.goto("/inventory/quarantine");
    await expect(authenticatedPage.getByRole("heading", { level: 1 })).toContainText("Quarantine & scrap disposal");

    const moveTab = authenticatedPage.locator(".panel-tabs button:has-text('Move to quarantine')");
    const scrapTab = authenticatedPage.locator(".panel-tabs button:has-text('Dispose of scrap')");
    await expect(moveTab).toBeVisible();
    await expect(scrapTab).toBeVisible();

    // Check move form
    await moveTab.click();
    await expect(authenticatedPage.locator("label:has-text('Destination quarantine bay')")).toBeVisible();

    // Check scrap tab explanation
    await scrapTab.click();
    await expect(authenticatedPage.locator(".form-intro")).toContainText("Reduces physical inventory permanently");
  });
});
