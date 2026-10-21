import { test, expect } from "@playwright/test";

test.describe("Staging API health", () => {
  test("Flask API and Supabase REST dependency are connected", async ({ request }) => {
    const apiBase = process.env.E2E_API_URL;
    test.skip(!apiBase, "Set E2E_API_URL to enable the live staging API health check.");

    const response = await request.get(`${apiBase!.replace(/\/$/, "")}/health`, {
      timeout: 45000,
    });
    expect(response.ok(), `API health returned HTTP ${response.status()}`).toBeTruthy();
    await expect(response).toBeOK();
    const payload = await response.json() as { status?: string; database?: string };
    expect(payload.status).toBe("HEALTHY");
    expect(payload.database).toBe("CONNECTED");
  });
});
