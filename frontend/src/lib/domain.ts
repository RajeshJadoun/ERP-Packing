export type QuantityStatus = {
  originalPlannedQuantity: number;
  currentRevisedQuantity: number;
  completedQuantity: number;
  pendingQuantity: number;
  cancelledQuantity: number;
};

export function quantityBalanced(q: QuantityStatus): boolean {
  return q.currentRevisedQuantity === q.completedQuantity + q.pendingQuantity + q.cancelledQuantity;
}

export function quantityEquation(q: QuantityStatus): string {
  return `${q.currentRevisedQuantity} = ${q.completedQuantity} + ${q.pendingQuantity} + ${q.cancelledQuantity}`;
}

export function formatQuantity(value: number | string | null | undefined, maximumFractionDigits = 3): string {
  if (value === null || value === undefined || value === "") return "—";
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return "—";
  return new Intl.NumberFormat("en-IN", { maximumFractionDigits, minimumFractionDigits: 0 }).format(parsed);
}

export function variancePreview(actual: number | string, theoretical: number | string) {
  const a = Number(actual);
  const t = Number(theoretical);
  if (!Number.isFinite(a) || !Number.isFinite(t) || String(actual).trim() === "") {
    return { variance: null as number | null, status: "UNVERIFIED" as const };
  }
  const variance = a - t;
  return { variance, status: variance === 0 ? "VERIFIED_ZERO" as const : "VARIANCE_RECORDED" as const };
}

export function validateCategory(code: string, name: string): string | null {
  if (!/^[A-Z0-9_-]{2,40}$/.test(code.trim().toUpperCase())) return "Code must be 2–40 letters, digits, dashes or underscores.";
  if (!name.trim()) return "Name is required.";
  return null;
}

export function csvValue(value: unknown): string {
  const stringValue = typeof value === "object" && value !== null ? JSON.stringify(value) : String(value ?? "");
  return `"${stringValue.replace(/"/g, '""')}"`;
}

export function toCsv(rows: Array<Record<string, unknown>>): string {
  if (!rows.length) return "";
  const columns = Array.from(new Set(rows.flatMap((row) => Object.keys(row))));
  return [columns.map(csvValue).join(","), ...rows.map((row) => columns.map((column) => csvValue(row[column])).join(","))].join("\r\n");
}