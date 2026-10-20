import { beforeEach, describe, expect, it, vi } from "vitest";
import { http, HttpResponse } from "msw";
import { API_BASE_URL, apiPost } from "./api";
import { supabase } from "./supabase";
import { server } from "../test/server";

describe("transactional API client integration", () => {
  beforeEach(() => {
    vi.spyOn(supabase.auth, "getSession").mockResolvedValue({
      data: { session: { access_token: "test-user-access-token" } as never },
      error: null
    });
  });

  it("sends the verified session token and an idempotency key with a production request", async () => {
    let captured: Record<string,string> = {};
    server.use(http.post(`${API_BASE_URL}/production/completions`, async ({request}) => {
      captured = Object.fromEntries(request.headers.entries());
      const body = await request.json() as {completedUnits:number;completionPolicy:string};
      expect(body.completedUnits).toBe(25);
      expect(body.completionPolicy).toBe("AUTO_BOM_THEORETICAL");
      return HttpResponse.json({success:true,completionId:"completion-1",consumptions:[{varianceStatus:"UNVERIFIED"}]});
    }));
    const result = await apiPost<{success:boolean;completionId:string}>("/production/completions", {
      packingJobId:"job-1",completedUnits:25,workerId:"worker-1",
      completionPolicy:"AUTO_BOM_THEORETICAL",actualMaterialUsage:[]
    });
    expect(result.success).toBe(true);
    expect(captured.authorization).toBe("Bearer test-user-access-token");
    expect(captured["idempotency-key"]).toMatch(/^web-/);
    expect(captured["content-type"]).toContain("application/json");
  });

  it("surfaces a safe API error instead of treating a failed close as success", async () => {
    server.use(http.post(`${API_BASE_URL}/closings`, () => HttpResponse.json({
      success:false,error:{code:"VALIDATION_ERROR",message:"Unverified consumption remains.",requestId:"req-test"}
    },{status:422})));
    await expect(apiPost("/closings",{dailyPlanId:"plan-1",shiftCode:"SHIFT_1"}))
      .rejects.toThrow("Unverified consumption remains. (request req-test)");
  });
});