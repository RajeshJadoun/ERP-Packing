import { test as base, expect, Page } from "@playwright/test";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const AUTH_FILE = path.resolve(__dirname, "../../.auth/admin.json");

export type AuthFixtures = {
  authenticatedPage: Page;
  isAdmin: boolean;
};

export const test = base.extend<AuthFixtures>({
  authenticatedPage: async ({ browser }, use, testInfo) => {
    const hasAuthFile = fs.existsSync(AUTH_FILE);
    const email = process.env.E2E_EMAIL;
    const password = process.env.E2E_PASSWORD;

    if (hasAuthFile) {
      // Use saved storage state
      const context = await browser.newContext({ storageState: AUTH_FILE });
      const page = await context.newPage();
      await use(page);
      await context.close();
    } else if (email && password) {
      // Authenticate programmatically via UI
      const context = await browser.newContext();
      const page = await context.newPage();
      await page.goto("/");
      await page.fill("input[type='email']", email);
      await page.fill("input[type='password']", password);
      await page.click("button[type='submit']");
      await page.waitForSelector(".app-shell, .sidebar, .user-profile", { timeout: 20000 });
      // Save state for remaining tests. Playwright's BrowserContext API uses camelCase.
      fs.mkdirSync(path.dirname(AUTH_FILE), { recursive: true });
      await context.storageState({ path: AUTH_FILE });
      await use(page);
      await context.close();
    } else {
      testInfo.skip(true, "Authentication prerequisite: .auth/admin.json or E2E_EMAIL/E2E_PASSWORD required.");
    }
  },

  isAdmin: async ({}, use) => {
    // Default assumed admin for seeded test runs
    await use(true);
  },
});

export { expect };
