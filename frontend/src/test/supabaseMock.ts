import { vi } from "vitest";

export type MockRow = Record<string, unknown>;
export type MockOperation = {
  table: string;
  operation: "select" | "insert" | "update" | "delete";
  payload?: unknown;
  filters: Array<{ kind: "eq" | "in" | "is" | "gte" | "lte"; key: string; value: unknown }>;
};

type QueryState = {
  table: string;
  operation: MockOperation["operation"];
  payload?: unknown;
  filters: MockOperation["filters"];
  limit?: number;
  order?: { key: string; ascending: boolean };
};

export function createSupabaseMock(seed: Record<string, MockRow[]> = {}) {
  const tables: Record<string, MockRow[]> = Object.fromEntries(
    Object.entries(seed).map(([name, rows]) => [name, rows.map((row) => ({ ...row }))])
  );
  const operations: MockOperation[] = [];
  const errors: Record<string, Error> = {};
  let sequence = 0;

  const matches = (row: MockRow, filter: QueryState["filters"][number]) => {
    const left = row[filter.key];
    if (filter.kind === "eq") return String(left) === String(filter.value);
    if (filter.kind === "is") return left === filter.value;
    if (filter.kind === "in") return Array.isArray(filter.value) && filter.value.some((value) => String(value) === String(left));
    if (filter.kind === "gte") return String(left ?? "") >= String(filter.value ?? "");
    return String(left ?? "") <= String(filter.value ?? "");
  };

  const from = vi.fn((table: string) => {
    const state: QueryState = { table, operation: "select", filters: [] };
    const builder: Record<string, (...args: any[]) => any> = {};

    builder.select = () => builder;
    builder.insert = (payload: unknown) => { state.operation = "insert"; state.payload = payload; return builder; };
    builder.update = (payload: unknown) => { state.operation = "update"; state.payload = payload; return builder; };
    builder.delete = () => { state.operation = "delete"; return builder; };
    builder.eq = (key: string, value: unknown) => { state.filters.push({ kind: "eq", key, value }); return builder; };
    builder.in = (key: string, value: unknown) => { state.filters.push({ kind: "in", key, value }); return builder; };
    builder.is = (key: string, value: unknown) => { state.filters.push({ kind: "is", key, value }); return builder; };
    builder.gte = (key: string, value: unknown) => { state.filters.push({ kind: "gte", key, value }); return builder; };
    builder.lte = (key: string, value: unknown) => { state.filters.push({ kind: "lte", key, value }); return builder; };
    builder.order = (key: string, options?: { ascending?: boolean }) => {
      state.order = { key, ascending: options?.ascending ?? true };
      return builder;
    };
    builder.limit = (value: number) => { state.limit = value; return builder; };

    const execute = async () => {
      operations.push({
        table: state.table,
        operation: state.operation,
        payload: state.payload,
        filters: state.filters.map((filter) => ({ ...filter }))
      });
      if (errors[state.table]) return { data: null, error: errors[state.table] };
      const rows = tables[state.table] ?? (tables[state.table] = []);
      const selected = rows.filter((row) => state.filters.every((filter) => matches(row, filter)));
      if (state.operation === "insert") {
        const inputRows = (Array.isArray(state.payload) ? state.payload : [state.payload]) as MockRow[];
        const inserted = inputRows.map((row) => ({
          id: row.id ?? `mock-${state.table}-${++sequence}`,
          created_at: row.created_at ?? "2026-10-20T00:00:00Z",
          ...row
        }));
        rows.push(...inserted);
        return { data: inserted, error: null };
      }
      if (state.operation === "update") {
        for (const row of selected) Object.assign(row, state.payload);
        return { data: selected, error: null };
      }
      if (state.operation === "delete") {
        tables[state.table] = rows.filter((row) => !selected.includes(row));
        return { data: selected, error: null };
      }
      let result = [...selected];
      if (state.order) {
        const { key, ascending } = state.order;
        result.sort((a, b) => {
          const left = String(a[key] ?? "");
          const right = String(b[key] ?? "");
          const cmp = left.localeCompare(right, undefined, { numeric: true });
          return ascending ? cmp : -cmp;
        });
      }
      if (state.limit !== undefined) result = result.slice(0, state.limit);
      return { data: result, error: null };
    };

    builder.single = async () => {
      const result = await execute();
      return { data: result.data?.[0] ?? null, error: result.error };
    };
    builder.maybeSingle = builder.single;
    builder.then = (resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) =>
      execute().then(resolve, reject);
    return builder;
  });

  return {
    tables,
    operations,
    errors,
    from,
    reset: (seedRows: Record<string, MockRow[]> = {}) => {
      for (const key of Object.keys(tables)) delete tables[key];
      for (const [key, rows] of Object.entries(seedRows)) tables[key] = rows.map((row) => ({ ...row }));
      operations.length = 0;
      for (const key of Object.keys(errors)) delete errors[key];
      sequence = 0;
    }
  };
}
