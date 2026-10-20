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
});
