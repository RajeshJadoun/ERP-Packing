import { beforeEach, describe, expect, it, vi, type Mock } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { http, HttpResponse } from "msw";
import { supabase } from "../lib/supabase";
import { API_BASE_URL } from "../lib/api";
import { server } from "../test/server";
import { createSupabaseMock, type MockRow } from "../test/supabaseMock";
import { PurchasingPage } from "./Purchasing";
import { PlanningPage, JobDetailPage } from "./Planning";
import { ProductionPage } from "./ProductionClosing";

const userSession = { access_token: "test-operations-token" };

vi.mock("../lib/supabase", () => ({
  supabaseConfigured: true,
  supabase: {
    auth: { getSession: vi.fn() },
    from: vi.fn()
  }
}));

function configureDb(seed: Record<string, MockRow[]> = {}) {
  const db = createSupabaseMock(seed);
  (supabase.from as unknown as Mock).mockImplementation(db.from);
  (supabase.auth.getSession as unknown as Mock).mockResolvedValue({
    data: { session: userSession },
    error: null
  });
  return db;
}

const partyId = "party-1";
const productId = "product-1";
const vendorId = "vendor-1";
const materialId = "material-1";
const unitId = "unit-pcs";
const shelfId = "shelf-1";
const workerId = "worker-1";
const jobId = "job-1";

const purchasingSeed: Record<string, MockRow[]> = {
  vendors: [{ id: vendorId, vendor_code: "V-001", name: "Sample Supplier", is_active: true }],
  materials: [{ id: materialId, material_code: "MAT-001", name: "Poly bag", canonical_unit_id: unitId, is_active: true }],
  units: [{ id: unitId, code: "PCS", name: "Pieces", dimension: "COUNT" }],
  locations: [{ id: shelfId, location_code: "IN-A1", name: "Receiving bay A1", location_type: "RECEIVING_BAY", is_leaf: true, is_active: true }],
  purchase_orders: [],
  goods_receipts: []
};

const jobFixture = {
  id: jobId,
  jobCode: "JOB-001",
  dailyPlanId: "plan-1",
  status: "RELEASED",
  isCustomized: false,
  masterBomId: "bom-v1",
  snapshot: {
    lines: [{
      materialId,
      quantityPerUnit: 1,
      canonicalQuantityPerUnit: 1,
      canonicalUnitId: unitId,
      isOptional: false
    }]
  },
  quantityStatus: {
    originalPlannedQuantity: 520,
    currentRevisedQuantity: 520,
    completedQuantity: 0,
    pendingQuantity: 520,
    cancelledQuantity: 0
  }
};

describe("Phase 8 transactional operator workflows (MSW + React)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("creates a purchase order through the authenticated Flask API without changing stock", async () => {
    const user = userEvent.setup();
    const db = configureDb(purchasingSeed);
    let requestBody: Record<string, unknown> | undefined;
    let requestHeaders: Headers | undefined;
    server.use(http.post(`${API_BASE_URL}/purchase-orders`, async ({ request }) => {
      requestHeaders = request.headers;
      requestBody = await request.json() as Record<string, unknown>;
      return HttpResponse.json({
        success: true, id: "po-1", poNumber: "PO-TEST-001", status: "DRAFT",
        lines: [{ materialId, orderedQuantity: 100, unitId, unitPrice: 2.5 }]
      }, { status: 201 });
    }));

    render(<MemoryRouter><PurchasingPage role="STOREKEEPER" /></MemoryRouter>);
    expect(await screen.findByText("No purchase orders yet")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /New purchase order/i }));
    await user.selectOptions(screen.getByLabelText(/Vendor/), vendorId);
    await user.selectOptions(screen.getByLabelText(/^Material/), materialId);
    await user.clear(screen.getByLabelText(/Ordered quantity/));
    await user.type(screen.getByLabelText(/Ordered quantity/), "100");
    await user.selectOptions(screen.getByLabelText(/Unit/), unitId);
    await user.clear(screen.getByLabelText(/Unit price/));
    await user.type(screen.getByLabelText(/Unit price/), "2.5");
    await user.click(screen.getByRole("button", { name: "Create draft PO" }));

    expect(await screen.findByText(/PO-TEST-001 created as a draft/i)).toBeInTheDocument();
    expect(requestHeaders?.get("authorization")).toBe(`Bearer ${userSession.access_token}`);
    expect(requestHeaders?.get("idempotency-key")).toMatch(/^web-/);
    expect(requestBody).toMatchObject({
      vendorId,
      lines: [{ materialId, orderedQuantity: 100, unitId, unitPrice: 2.5 }]
    });
    expect(db.operations.some((op) => op.table === "stock_transactions" && op.operation !== "select")).toBe(false);
  });

  it("creates a shift plan with repeated product/party jobs and distinct BOM versions", async () => {
    const user = userEvent.setup();
    configureDb({
      daily_plans: [],
      parties: [{ id: partyId, code: "PTY-1", name: "Customer One", is_active: true }],
      products: [{ id: productId, sku_code: "SKU-1", name: "Product One", default_party_id: partyId, is_active: true }],
      boms: [
        { id: "bom-v1", bom_code: "BOM-1", product_id: productId, party_id: partyId, packing_variant_name: "Screw M4x10", version_number: 1, status: "ACTIVE" },
        { id: "bom-v2", bom_code: "BOM-2", product_id: productId, party_id: partyId, packing_variant_name: "Screw M4x16", version_number: 2, status: "ACTIVE" }
      ],
      materials: [],
      units: []
    });
    let body: Record<string, unknown> | undefined;
    server.use(http.post(`${API_BASE_URL}/daily-plans`, async ({ request }) => {
      body = await request.json() as Record<string, unknown>;
      return HttpResponse.json({ success: true, id: "plan-new", planNumber: "PLAN-TEST-01", status: "DRAFT" }, { status: 201 });
    }));

    render(<MemoryRouter><PlanningPage role="PLANNER" shift="SHIFT_1" /></MemoryRouter>);
    expect(await screen.findByText("No daily plans")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /Create daily plan/i }));
    await user.selectOptions(screen.getAllByLabelText(/Customer party/)[0], partyId);
    await user.selectOptions(screen.getAllByLabelText(/Product/)[0], productId);
    await user.selectOptions(screen.getAllByLabelText(/Active BOM version/)[0], "bom-v1");
    await user.click(screen.getByRole("button", { name: /Add job/i }));
    await user.selectOptions(screen.getAllByLabelText(/Customer party/)[1], partyId);
    await user.selectOptions(screen.getAllByLabelText(/^Product$/)[1], productId);
    await user.selectOptions(screen.getAllByLabelText(/Active BOM version/)[1], "bom-v2");
    await user.clear(screen.getAllByLabelText(/Planned quantity/)[0]);
    await user.type(screen.getAllByLabelText(/Planned quantity/)[0], "300");
    await user.clear(screen.getAllByLabelText(/Planned quantity/)[1]);
    await user.type(screen.getAllByLabelText(/Planned quantity/)[1], "100");
    await user.click(screen.getByRole("button", { name: "Create draft plan" }));

    expect(await screen.findByText(/PLAN-TEST-01 created in draft status/i)).toBeInTheDocument();
    expect(body).toMatchObject({
      shiftCode: "SHIFT_1",
      masterDerivedJobs: [
        { partyId, productId, masterBomId: "bom-v1", plannedQuantity: 300 },
        { partyId, productId, masterBomId: "bom-v2", plannedQuantity: 100 }
      ],
      customJobs: []
    });
  });

  it("revises a job from 520 to 450 and cancels only the remaining quantity", async () => {
    const user = userEvent.setup();
    configureDb({ packing_jobs: [], production_completions: [], material_consumption_records: [] });
    let currentJob = structuredClone(jobFixture);
    let revisionBody: Record<string, unknown> | undefined;
    let cancellationBody: Record<string, unknown> | undefined;
    server.use(
      http.get(`${API_BASE_URL}/packing-jobs/${jobId}`, () => HttpResponse.json(currentJob)),
      http.post(`${API_BASE_URL}/packing-jobs/${jobId}/revise-quantity`, async ({ request }) => {
        revisionBody = await request.json() as Record<string, unknown>;
        currentJob = {
          ...currentJob,
          quantityStatus: { ...currentJob.quantityStatus, currentRevisedQuantity: 450, pendingQuantity: 450 }
        };
        return HttpResponse.json({ success: true, jobId, revisedQuantity: 450 });
      }),
      http.post(`${API_BASE_URL}/packing-jobs/${jobId}/cancel`, async ({ request }) => {
        cancellationBody = await request.json() as Record<string, unknown>;
        currentJob = {
          ...currentJob,
          status: "CANCELLED",
          quantityStatus: { ...currentJob.quantityStatus, pendingQuantity: 0, cancelledQuantity: 450 }
        };
        return HttpResponse.json({ success: true, jobId, status: "CANCELLED" });
      })
    );

    render(
      <MemoryRouter initialEntries={[`/daily-plans/jobs/${jobId}`]}>
        <Routes><Route path="/daily-plans/jobs/:id" element={<JobDetailPage role="PLANNER" />} /></Routes>
      </MemoryRouter>
    );
    await waitFor(() => expect(screen.getByText("Quantity conservation balanced").closest(".conservation-panel")?.textContent).toContain("520 = 0 + 520 + 0"));

    await user.click(screen.getByRole("button", { name: /Revise target/i }));
    await user.clear(screen.getByLabelText(/New authorized target/));
    await user.type(screen.getByLabelText(/New authorized target/), "450");
    await user.type(screen.getByLabelText(/Revision reason/), "Truck transport capacity limitation");
    await user.click(screen.getByRole("button", { name: "Confirm revision" }));
    await waitFor(() => expect(revisionBody).toMatchObject({ revisedQuantity: 450, reason: "Truck transport capacity limitation" }));
    await waitFor(() => expect(screen.getByText("Quantity conservation balanced").closest(".conservation-panel")?.textContent).toContain("450 = 0 + 450 + 0"));

    await user.click(screen.getByRole("button", { name: /Cancel remainder/i }));
    await user.type(screen.getByLabelText(/Cancellation reason/), "Customer order cancelled");
    await user.click(screen.getByRole("button", { name: "Confirm cancellation" }));
    await waitFor(() => expect(cancellationBody).toMatchObject({ reason: "Customer order cancelled" }));
    await waitFor(() => expect(screen.getByText("Quantity conservation balanced").closest(".conservation-panel")?.textContent).toContain("450 = 0 + 0 + 450"));
    expect(screen.getByText("CANCELLED")).toBeInTheDocument();
  });

  it("records production output and keeps auto-BOM consumption explicitly unverified", async () => {
    const user = userEvent.setup();
    configureDb({
      workers: [{ id: workerId, worker_code: "OP-01", name: "Operator One", is_active: true }],
    });
    let body: Record<string, unknown> | undefined;
    server.use(
      http.get(`${API_BASE_URL}/packing-jobs/${jobId}`, () => HttpResponse.json({
        ...jobFixture,
        quantityStatus: { ...jobFixture.quantityStatus, currentRevisedQuantity: 1000, pendingQuantity: 1000 }
      })),
      http.post(`${API_BASE_URL}/production/completions`, async ({ request }) => {
        body = await request.json() as Record<string, unknown>;
        return HttpResponse.json({
          success: true, id: "completion-1", completionNumber: "COMP-TEST-001",
          consumptions: [{
            id: "consumption-1", materialId, theoreticalQuantity: 530, postedLedgerQuantity: 530,
            physicallyConfirmedQuantity: null, varianceQuantity: null, varianceStatus: "UNVERIFIED"
          }]
        });
      })
    );

    render(
      <MemoryRouter initialEntries={[`/daily-plans/jobs/${jobId}/complete`]}>
        <Routes><Route path="/daily-plans/jobs/:id/complete" element={<ProductionPage role="OPERATOR" />} /></Routes>
      </MemoryRouter>
    );
    expect(await screen.findByRole("heading", { name: "Production batch" })).toBeInTheDocument();
    await user.clear(screen.getByLabelText(/Completed units/));
    await user.type(screen.getByLabelText(/Completed units/), "530");
    await user.selectOptions(screen.getByLabelText(/Packing operator/), workerId);
    await user.click(screen.getByRole("button", { name: /Record production completion/i }));

    expect(await screen.findByText(/Completion COMP-TEST-001 recorded/i)).toBeInTheDocument();
    expect(body).toMatchObject({
      packingJobId: jobId,
      completedUnits: 530,
      workerId,
      completionPolicy: "AUTO_BOM_THEORETICAL",
      actualMaterialUsage: []
    });
    expect(await screen.findByText("UNVERIFIED")).toBeInTheDocument();
    expect(body).not.toHaveProperty("varianceQuantity", 0);
  });
  it("posts a draft goods receipt through the authoritative API", async () => {
    const user = userEvent.setup();
    const draftGrn: MockRow = {
      id: "grn-1", grn_number: "GRN-TEST-01", vendor_id: vendorId, po_id: null,
      invoice_number: "INV-01", invoice_date: "2026-10-20", received_date: "2026-10-20",
      destination_location_id: shelfId, status: "DRAFT", created_at: "2026-10-20T00:00:00Z"
    };
    const db = configureDb({ ...purchasingSeed, goods_receipts: [draftGrn] });
    let body: Record<string, unknown> | undefined;
    server.use(http.post(`${API_BASE_URL}/goods-receipts/post`, async ({ request }) => {
      body = await request.json() as Record<string, unknown>;
      const saved = db.tables.goods_receipts?.find((row) => row.id === "grn-1");
      if (saved) saved.status = "POSTED";
      return HttpResponse.json({ success: true, goodsReceiptId: "grn-1", status: "POSTED", postedAt: "2026-10-20T10:00:00Z", lines: [] });
    }));

    render(<MemoryRouter><PurchasingPage role="STOREKEEPER" /></MemoryRouter>);
    await user.click(await screen.findByRole("button", { name: /Inward GRNs/i }));
    await user.click(await screen.findByRole("button", { name: /Post GRN/i }));

    expect(await screen.findByText(/grn-1 posted\. Canonical quantities and ledger transactions were confirmed/i)).toBeInTheDocument();
    expect(body).toEqual({ goodsReceiptId: "grn-1" });
    expect(db.operations.some((op) => op.table === "stock_transactions" && op.operation !== "select")).toBe(false);
  });

  it("issues material to worker custody and returns unused material with separate ledger API operations", async () => {
    const user = userEvent.setup();
    const custodyLocationId = "custody-location-1";
    const stockShelfId = "stock-shelf-1";
    const custodyRows: MockRow[] = [];
    configureDb({
      workers: [{ id: workerId, worker_code: "OP-01", name: "Operator One", assigned_location_id: custodyLocationId, is_active: true }],
      materials: [{ id: materialId, material_code: "MAT-001", name: "Poly bag", canonical_unit_id: unitId, is_active: true }],
      locations: [
        { id: stockShelfId, location_code: "S-01", name: "Store shelf", location_type: "STORE_SHELF", is_leaf: true, is_active: true },
        { id: custodyLocationId, location_code: "WC-01", name: "Operator custody", location_type: "WORKER_CUSTODY", is_leaf: true, is_active: true },
        { id: "quarantine-1", location_code: "Q-01", name: "Quarantine", location_type: "DAMAGE_QUARANTINE", is_leaf: true, is_active: true }
      ],
      packing_jobs: [{ id: jobId, job_code: "JOB-001", status: "RELEASED", assigned_worker_id: workerId, pending_quantity: 100, current_revised_quantity: 100 }]
    });
    const bodies: Array<{ path: string; body: Record<string, unknown> }> = [];
    server.use(
      http.get(`${API_BASE_URL}/stock/worker-custody`, () => HttpResponse.json(custodyRows)),
      http.post(`${API_BASE_URL}/stock/issue-to-worker`, async ({ request }) => {
        const body = await request.json() as Record<string, unknown>;
        bodies.push({ path: "/stock/issue-to-worker", body });
        custodyRows.splice(0, custodyRows.length, {
          workerId, workerName: "Operator One", workerCode: "OP-01", workerIsActive: true,
          materialId, materialName: "Poly bag", materialCode: "MAT-001",
          onHandQuantity: 10, availableQuantity: 10, canonicalUnitCode: "PCS"
        });
        return HttpResponse.json({ success: true, canonicalQuantity: 10, stockTransactionId: "transaction-issue-1" });
      }),
      http.post(`${API_BASE_URL}/stock/return-from-worker`, async ({ request }) => {
        const body = await request.json() as Record<string, unknown>;
        bodies.push({ path: "/stock/return-from-worker", body });
        custodyRows[0].onHandQuantity = 6;
        return HttpResponse.json({ success: true, canonicalQuantity: 4, stockTransactionId: "transaction-return-1" });
      })
    );

    render(<MemoryRouter><CustodyPage role="STOREKEEPER" /></MemoryRouter>);
    await user.selectOptions(await screen.findByLabelText(/Worker/), workerId);
    await user.selectOptions(screen.getByLabelText(/Packing job/), jobId);
    await user.selectOptions(screen.getByLabelText(/Material/), materialId);
    await user.selectOptions(screen.getByLabelText(/Source shelf/), stockShelfId);
    await user.clear(screen.getByLabelText(/Quantity/));
    await user.type(screen.getByLabelText(/Quantity/), "10");
    await user.type(screen.getByLabelText(/Measurement evidence/), "Count sheet 001");
    await user.click(screen.getByRole("button", { name: "Confirm material issue" }));
    expect(await screen.findByText(/Issued 10 units to Operator One/i)).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Return from worker" }));
    await user.selectOptions(screen.getByLabelText(/Return destination/), stockShelfId);
    await user.clear(screen.getByLabelText(/Quantity/));
    await user.type(screen.getByLabelText(/Quantity/), "4");
    await user.type(screen.getByLabelText(/Measurement evidence/), "Return count 002");
    await user.click(screen.getByRole("button", { name: "Confirm material return" }));

    expect(await screen.findByText(/Return posted\. Transaction/i)).toBeInTheDocument();
    expect(bodies).toHaveLength(2);
    expect(bodies[0]).toMatchObject({
      path: "/stock/issue-to-worker",
      body: { workerId, jobId, materialId, sourceLocationId: stockShelfId, destinationLocationId: custodyLocationId, quantity: 10, unitId }
    });
    expect(bodies[1]).toMatchObject({
      path: "/stock/return-from-worker",
      body: { workerId, jobId, materialId, sourceLocationId: custodyLocationId, destinationLocationId: stockShelfId, quantity: 4, unitId }
    });
  });

  it("keeps quarantine moves and scrap disposal as distinct authorized stock transactions", async () => {
    const user = userEvent.setup();
    const stockShelfId = "stock-shelf-1";
    const quarantineId = "quarantine-1";
    configureDb({
      materials: [{ id: materialId, material_code: "MAT-001", name: "Poly bag", canonical_unit_id: unitId, is_active: true }],
      locations: [
        { id: stockShelfId, location_code: "S-01", name: "Store shelf", location_type: "STORE_SHELF", is_leaf: true, is_active: true },
        { id: quarantineId, location_code: "Q-01", name: "Damage quarantine", location_type: "DAMAGE_QUARANTINE", is_leaf: true, is_active: true }
      ]
    });
    const bodies: Array<{ path: string; body: Record<string, unknown> }> = [];
    server.use(
      http.get(`${API_BASE_URL}/stock/balances`, () => HttpResponse.json([{
        id: "balance-q", materialId, materialCode: "MAT-001", materialName: "Poly bag",
        locationId: quarantineId, locationCode: "Q-01", locationType: "DAMAGE_QUARANTINE",
        onHandQuantity: 10, reservedQuantity: 0, availableQuantity: 0, canonicalUnitCode: "PCS"
      }])),
      http.post(`${API_BASE_URL}/stock/damage-quarantine`, async ({ request }) => {
        bodies.push({ path: "/stock/damage-quarantine", body: await request.json() as Record<string, unknown> });
        return HttpResponse.json({ success: true, stockTransactionId: "tx-quarantine" });
      }),
      http.post(`${API_BASE_URL}/stock/scrap-disposal`, async ({ request }) => {
        bodies.push({ path: "/stock/scrap-disposal", body: await request.json() as Record<string, unknown> });
        return HttpResponse.json({ success: true, stockTransactionId: "tx-scrap" });
      })
    );

    render(<MemoryRouter><QuarantinePage role="ADMIN" /></MemoryRouter>);
    await user.selectOptions(await screen.findByLabelText(/^Material/), materialId);
    await user.selectOptions(screen.getByLabelText(/Source location/), stockShelfId);
    await user.selectOptions(screen.getByLabelText(/Destination quarantine bay/), quarantineId);
    await user.clear(screen.getByLabelText(/Quantity/));
    await user.type(screen.getByLabelText(/Quantity/), "10");
    await user.type(screen.getByLabelText(/Quarantine reason/), "Moisture damage on receipt");
    await user.click(screen.getByRole("button", { name: "Confirm quarantine" }));
    expect(await screen.findByText(/Total physical stock is unchanged/i)).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Dispose of scrap" }));
    await user.selectOptions(screen.getByLabelText(/Quarantine source bay/), quarantineId);
    await user.clear(screen.getByLabelText(/Quantity/));
    await user.type(screen.getByLabelText(/Quantity/), "2");
    await user.clear(screen.getByLabelText(/Disposal reason/));
    await user.type(screen.getByLabelText(/Disposal reason/), "QC condemned material");
    await user.click(screen.getByRole("button", { name: "Confirm scrap disposal" }));
    expect(await screen.findByText(/Scrap disposal posted to the immutable ledger/i)).toBeInTheDocument();

    expect(bodies).toHaveLength(2);
    expect(bodies[0]).toMatchObject({
      path: "/stock/damage-quarantine",
      body: { materialId, quantity: 10, unitId, sourceLocationId: stockShelfId, destinationLocationId: quarantineId, quarantineReason: "Moisture damage on receipt" }
    });
    expect(bodies[1]).toMatchObject({
      path: "/stock/scrap-disposal",
      body: { materialId, quantity: 2, unitId, sourceLocationId: quarantineId, disposalReason: "QC condemned material" }
    });
  });

  it("submits custom daily-plan recipes as material lines without fabricating a master BOM", async () => {
    const user = userEvent.setup();
    const secondMaterialId = "material-2";
    configureDb({
      daily_plans: [],
      parties: [{ id: partyId, code: "PTY-1", name: "Customer One", is_active: true }],
      products: [{ id: productId, sku_code: "SKU-1", name: "Product One", default_party_id: partyId, is_active: true }],
      boms: [],
      materials: [
        { id: materialId, material_code: "MAT-001", name: "Poly bag", canonical_unit_id: unitId, is_active: true },
        { id: secondMaterialId, material_code: "MAT-002", name: "Label", canonical_unit_id: unitId, is_active: true }
      ],
      units: [{ id: unitId, code: "PCS", name: "Pieces", dimension: "COUNT" }]
    });
    let body: Record<string, unknown> | undefined;
    server.use(http.post(`${API_BASE_URL}/daily-plans`, async ({ request }) => {
      body = await request.json() as Record<string, unknown>;
      return HttpResponse.json({ success: true, id: "plan-custom", planNumber: "PLAN-CUSTOM-01", status: "DRAFT" }, { status: 201 });
    }));

    render(<MemoryRouter><PlanningPage role="PLANNER" shift="SHIFT_1" /></MemoryRouter>);
    await screen.findByText("No daily plans");
    await user.click(screen.getByRole("button", { name: /Create daily plan/i }));
    await user.selectOptions(screen.getByLabelText(/Recipe type/), "custom");
    await user.selectOptions(screen.getByLabelText(/Customer party/), partyId);
    await user.selectOptions(screen.getByLabelText(/Product/), productId);
    await user.selectOptions(screen.getByLabelText(/Custom material/), materialId);
    await user.click(screen.getByRole("button", { name: /Add custom material/i }));
    await user.selectOptions(screen.getAllByLabelText(/Custom material/)[1], secondMaterialId);
    await user.clear(screen.getAllByLabelText(/Qty per finished unit/)[1]);
    await user.type(screen.getAllByLabelText(/Qty per finished unit/)[1], "0.5");
    await user.click(screen.getByRole("button", { name: "Create draft plan" }));

    expect(await screen.findByText(/Daily plan PLAN-CUSTOM-01 created in draft status/i)).toBeInTheDocument();
    expect(body).toMatchObject({
      masterDerivedJobs: [],
      customJobs: [{
        partyId, productId, plannedQuantity: 100,
        customBomLines: [
          { materialId, quantityPerUnit: 1, unitId, isOptional: false, applicationNotes: null },
          { materialId: secondMaterialId, quantityPerUnit: 0.5, unitId, isOptional: false, applicationNotes: null }
        ]
      }]
    });
  });

  it("activates a BOM version through the backend and never mutates BOM tables directly", async () => {
    const user = userEvent.setup();
    const db = configureDb({
      boms: [{
        id: "bom-v1", bom_code: "BOM-1", product_id: productId, party_id: partyId,
        packing_variant_name: "Standard", version_number: 1, status: "DRAFT",
        notes: null, created_at: "2026-10-20T00:00:00Z", bom_lines: []
      }],
      products: [{ id: productId, sku_code: "SKU-1", name: "Product One", is_active: true }],
      parties: [{ id: partyId, code: "PTY-1", name: "Customer One", is_active: true }],
      materials: [{ id: materialId, material_code: "MAT-001", name: "Poly bag", canonical_unit_id: unitId, is_active: true }],
      units: [{ id: unitId, code: "PCS", name: "Pieces", dimension: "COUNT" }]
    });
    let body: unknown;
    server.use(http.post(`${API_BASE_URL}/boms/bom-v1/activate`, async ({ request }) => {
      body = await request.json();
      const row = db.tables.boms?.find((bom) => bom.id === "bom-v1");
      if (row) row.status = "ACTIVE";
      return HttpResponse.json({ success: true, id: "bom-v1", status: "ACTIVE" });
    }));

    render(<MemoryRouter><BomStudioPage role="PLANNER" /></MemoryRouter>);
    expect(await screen.findByText("BOM-1")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /Activate/ }));
    expect(await screen.findByText(/BOM-1 v1 is now active/i)).toBeInTheDocument();
    expect(body).toEqual({});
    expect(db.operations.some((op) => ["boms", "bom_lines"].includes(op.table) && op.operation !== "select")).toBe(false);
  });

  it("validates and closes a released shift through the audited closing API", async () => {
    const user = userEvent.setup();
    const dailyPlanId = "plan-1";
    configureDb({
      daily_plans: [{
        id: dailyPlanId, plan_number: "PLAN-001", plan_date: "2026-10-20",
        shift_code: "SHIFT_1", status: "RELEASED", packing_jobs: [{
          id: jobId, job_code: "JOB-001", status: "COMPLETED",
          current_revised_quantity: 100, completed_quantity: 100, pending_quantity: 0, cancelled_quantity: 0
        }]
      }],
      daily_closings: []
    });
    const detail = {
      id: dailyPlanId, planNumber: "PLAN-001", planDate: "2026-10-20", shiftCode: "SHIFT_1",
      jobs: [{
        id: jobId, jobCode: "JOB-001", status: "COMPLETED",
        quantityStatus: { originalPlannedQuantity: 100, currentRevisedQuantity: 100, completedQuantity: 100, pendingQuantity: 0, cancelledQuantity: 0 }
      }]
    };
    let body: Record<string, unknown> | undefined;
    server.use(
      http.get(`${API_BASE_URL}/daily-plans/${dailyPlanId}`, () => HttpResponse.json(detail)),
      http.post(`${API_BASE_URL}/closings`, async ({ request }) => {
        body = await request.json() as Record<string, unknown>;
        return HttpResponse.json({
          success: true, id: "closing-1", dailyPlanId, shiftCode: "SHIFT_1", closingDate: "2026-10-20",
          total_planned_units: 100, total_completed_units: 100, total_pending_units: 0,
          total_cancelled_units: 0, unresolvedDiscrepanciesCount: 0, discrepancyDetails: [],
          closedAt: "2026-10-20T12:00:00Z", isReopened: false
        });
      })
    );

    render(<MemoryRouter><ClosingPage role="STOREKEEPER" /></MemoryRouter>);
    await user.click(await screen.findByRole("button", { name: /Reconcile/ }));
    expect(await screen.findByText("PLAN-001")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Validate & close shift" }));

    expect(await screen.findByText(/Shift closing saved\. 0 discrepancy item\(s\) are recorded/i)).toBeInTheDocument();
    expect(body).toMatchObject({
      dailyPlanId, shiftCode: "SHIFT_1", allowDiscrepancyOverride: false,
      supervisorOverrideReason: null, pendingDispositions: []
    });
  });

  it("disables worker issue and return controls for a Viewer role", async () => {
    configureDb({
      workers: [{ id: workerId, worker_code: "OP-01", name: "Operator One", assigned_location_id: "custody-location-1", is_active: true }],
      materials: [{ id: materialId, material_code: "MAT-001", name: "Poly bag", canonical_unit_id: unitId, is_active: true }],
      locations: [
        { id: "shelf-1", location_code: "S-01", name: "Store shelf", location_type: "STORE_SHELF", is_leaf: true, is_active: true },
        { id: "custody-location-1", location_code: "WC-01", name: "Worker custody", location_type: "WORKER_CUSTODY", is_leaf: true, is_active: true }
      ],
      packing_jobs: [{ id: jobId, job_code: "JOB-001", status: "RELEASED", assigned_worker_id: workerId, pending_quantity: 10 }]
    });
    server.use(http.get(`${API_BASE_URL}/stock/worker-custody`, () => HttpResponse.json([])));

    render(<MemoryRouter><CustodyPage role="VIEWER" /></MemoryRouter>);
    expect(await screen.findByRole("button", { name: "Confirm material issue" })).toBeDisabled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Return from worker" }));
    expect(screen.getByRole("button", { name: "Confirm material return" })).toBeDisabled();
  });

});
