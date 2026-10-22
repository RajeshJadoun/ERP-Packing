import { createClient } from "@supabase/supabase-js";
import { test, expect, APIRequestContext } from "@playwright/test";

const STAGING_PROJECT_REF = "pcrttrimxeoiabncnfan";
const STAGING_SUPABASE_URL = `https://${STAGING_PROJECT_REF}.supabase.co`;
const STAGING_API_URL = "https://packing-erp-staging-api.onrender.com/api/v1";
const ACCEPTANCE_ENABLED = process.env.E2E_OPERATIONAL_ACCEPTANCE_ENABLED?.toLowerCase() === "true";
const MUTATIONS_ALLOWED = process.env.E2E_ALLOW_MUTATIONS?.toLowerCase() === "true";

type Row = Record<string, any>;

type Context = {
  apiBase: string;
  request: APIRequestContext;
  authorization: { Authorization: string };
};

function idemKey(runToken: string, operation: string): string {
  return `req_phase17_${runToken}_${operation}`;
}

async function requiredRow(query: any, label: string): Promise<Row> {
  const { data, error } = await query;
  if (error) throw new Error(`Staging fixture lookup failed for ${label}: ${error.message}`);
  if (!data) throw new Error(`Required TEST-E2E staging fixture is missing: ${label}`);
  return data as Row;
}

async function apiGet(context: Context, path: string): Promise<any> {
  const response = await context.request.get(`${context.apiBase}${path}`, {
    headers: context.authorization,
    timeout: 30000,
  });
  const bodyText = await response.text();
  if (response.status() !== 200) {
    throw new Error(`GET ${path} returned HTTP ${response.status()}: ${bodyText.slice(0, 1000)}`);
  }
  return JSON.parse(bodyText);
}

async function apiPost(
  context: Context,
  path: string,
  key: string,
  body: Row,
): Promise<{ status: number; body: any; text: string }> {
  const response = await context.request.post(`${context.apiBase}${path}`, {
    headers: {
      ...context.authorization,
      "Content-Type": "application/json",
      "Idempotency-Key": key,
    },
    data: body,
    timeout: 30000,
  });
  const text = await response.text();
  let parsed: any;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = { raw: text };
  }
  return { status: response.status(), body: parsed, text };
}

async function expectStatus(
  response: { status: number; body: any; text: string },
  expected: number,
  label: string,
): Promise<any> {
  expect(
    response.status,
    `${label}: HTTP ${response.status} body ${response.text.slice(0, 1000)}`,
  ).toBe(expected);
  return response.body;
}

async function readBalance(
  context: Context,
  materialId: string,
  locationId: string,
): Promise<number> {
  const rows = await apiGet(
    context,
    `/stock/balances?materialId=${encodeURIComponent(materialId)}&locationId=${encodeURIComponent(locationId)}`,
  );
  expect(Array.isArray(rows), "stock balance endpoint should return an array").toBe(true);
  const row = (rows as Row[]).find(
    (item) => item.materialId === materialId && item.locationId === locationId,
  );
  return row ? Number(row.onHandQuantity) : 0;
}

function expectQuantityDelta(after: number, before: number, expectedDelta: number, label: string) {
  expect(
    Math.abs((after - before) - expectedDelta),
    `${label}: expected quantity delta ${expectedDelta}, observed ${after - before}`,
  ).toBeLessThan(0.000001);
}

test("Phase 17 — persisted PO → GRN → Stock → BOM → Planning → Production → Shift Closing", async ({ request }) => {
  test.skip(
    !ACCEPTANCE_ENABLED || !MUTATIONS_ALLOWED,
    "Manual Phase 17 acceptance only: dispatch Staging Operational Acceptance with confirm_staging_mutations=true.",
  );
  test.setTimeout(240000);

  const apiBase = (process.env.E2E_API_URL || "").replace(/\/+$/, "");
  const supabaseUrl = process.env.VITE_SUPABASE_URL || "";
  const anonKey = process.env.VITE_SUPABASE_ANON_KEY || "";
  const email = process.env.E2E_EMAIL || "";
  const password = process.env.E2E_PASSWORD || "";

  expect(process.env.E2E_ENV).toBe("staging");
  expect(process.env.E2E_EXPECTED_SUPABASE_REF).toBe(STAGING_PROJECT_REF);
  expect(apiBase).toBe(STAGING_API_URL);
  expect(supabaseUrl).toBe(STAGING_SUPABASE_URL);
  expect(anonKey.length, "staging publishable/anon key must be configured").toBeGreaterThan(0);
  expect(email.length, "staging ADMIN email must be configured").toBeGreaterThan(0);
  expect(password.length, "staging ADMIN password must be configured").toBeGreaterThan(0);

  const supabase = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: login, error: loginError } = await supabase.auth.signInWithPassword({ email, password });
  expect(loginError, "staging ADMIN account must sign in").toBeNull();
  expect(login.session?.access_token, "ADMIN must receive a Supabase access token").toBeTruthy();
  const context: Context = {
    apiBase,
    request,
    authorization: { Authorization: `Bearer ${login.session!.access_token}` },
  };

  const runToken = Date.now().toString(36).toUpperCase();
  const today = new Date().toISOString().slice(0, 10);
  const addDays = (days: number) => new Date(Date.now() + days * 86400000).toISOString().slice(0, 10);
  const planDate = addDays(1);
  const shiftCode = `E2E_${runToken}`;
  const plannedUnits = 10;
  const receiptQuantities = new Map<string, number>();

  // Resolve the dedicated TEST-E2E fixtures only; never fall back to ordinary factory data.
  const vendor = await requiredRow(
    supabase.from("vendors").select("id,vendor_code,is_active")
      .eq("vendor_code", "TEST-E2E-VEN-SUPREME").eq("is_active", true).single(),
    "TEST-E2E-VEN-SUPREME",
  );
  const party = await requiredRow(
    supabase.from("parties").select("id,code,is_active")
      .eq("code", "TEST-E2E-PTY-01").eq("is_active", true).single(),
    "TEST-E2E-PTY-01",
  );
  const product = await requiredRow(
    supabase.from("products").select("id,sku_code,default_party_id,is_active")
      .eq("sku_code", "TEST-E2E-SKU-100").eq("is_active", true).single(),
    "TEST-E2E-SKU-100",
  );
  const box = await requiredRow(
    supabase.from("materials").select("id,material_code,canonical_unit_id,is_active")
      .eq("material_code", "TEST-E2E-MAT-BOX").eq("is_active", true).single(),
    "TEST-E2E-MAT-BOX",
  );
  const tape = await requiredRow(
    supabase.from("materials").select("id,material_code,canonical_unit_id,is_active")
      .eq("material_code", "TEST-E2E-MAT-TAPE").eq("is_active", true).single(),
    "TEST-E2E-MAT-TAPE",
  );
  const pcsUnit = await requiredRow(
    supabase.from("units").select("id,code").eq("code", "PCS").single(),
    "unit PCS",
  );
  const rollUnit = await requiredRow(
    supabase.from("units").select("id,code").eq("code", "ROLL").single(),
    "unit ROLL",
  );
  const shelf = await requiredRow(
    supabase.from("locations").select("id,location_code,location_type,is_leaf,is_active")
      .eq("location_code", "TEST-E2E-LOC-SHELF-01").eq("is_leaf", true).eq("is_active", true).single(),
    "TEST-E2E-LOC-SHELF-01",
  );
  const worker = await requiredRow(
    supabase.from("workers").select("id,worker_code,assigned_location_id,is_active")
      .eq("worker_code", "TEST-E2E-WRK-01").eq("is_active", true).single(),
    "TEST-E2E-WRK-01",
  );
  const workerLocation = await requiredRow(
    supabase.from("locations").select("id,location_code,location_type,is_leaf,is_active")
      .eq("id", worker.assigned_location_id).eq("is_active", true).eq("is_leaf", true).single(),
    "worker custody location",
  );

  expect(product.default_party_id).toBe(party.id);
  expect(box.canonical_unit_id).toBe(pcsUnit.id);
  expect(tape.canonical_unit_id).toBe(rollUnit.id);
  expect(shelf.location_type).toBe("STORE_SHELF");
  expect(workerLocation.location_type).toBe("WORKER_CUSTODY");

  const bom = await requiredRow(
    supabase.from("boms")
      .select("id,bom_code,product_id,party_id,packing_variant_name,status,version_number")
      .eq("product_id", product.id).eq("party_id", party.id)
      .eq("packing_variant_name", "Standard Retail Pack").eq("status", "ACTIVE").single(),
    "active TEST-E2E Standard Retail Pack BOM",
  );
  const { data: rawBomLines, error: bomLinesError } = await supabase
    .from("bom_lines")
    .select("id,bom_id,material_id,quantity_per_unit,unit_id,is_optional")
    .eq("bom_id", bom.id);
  if (bomLinesError) throw new Error(`Could not read TEST-E2E BOM lines: ${bomLinesError.message}`);
  const requiredBomLines = ((rawBomLines || []) as Row[]).filter((line) => line.is_optional === false);
  expect(requiredBomLines, "test BOM must have two required lines").toHaveLength(2);
  expect(requiredBomLines.map((line) => line.material_id).sort()).toEqual([box.id, tape.id].sort());
  for (const line of requiredBomLines) {
    const material = line.material_id === box.id ? box : tape;
    expect(line.unit_id, "Phase 17 fixture BOM lines must use canonical units").toBe(material.canonical_unit_id);
    const requiredQty = Number(line.quantity_per_unit) * plannedUnits;
    expect(requiredQty, "test BOM material requirement must be a positive finite number").toBeGreaterThan(0);
    receiptQuantities.set(line.material_id, Math.max(line.material_id === box.id ? 50 : 0, requiredQty * 3));
  }
  // These fixed fixture quantities keep the receipt meaningful and still cover each frozen BOM line.
  receiptQuantities.set(box.id, Math.max(50, receiptQuantities.get(box.id) || 0));
  receiptQuantities.set(tape.id, Math.max(5, receiptQuantities.get(tape.id) || 0));

  // 1. Purchase order — exercise create, replay, mismatch protection, and persisted retrieval.
  const poNumber = `TEST-E2E-PO-${runToken}`;
  const poKey = idemKey(runToken, "po");
  const poPayload = {
    poNumber,
    vendorId: vendor.id,
    orderDate: today,
    expectedDeliveryDate: addDays(7),
    notes: `TEST-E2E Phase 17 operational acceptance ${runToken}`,
    lines: [
      { materialId: box.id, orderedQuantity: receiptQuantities.get(box.id), unitId: pcsUnit.id, unitPrice: 0.1 },
      { materialId: tape.id, orderedQuantity: receiptQuantities.get(tape.id), unitId: rollUnit.id, unitPrice: 0.25 },
    ],
  };
  const poResponse = await apiPost(context, "/purchase-orders", poKey, poPayload);
  const poCreated = await expectStatus(poResponse, 201, "create test purchase order");
  expect(poCreated.id).toBeTruthy();
  const poReplay = await apiPost(context, "/purchase-orders", poKey, poPayload);
  const poReplayed = await expectStatus(poReplay, 201, "idempotent PO replay");
  expect(poReplayed.id).toBe(poCreated.id);
  const poMismatch = await apiPost(context, "/purchase-orders", poKey, {
    ...poPayload, notes: `${poPayload.notes} MISMATCH`,
  });
  expect(poMismatch.status, `mismatched idempotency replay must be rejected: ${poMismatch.text}`)
    .toBeGreaterThanOrEqual(400);
  expect(poMismatch.status, "idempotency mismatch must not surface as an unhandled server error")
    .toBeLessThan(500);
  const poDetail = await apiGet(context, `/purchase-orders/${poCreated.id}`);
  expect(poDetail.poNumber).toBe(poNumber);
  expect(poDetail.status).toBe("DRAFT");
  expect(poDetail.lines).toHaveLength(2);

  // Record baseline stock at the test shelf before posting the receipt.
  const shelfBeforeReceipt = new Map<string, number>();
  for (const line of requiredBomLines) {
    shelfBeforeReceipt.set(line.material_id, await readBalance(context, line.material_id, shelf.id));
  }

  // 2. Draft GRN — the only direct REST inserts are DRAFT header/lines under the signed-in staging ADMIN.
  const grnNumber = `TEST-E2E-GRN-${runToken}`;
  let grnId = "";
  try {
    const { data: grnHeader, error: grnHeaderError } = await supabase
      .from("goods_receipts")
      .insert({
        grn_number: grnNumber,
        vendor_id: vendor.id,
        po_id: poCreated.id,
        invoice_number: `TEST-E2E-INV-${runToken}`,
        invoice_date: today,
        received_date: today,
        destination_location_id: shelf.id,
        status: "DRAFT",
        remarks: `TEST-E2E Phase 17 operational acceptance ${runToken}`,
      })
      .select("id,grn_number")
      .single();
    if (grnHeaderError || !grnHeader) {
      throw new Error(`Create TEST-E2E draft GRN failed: ${grnHeaderError?.message || "No row returned"}`);
    }
    grnId = grnHeader.id as string;

    for (const line of requiredBomLines) {
      const material = line.material_id === box.id ? box : tape;
      const unit = line.material_id === box.id ? pcsUnit : rollUnit;
      const poLine = poDetail.lines.find((item: Row) => item.materialId === line.material_id);
      if (!poLine) throw new Error(`Test PO line is missing for material ${material.material_code}`);
      const quantity = receiptQuantities.get(line.material_id)!;
      const { error: grnLineError } = await supabase.from("goods_receipt_lines").insert({
        grn_id: grnId,
        purchase_order_line_id: poLine.id,
        material_id: line.material_id,
        entered_qty: quantity,
        entered_unit_id: unit.id,
        rejected_qty: 0,
        rejected_unit_id: unit.id,
        accepted_qty: quantity,
        canonical_quantity: quantity,
        canonical_unit_id: material.canonical_unit_id,
        conversion_factor_used: 1,
        conversion_direction: "NONE",
        conversion_type_used: "EXACT",
        is_estimated_conversion: false,
        batch_lot_number: `TEST-E2E-BATCH-${runToken}`,
      });
      if (grnLineError) throw new Error(`Create TEST-E2E draft GRN line failed: ${grnLineError.message}`);
    }
  } catch (error) {
    // Safe compensation is limited to a still-DRAFT header. Never delete a posted receipt or ledger row.
    if (grnId) {
      await supabase.from("goods_receipts").delete().eq("id", grnId).eq("status", "DRAFT");
    }
    throw error;
  }

  const postGrnKey = idemKey(runToken, "grnpost");
  const grnPostResponse = await apiPost(context, "/goods-receipts/post", postGrnKey, { goodsReceiptId: grnId });
  const grnPosted = await expectStatus(grnPostResponse, 200, "post test goods receipt");
  expect(grnPosted.status).toBe("POSTED");
  expect(grnPosted.lines).toHaveLength(2);
  expect(grnPosted.lines.every((line: Row) => Boolean(line.stockTransactionId))).toBe(true);
  expect(new Set(grnPosted.lines.map((line: Row) => line.stockTransactionId)).size).toBe(2);

  const grnReplayResponse = await apiPost(context, "/goods-receipts/post", postGrnKey, { goodsReceiptId: grnId });
  const grnReplayed = await expectStatus(grnReplayResponse, 200, "idempotent GRN-post replay");
  expect(grnReplayed.lines.map((line: Row) => line.stockTransactionId).sort())
    .toEqual(grnPosted.lines.map((line: Row) => line.stockTransactionId).sort());

  const shelfAfterReceipt = new Map<string, number>();
  for (const line of requiredBomLines) {
    const after = await readBalance(context, line.material_id, shelf.id);
    shelfAfterReceipt.set(line.material_id, after);
    expectQuantityDelta(
      after,
      shelfBeforeReceipt.get(line.material_id) || 0,
      receiptQuantities.get(line.material_id)!,
      `GRN stock receipt for ${line.material_id === box.id ? box.material_code : tape.material_code}`,
    );
  }
  const grnDetail = await apiGet(context, `/goods-receipts/${grnId}`);
  expect(grnDetail.status).toBe("POSTED");
  expect(grnDetail.lines.map((line: Row) => line.stockTransactionId).sort())
    .toEqual(grnPosted.lines.map((line: Row) => line.stockTransactionId).sort());

  // 3. Reuse the already-active test BOM and create a fresh, uniquely named daily plan.
  const bomDetail = await apiGet(context, `/boms/${bom.id}`);
  expect(bomDetail.id).toBe(bom.id);
  const planKey = idemKey(runToken, "plan");
  const planPayload = {
    planDate,
    shiftCode,
    notes: `TEST-E2E Phase 17 operational acceptance ${runToken}`,
    masterDerivedJobs: [{
      partyId: party.id,
      productId: product.id,
      masterBomId: bom.id,
      plannedQuantity: plannedUnits,
    }],
    customJobs: [],
  };
  const planResponse = await apiPost(context, "/daily-plans", planKey, planPayload);
  const planCreated = await expectStatus(planResponse, 201, "create test daily plan");
  expect(planCreated.id).toBeTruthy();
  expect(planCreated.jobs).toHaveLength(1);
  const jobId = planCreated.jobs[0].id as string;
  expect(jobId).toBeTruthy();

  const releaseResponse = await apiPost(
    context,
    `/daily-plans/${planCreated.id}/release`,
    idemKey(runToken, "release"),
    {},
  );
  const released = await expectStatus(releaseResponse, 200, "release test daily plan");
  expect(released.id).toBe(planCreated.id);
  const jobDetail = await apiGet(context, `/packing-jobs/${jobId}`);
  expect(jobDetail.id).toBe(jobId);
  expect(jobDetail.status).toBe("RELEASED");

  // 4. Issue the required canonical quantities to the dedicated test worker's custody location.
  const workerBalanceBeforeIssue = new Map<string, number>();
  for (const line of requiredBomLines) {
    workerBalanceBeforeIssue.set(line.material_id, await readBalance(context, line.material_id, workerLocation.id));
  }
  const requiredQuantities = new Map<string, number>();
  for (const line of requiredBomLines) {
    const quantity = Number(line.quantity_per_unit) * plannedUnits;
    requiredQuantities.set(line.material_id, quantity);
    const material = line.material_id === box.id ? box : tape;
    const unit = line.material_id === box.id ? pcsUnit : rollUnit;
    const issueBody = {
      materialId: line.material_id,
      workerId: worker.id,
      jobId,
      sourceLocationId: shelf.id,
      destinationLocationId: workerLocation.id,
      quantity,
      unitId: unit.id,
      measurementMethod: "MANUALLY_COUNTED",
      measurementEvidence: `TEST-E2E Phase 17 issue ${runToken}`,
    };
    const issueKey = idemKey(runToken, `issue${line.material_id === box.id ? "box" : "tape"}`);
    const issueResponse = await apiPost(context, "/stock/issue-to-worker", issueKey, issueBody);
    const issued = await expectStatus(issueResponse, 200, `issue ${material.material_code} to test worker`);
    expect(issued.stockTransactionId).toBeTruthy();
    const issueReplayResponse = await apiPost(context, "/stock/issue-to-worker", issueKey, issueBody);
    const issueReplay = await expectStatus(issueReplayResponse, 200, `idempotent issue replay for ${material.material_code}`);
    expect(issueReplay.stockTransactionId).toBe(issued.stockTransactionId);
  }
  for (const line of requiredBomLines) {
    const afterShelfIssue = await readBalance(context, line.material_id, shelf.id);
    const afterWorkerIssue = await readBalance(context, line.material_id, workerLocation.id);
    expectQuantityDelta(
      afterShelfIssue,
      shelfAfterReceipt.get(line.material_id) || 0,
      -requiredQuantities.get(line.material_id)!,
      `issue out of test shelf for ${line.material_id}`,
    );
    expectQuantityDelta(
      afterWorkerIssue,
      workerBalanceBeforeIssue.get(line.material_id) || 0,
      requiredQuantities.get(line.material_id)!,
      `issue into test worker custody for ${line.material_id}`,
    );
  }

  // 5. Complete production with explicit physical quantities matching the frozen canonical BOM.
  const actualMaterialUsage = requiredBomLines.map((line) => ({
    materialId: line.material_id,
    physicallyConfirmedQuantity: requiredQuantities.get(line.material_id)!.toString(),
    unitId: line.unit_id,
    measurementMethod: "MANUALLY_COUNTED",
    measurementEvidence: `TEST-E2E Phase 17 verified count ${runToken}`,
  }));
  const completionKey = idemKey(runToken, "completion");
  const completionPayload = {
    packingJobId: jobId,
    completedUnits: plannedUnits,
    workerId: worker.id,
    completionPolicy: "CONFIRMED_ACTUAL_ENTRY",
    actualMaterialUsage,
    remarks: `TEST-E2E Phase 17 operational acceptance ${runToken}`,
  };
  const completionResponse = await apiPost(context, "/production/completions", completionKey, completionPayload);
  const completionCreated = await expectStatus(completionResponse, 200, "record test production completion");
  const completionId = (completionCreated.id || completionCreated.completionId) as string;
  expect(completionId).toBeTruthy();
  expect(Number(completionCreated.completedUnits)).toBe(plannedUnits);

  const completionReplayResponse = await apiPost(context, "/production/completions", completionKey, completionPayload);
  const completionReplay = await expectStatus(completionReplayResponse, 200, "idempotent production completion replay");
  expect(completionReplay.id || completionReplay.completionId).toBe(completionId);
  const completionMismatchResponse = await apiPost(context, "/production/completions", completionKey, {
    ...completionPayload,
    completedUnits: plannedUnits - 1,
  });
  expect(
    completionMismatchResponse.status,
    `mismatched production idempotency replay should be rejected: ${completionMismatchResponse.text}`,
  ).toBeGreaterThanOrEqual(400);
  expect(completionMismatchResponse.status).toBeLessThan(500);

  const completionDetail = await apiGet(context, `/production/completions/${completionId}`);
  expect(Number(completionDetail.completedUnits)).toBe(plannedUnits);
  expect(completionDetail.consumptions).toHaveLength(requiredBomLines.length);
  for (const consumption of completionDetail.consumptions as Row[]) {
    expect(consumption.physicallyConfirmedQuantity).not.toBeNull();
    expect(consumption.varianceStatus).toBe("VERIFIED_ZERO");
    expect(Math.abs(Number(consumption.varianceQuantity))).toBeLessThan(0.000001);
  }

  for (const line of requiredBomLines) {
    const afterWorkerConsumption = await readBalance(context, line.material_id, workerLocation.id);
    expectQuantityDelta(
      afterWorkerConsumption,
      workerBalanceBeforeIssue.get(line.material_id) || 0,
      0,
      `test worker custody after issue and production consumption for ${line.material_id}`,
    );
  }

  // 6. Close the fully completed test plan and verify persisted quantity conservation.
  const closeResponse = await apiPost(
    context,
    "/closings",
    idemKey(runToken, "closing"),
    {
      dailyPlanId: planCreated.id,
      shiftCode,
      allowDiscrepancyOverride: false,
      pendingDispositions: [],
    },
  );
  const closingCreated = await expectStatus(closeResponse, 200, "close completed test daily plan");
  const closingId = closingCreated.id as string;
  expect(closingId).toBeTruthy();
  const closingDetail = await apiGet(context, `/closings/${closingId}`);
  expect(closingDetail.dailyPlanId).toBe(planCreated.id);
  expect(Number(closingDetail.totalPlannedUnits)).toBe(plannedUnits);
  expect(Number(closingDetail.totalCompletedUnits)).toBe(plannedUnits);
  expect(Number(closingDetail.totalPendingUnits)).toBe(0);
  expect(Number(closingDetail.totalCancelledUnits)).toBe(0);
  expect(
    Number(closingDetail.totalPlannedUnits),
  ).toBe(
    Number(closingDetail.totalCompletedUnits)
      + Number(closingDetail.totalPendingUnits)
      + Number(closingDetail.totalCancelledUnits),
  );

  console.log("PHASE17_OPERATIONAL_ACCEPTANCE_IDS", JSON.stringify({
    runToken,
    purchaseOrderId: poCreated.id,
    purchaseOrderNumber: poNumber,
    goodsReceiptId: grnId,
    goodsReceiptNumber: grnNumber,
    bomId: bom.id,
    dailyPlanId: planCreated.id,
    packingJobId: jobId,
    issueTransactionIds: [...requiredBomLines].map((line) => line.material_id),
    productionCompletionId: completionId,
    dailyClosingId: closingId,
    stagingProjectRef: STAGING_PROJECT_REF,
    immutableLedgerEvidenceRetained: true,
  }));

  await supabase.auth.signOut();
});
