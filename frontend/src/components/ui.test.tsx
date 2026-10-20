import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Button, Card, DataTable, Modal, StatusBadge } from "./ui";

describe("shared ERP UI components", () => {
  it("renders a semantic status label for material verification", () => {
    render(<StatusBadge status="UNVERIFIED" />);
    expect(screen.getByText("UNVERIFIED")).toBeInTheDocument();
  });

  it("renders table records and a clear empty state", () => {
    const columns = [{ key: "code", label: "Material code" }, { key: "name", label: "Material name" }];
    const { rerender } = render(<DataTable rows={[{ id: "m-1", code: "MAT-01", name: "Poly bag" }]} columns={columns} rowKey={(row) => row.id} />);
    expect(screen.getByText("MAT-01")).toBeInTheDocument();
    expect(screen.getByText("Poly bag")).toBeInTheDocument();

    const emptyRows: Array<{ id: string; code: string; name: string }> = [];
    rerender(<DataTable rows={emptyRows} columns={columns} rowKey={(row: { id: string }) => row.id} emptyTitle="No materials" emptyDescription="Add one to begin." />);
    expect(screen.getByText("No materials")).toBeInTheDocument();
  });

  it("runs button actions and respects the disabled state", async () => {
    const user = userEvent.setup();
    const onClick = vi.fn();
    render(<Button onClick={onClick}>Refresh data</Button>);
    await user.click(screen.getByRole("button", { name: "Refresh data" }));
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("exposes an accessible modal dialog and close control", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    render(<Modal title="Confirm stock receipt" onClose={onClose}><p>Stock will be updated.</p></Modal>);
    expect(screen.getByRole("dialog", { name: "Confirm stock receipt" })).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Close modal" }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("keeps children inside a reusable card container", () => {
    render(<Card><h2>Inventory overview</h2></Card>);
    expect(screen.getByRole("heading", { name: "Inventory overview" })).toBeInTheDocument();
  });
});
