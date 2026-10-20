import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { ReportsAnalyticsPage } from "./ReportsAnalytics";

const mocks = vi.hoisted(() => ({
  reportData: null as Record<string, unknown> | null,
  downloadCsv: vi.fn(),
  selectRows: vi.fn(async () => []),
  reload: vi.fn()
}));

vi.mock("../../lib/api", () => ({ apiGet: vi.fn() }));
vi.mock("../shared", () => ({
  useAsyncData: () => ({
    data: mocks.reportData,
    loading: false,
    error: "",
    reload: mocks.reload,
    setData: vi.fn()
  }),
  selectRows: mocks.selectRows,
  downloadCsv: mocks.downloadCsv,
  displayDate: (value: unknown) => value ? String(value) : "—"
}));

const stockRow = {
  material_id: "mat-1",
  material_code: "MAT-001",
  material_name: "Poly bag",
  location_id: "loc-1",
  location_code: "S-01",
  location_name: "Store shelf",
  location_type: "STORE_SHELF",
  location_is_active: true,
  is_leaf: true,
  inventory_segment: "USABLE",
  on_hand_quantity: "25",
  reserved_quantity: "4",
  available_quantity: "21",
  canonical_unit_code: "PCS"
};

describe("Phase 9 operations analytics page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.reportData = {
      stock: [stockRow],
      custody: [],
      consumption: [],
      production: [],
      workerOutput: [],
      vendorHistory: [],
      materials: [],
      workers: [],
      vendors: []
    };
  });

  it("renders the inventory view and exports the filtered displayed rows as CSV", () => {
    render(<ReportsAnalyticsPage />);

    expect(screen.getByRole("heading", { name: "Operations intelligence" })).toBeInTheDocument();
    expect(screen.getByText("Poly bag")).toBeInTheDocument();
    expect(screen.getByText("21 PCS")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Export CSV" }));
    expect(mocks.downloadCsv).toHaveBeenCalledWith("packwise-stock-report.csv", [stockRow]);
  });

  it("searches within the active report before exporting", () => {
    const second = { ...stockRow, material_id: "mat-2", material_code: "MAT-002", material_name: "Carton" };
    mocks.reportData = { ...mocks.reportData, stock: [stockRow, second] };
    render(<ReportsAnalyticsPage />);

    fireEvent.change(screen.getByRole("textbox", { name: "Search displayed report rows…" }), {
      target: { value: "MAT-002" }
    });

    expect(screen.getByText("Carton")).toBeInTheDocument();
    expect(screen.queryByText("Poly bag")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Export CSV" }));
    expect(mocks.downloadCsv).toHaveBeenCalledWith("packwise-stock-report.csv", [second]);
  });

  it("renders unverified physical consumption as Not verified and never falsely 0", () => {
    const consumptionRow = {
      consumption_id: "c-1",
      completion_number: "CMP-001",
      shift_code: "SHIFT_1",
      worker_name: "Ramesh Kumar",
      material_name: "Poly Bag 25kg",
      canonical_unit_code: "KG",
      theoretical_quantity: "530",
      physically_confirmed_quantity: null,
      variance_quantity: null,
      variance_status: "UNVERIFIED"
    };
    mocks.reportData = { ...mocks.reportData, consumption: [consumptionRow] };
    render(<ReportsAnalyticsPage />);

    fireEvent.click(screen.getByRole("button", { name: /Consumption variance/ }));

    expect(screen.getByText("CMP-001")).toBeInTheDocument();
    expect(screen.getByText("Not verified")).toBeInTheDocument();
    expect(screen.queryByText("0.000 KG")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Export CSV" }));
    expect(mocks.downloadCsv).toHaveBeenCalledWith("packwise-consumption-report.csv", [consumptionRow]);
  });

  it("renders shift production summaries and switches to worker custody tab", () => {
    const shiftRow = {
      plan_id: "plan-1",
      plan_number: "PLAN-2026-10-20-01",
      plan_date: "2026-10-20",
      shift_code: "SHIFT_1",
      job_count: 2,
      authorized_units: 1000,
      completed_units: 530,
      pending_units: 470,
      cancelled_units: 0,
      completion_count: 1
    };
    const custodyRow = {
      worker_id: "w-1",
      worker_name: "Sita Sharma",
      worker_code: "WRK-001",
      material_id: "mat-1",
      material_code: "MAT-001",
      material_name: "Box Liner",
      location_code: "LOC-CUST-1",
      on_hand_quantity: "15",
      canonical_unit_code: "PCS",
      worker_is_active: true
    };
    mocks.reportData = { ...mocks.reportData, production: [shiftRow], custody: [custodyRow] };
    render(<ReportsAnalyticsPage />);

    // Production tab
    fireEvent.click(screen.getByRole("button", { name: /Production by shift/ }));
    expect(screen.getByText("PLAN-2026-10-20-01")).toBeInTheDocument();

    // Custody tab
    fireEvent.click(screen.getByRole("button", { name: /Worker custody/ }));
    expect(screen.getByText("Sita Sharma")).toBeInTheDocument();
    expect(screen.getByText("15 PCS")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Export CSV" }));
    expect(mocks.downloadCsv).toHaveBeenCalledWith("packwise-custody-report.csv", [custodyRow]);
  });

  it("shows validation error when from date is after to date", () => {
    render(<ReportsAnalyticsPage />);

    const fromDateInput = screen.getByLabelText("From date");
    const toDateInput = screen.getByLabelText("To date");

    fireEvent.change(fromDateInput, { target: { value: "2026-10-25" } });
    fireEvent.change(toDateInput, { target: { value: "2026-10-20" } });

    expect(screen.getByText("From date cannot be after the to date.")).toBeInTheDocument();
  });
});

