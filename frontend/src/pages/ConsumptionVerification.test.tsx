import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { apiGet, apiPost } from "../lib/api";
import { ConsumptionVerificationPage } from "./ConsumptionVerification";

vi.mock("../lib/api", () => ({
  apiGet: vi.fn(),
  apiPost: vi.fn()
}));

const completion = {
  id: "completion-1",
  completionId: "completion-1",
  completionNumber: "COMP-20261020-00000001",
  packingJobId: "job-1",
  completedUnits: 25,
  completionPolicy: "AUTO_BOM_THEORETICAL",
  createdAt: "2026-10-20T09:00:00Z",
  consumptions: [
    {
      id: "consumption-1",
      materialId: "material-1",
      theoreticalQuantity: 125,
      postedLedgerQuantity: 125,
      physicallyConfirmedQuantity: null,
      varianceQuantity: null,
      varianceStatus: "UNVERIFIED",
      stockTransactionId: "transaction-1",
      canonicalUnitId: "unit-1",
      canonicalUnitCode: "PCS",
      ledgerQuantityEstimated: true
    },
    {
      id: "consumption-2",
      materialId: "material-2",
      theoreticalQuantity: 50,
      postedLedgerQuantity: 50,
      physicallyConfirmedQuantity: null,
      varianceQuantity: null,
      varianceStatus: "UNVERIFIED",
      stockTransactionId: "transaction-2",
      canonicalUnitId: "unit-2",
      canonicalUnitCode: "KG",
      ledgerQuantityEstimated: true
    }
  ]
};

function renderPage(role = "OPERATOR") {
  return render(
    <MemoryRouter initialEntries={["/production/completions/completion-1/verify"]}>
      <Routes>
        <Route path="/production/completions/:id/verify" element={<ConsumptionVerificationPage role={role} />} />
      </Routes>
    </MemoryRouter>
  );
}

describe("post-completion physical consumption verification", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(apiGet).mockResolvedValue(completion as never);
    vi.mocked(apiPost).mockResolvedValue({
      success: true,
      id: "completion-1",
      completionId: "completion-1",
      verifiedCount: 2,
      consumptions: completion.consumptions.map((row) => ({
        ...row,
        physicallyConfirmedQuantity: row.theoreticalQuantity,
        varianceQuantity: 0,
        varianceStatus: "VERIFIED_ZERO"
      }))
    } as never);
  });

  it("shows estimated theoretical use as unverified, not as zero variance", async () => {
    renderPage();
    expect(await screen.findByText("COMP-20261020-00000001")).toBeInTheDocument();
    expect(screen.getAllByText("UNVERIFIED").length).toBeGreaterThan(0);
    expect(screen.getByText("125")).toBeInTheDocument();
    expect(screen.getByText("50")).toBeInTheDocument();
  });

  it("requires a complete physical count and posts every material in its canonical unit", async () => {
    const user = userEvent.setup();
    renderPage();

    const quantities = await screen.findAllByLabelText(/Physically confirmed quantity/i);
    await user.type(quantities[0], "127");
    await user.type(quantities[1], "49.5");

    await user.click(screen.getByRole("button", { name: /save all physical counts/i }));

    await waitFor(() => expect(apiPost).toHaveBeenCalledTimes(1));
    expect(apiPost).toHaveBeenCalledWith(
      "/production/completions/completion-1/consumption/verify",
      {
        actualMaterialUsage: [
          {
            materialId: "material-1",
            physicallyConfirmedQuantity: 127,
            unitId: "unit-1",
            measurementMethod: "MANUALLY_COUNTED",
            measurementEvidence: null
          },
          {
            materialId: "material-2",
            physicallyConfirmedQuantity: 49.5,
            unitId: "unit-2",
            measurementMethod: "MANUALLY_COUNTED",
            measurementEvidence: null
          }
        ]
      }
    );
    expect(await screen.findByText(/physical counts saved/i)).toBeInTheDocument();
  });

  it("does not expose the count form to a viewer role", async () => {
    renderPage("VIEWER");
    expect(await screen.findByText(/your role cannot record physical counts/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /save all physical counts/i })).not.toBeInTheDocument();
  });
});
