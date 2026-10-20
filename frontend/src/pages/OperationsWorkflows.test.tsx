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
    await user.selectOptions(screen.getByLabelText("Vendor"), vendorId);
    await user.selectOptions(screen.getByLabelText("Material"), materialId);
    await user.clear(screen.getByLabelText("Ordered quantity"));
    await user.type(screen.getByLabelText("Ordered quantity"), "100");
    await user.selectOptions(screen.getByLabelText("Unit"), unitId);
    await user.clear(screen.getByLabelText("Unit price (₹)"));
    await user.type(screen.getByLabelText("Unit price (₹)"), "2.5");
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
    await user.selectOptions(screen.getAllByLabelText("Customer party")[0], partyId);
    await user.selectOptions(screen.getAllByLabelText("Product")[0], productId);
    await user.selectOptions(screen.getAllByLabelText("Active BOM version")[0], "bom-v1");
    await user.click(screen.getByRole("button", { name: /Add job/i }));
    await user.selectOptions(screen.getAllByLabelText("Customer party")[1], partyId);
    await user.selectOptions(screen.getAllByLabelText("Product")[1], productId);
    await user.selectOptions(screen.getAllByLabelText("Active BOM version")[1], "bom-v2");
    await user.clear(screen.getAllByLabelText("Planned quantity")[0]);
    await user.type(screen.getAllByLabelText("Planned quantity")[0], "300");
    await user.clear(screen.getAllByLabelText("Planned quantity")[1]);
    await user.type(screen.getAllByLabelText("Planned quantity")[1], "100");
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
    expect(await screen.findByText("520 = 0 + 520 + 0")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /Revise target/i }));
    await user.clear(screen.getByLabelText("New authorized target"));
    await user.type(screen.getByLabelText("New authorized target"), "450");
    await user.type(screen.getByLabelText("Revision reason"), "Truck transport capacity limitation");
    await user.click(screen.getByRole("button", { name: "Confirm revision" }));
    await waitFor(() => expect(revisionBody).toMatchObject({ revisedQuantity: 450, reason: "Truck transport capacity limitation" }));
    expect(await screen.findByText("450 = 0 + 450 + 0")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /Cancel remainder/i }));
    await user.type(screen.getByLabelText("Cancellation reason"), "Customer order cancelled");
    await user.click(screen.getByRole("button", { name: "Confirm cancellation" }));
    await waitFor(() => expect(cancellationBody).toMatchObject({ reason: "Customer order cancelled" }));
    expect(await screen.findByText("450 = 0 + 0 + 450")).toBeInTheDocument();
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
    await user.clear(screen.getByLabelText("Completed units"));
    await user.type(screen.getByLabelText("Completed units"), "530");
    await user.selectOptions(screen.getByLabelText("Packing operator"), workerId);
    await user.click(screen.getByRole("button", { name: /Record production completion/i }));

    expect(await screen.findByText(/COMP-TEST-001/)).toBeInTheDocument();
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
});
