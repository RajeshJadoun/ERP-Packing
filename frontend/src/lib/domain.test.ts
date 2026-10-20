import { describe, expect, it } from "vitest";
import { csvValue, formatQuantity, quantityBalanced, quantityEquation, validateCategory, variancePreview } from "./domain";

describe("quantity controls and display helpers", () => {
  it("checks the 5-variable quantity conservation identity", () => {
    expect(quantityBalanced({originalPlannedQuantity:520,currentRevisedQuantity:450,completedQuantity:100,pendingQuantity:0,cancelledQuantity:350})).toBe(true);
    expect(quantityBalanced({originalPlannedQuantity:520,currentRevisedQuantity:450,completedQuantity:100,pendingQuantity:10,cancelledQuantity:350})).toBe(false);
    expect(quantityEquation({originalPlannedQuantity:520,currentRevisedQuantity:450,completedQuantity:100,pendingQuantity:0,cancelledQuantity:350})).toBe("450 = 100 + 0 + 350");
  });
  it("never displays an unmeasured variance as zero", () => {
    expect(variancePreview("", 24)).toEqual({variance:null,status:"UNVERIFIED"});
    expect(variancePreview(24,24)).toEqual({variance:0,status:"VERIFIED_ZERO"});
    expect(variancePreview(26,24)).toEqual({variance:2,status:"VARIANCE_RECORDED"});
  });
  it("validates category identifiers and escapes CSV values", () => {
    expect(validateCategory("poly_bag","Poly Bags")).toBeNull();
    expect(validateCategory("bad code","Poly Bags")).toContain("Code");
    expect(validateCategory("BOX"," ")).toBe("Name is required.");
    expect(csvValue('Box "A"')).toBe('"Box ""A"""');
    expect(formatQuantity("not-a-number")).toBe("—");
  });
});