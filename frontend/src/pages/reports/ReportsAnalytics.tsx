import { useMemo, useState, type FormEvent } from "react";
import {
  Activity, Download, FileBarChart2, Factory, PackageSearch, Printer, RefreshCw, ShieldAlert, Users
} from "lucide-react";
import { apiGet } from "../../lib/api";
import { formatQuantity } from "../../lib/domain";
import {
  Alert, Badge, Button, Card, DataTable, Field, MetricCard, PageHeader, SearchBox,
  SelectField, StatusBadge, Toolbar
} from "../../components/ui";
import { displayDate, downloadCsv, selectRows, useAsyncData, type Row } from "../shared";
import "./reports.css";

type ReportTab = "stock" | "consumption" | "production" | "worker-output" | "vendors" | "custody";
type Filters = {
  fromDate: string;
  toDate: string;
  shiftCode: string;
  materialId: string;
  workerId: string;
  vendorId: string;
};
type ReportData = {
  stock: Row[];
  custody: Row[];
  consumption: Row[];
  production: Row[];
  workerOutput: Row[];
  vendorHistory: Row[];
  materials: Row[];
  workers: Row[];
  vendors: Row[];
};

const EMPTY_FILTERS: Filters = {
  fromDate: "", toDate: "", shiftCode: "", materialId: "", workerId: "", vendorId: ""
};

function queryString(filters: Filters, fields: Array<keyof Filters>, limit = 1000): string {
  const params = new URLSearchParams();
  for (const field of fields) {
    const value = filters[field].trim();
    if (value) params.set(field, value);
  }
  params.set("limit", String(limit));
  params.set("offset", "0");
  return `?${params.toString()}`;
}

const quantity = (value: unknown) => formatQuantity(value as number | string | null | undefined);
const dateLabel = (value: unknown) => displayDate(value);

function containsQuery(row: Row, search: string): boolean {
  if (!search.trim()) return true;
  const text = Object.values(row).map((value) => String(value ?? "")).join(" ").toLowerCase();
  return text.includes(search.trim().toLowerCase());
}

export function ReportsAnalyticsPage() {
  const [tab, setTab] = useState<ReportTab>("stock");
  const [search, setSearch] = useState("");
  const [draft, setDraft] = useState<Filters>(EMPTY_FILTERS);
  const [applied, setApplied] = useState<Filters>(EMPTY_FILTERS);

  const state = useAsyncData<ReportData>(async () => {
    const [stock, custody, consumption, production, workerOutput, vendorHistory, materials, workers, vendors] =
      await Promise.all([
        apiGet<Row[]>(`/reports/stock${queryString(applied, ["materialId"])}`),
        apiGet<Row[]>(`/reports/worker-custody${queryString(applied, ["materialId", "workerId"])}`),
        apiGet<Row[]>(`/reports/consumption-variance${queryString(applied, ["fromDate", "toDate", "shiftCode", "materialId", "workerId"])}`),
        apiGet<Row[]>(`/reports/production-shifts${queryString(applied, ["fromDate", "toDate", "shiftCode"])}`),
        apiGet<Row[]>(`/reports/worker-output${queryString(applied, ["fromDate", "toDate", "shiftCode", "workerId"])}`),
        apiGet<Row[]>(`/reports/vendor-purchase-history${queryString(applied, ["fromDate", "toDate", "vendorId"])}`),
        selectRows("materials", "id,material_code,name,is_active", "name", 1000),
        selectRows("workers", "id,worker_code,name,is_active", "name", 1000),
        selectRows("vendors", "id,vendor_code,name,is_active", "name", 1000)
      ]);
    return { stock, custody, consumption, production, workerOutput, vendorHistory, materials, workers, vendors };
  }, JSON.stringify(applied));

  const data = state.data;
  const stock = data?.stock ?? [];
  const custody = data?.custody ?? [];
  const consumption = data?.consumption ?? [];
  const production = data?.production ?? [];
  const workerOutput = data?.workerOutput ?? [];
  const vendorHistory = data?.vendorHistory ?? [];
  const materials = (data?.materials ?? []).filter((r) => r.is_active !== false);
  const workers = (data?.workers ?? []).filter((r) => r.is_active !== false);
  const vendors = (data?.vendors ?? []).filter((r) => r.is_active !== false);

  const tabs: Array<{ id: ReportTab; label: string; rows: Row[] }> = [
    { id: "stock", label: "Stock by location", rows: stock },
    { id: "consumption", label: "Consumption variance", rows: consumption },
    { id: "production", label: "Production by shift", rows: production },
    { id: "worker-output", label: "Worker output", rows: workerOutput },
    { id: "vendors", label: "Vendor history", rows: vendorHistory },
    { id: "custody", label: "Worker custody", rows: custody }
  ];

  const sourceRows: Row[] = tab === "stock" ? stock
    : tab === "consumption" ? consumption
    : tab === "production" ? production
    : tab === "worker-output" ? workerOutput
    : tab === "vendors" ? vendorHistory
    : custody;
  const reportRows = useMemo(
    () => sourceRows.filter((row) => containsQuery(row, search)),
    [sourceRows, search]
  );

  const unresolved = consumption.filter((r) => r.variance_status !== "VERIFIED_ZERO").length;
  const completedUnits = workerOutput.reduce((sum, row) => sum + Number(row.completed_units ?? 0), 0);
  const completionBatches = workerOutput.reduce((sum, row) => sum + Number(row.completion_count ?? 0), 0);
  const segmentCounts = ["USABLE", "WORKER_CUSTODY", "QUARANTINE"].map((segment) => ({
    segment,
    count: stock.filter((row) => row.inventory_segment === segment).length
  }));
  const maxSegmentCount = Math.max(1, ...segmentCounts.map((item) => item.count));

  const columns: Record<ReportTab, Array<{ key: string; label: string; render?: (row: Row) => React.ReactNode }>> = {
    stock: [
      { key: "material_name", label: "Material", render: (r: Row) => <div className="report-primary-cell"><strong>{r.material_name}</strong><small>{r.material_code}</small></div> },
      { key: "location_name", label: "Location", render: (r: Row) => <div className="report-primary-cell"><strong>{r.location_name}</strong><small>{r.location_code} · {String(r.location_type ?? "").replaceAll("_", " ")}</small></div> },
      { key: "inventory_segment", label: "Segment", render: (r: Row) => <Badge tone={r.inventory_segment === "QUARANTINE" ? "red" : r.inventory_segment === "WORKER_CUSTODY" ? "amber" : "green"}>{String(r.inventory_segment ?? "—").replaceAll("_", " ")}</Badge> },
      { key: "on_hand_quantity", label: "On hand", render: (r: Row) => quantity(r.on_hand_quantity) },
      { key: "reserved_quantity", label: "Reserved", render: (r: Row) => quantity(r.reserved_quantity) },
      { key: "available_quantity", label: "Available", render: (r: Row) => <strong>{quantity(r.available_quantity)} {r.canonical_unit_code}</strong> }
    ],
    consumption: [
      { key: "completion_number", label: "Completion", render: (r: Row) => <div className="report-primary-cell"><strong>{r.completion_number}</strong><small>{r.job_code ?? "Job"} · {r.shift_code}</small></div> },
      { key: "worker_name", label: "Worker", render: (r: Row) => <div className="report-primary-cell"><strong>{r.worker_name ?? "Unassigned"}</strong><small>{r.worker_code ?? "—"}</small></div> },
      { key: "material_name", label: "Material", render: (r: Row) => <div className="report-primary-cell"><strong>{r.material_name}</strong><small>{r.material_code}</small></div> },
      { key: "theoretical_quantity", label: "Theoretical", render: (r: Row) => <>{quantity(r.theoretical_quantity)} {r.canonical_unit_code}</> },
      { key: "physically_confirmed_quantity", label: "Physical", render: (r: Row) => r.physically_confirmed_quantity == null ? <Badge tone="amber">Not verified</Badge> : <>{quantity(r.physically_confirmed_quantity)} {r.canonical_unit_code}</> },
      { key: "variance_quantity", label: "Variance", render: (r: Row) => r.variance_quantity == null ? "—" : <strong>{quantity(r.variance_quantity)} {r.canonical_unit_code}</strong> },
      { key: "variance_status", label: "Status", render: (r: Row) => <StatusBadge status={r.variance_status} /> }
    ],
    production: [
      { key: "plan_number", label: "Plan", render: (r: Row) => <div className="report-primary-cell"><strong>{r.plan_number}</strong><small>{dateLabel(r.plan_date)}</small></div> },
      { key: "shift_code", label: "Shift", render: (r: Row) => <Badge tone="blue">{r.shift_code}</Badge> },
      { key: "job_count", label: "Jobs", render: (r: Row) => quantity(r.job_count) },
      { key: "authorized_units", label: "Authorized", render: (r: Row) => quantity(r.authorized_units) },
      { key: "completed_units", label: "Completed", render: (r: Row) => <strong>{quantity(r.completed_units)}</strong> },
      { key: "pending_units", label: "Pending", render: (r: Row) => quantity(r.pending_units) },
      { key: "cancelled_units", label: "Cancelled", render: (r: Row) => quantity(r.cancelled_units) },
      { key: "completion_count", label: "Batches", render: (r: Row) => quantity(r.completion_count) }
    ],
    "worker-output": [
      { key: "plan_number", label: "Plan / shift", render: (r: Row) => <div className="report-primary-cell"><strong>{r.plan_number}</strong><small>{dateLabel(r.plan_date)} · {r.shift_code}</small></div> },
      { key: "worker_name", label: "Worker", render: (r: Row) => <div className="report-primary-cell"><strong>{r.worker_name}</strong><small>{r.worker_code}</small></div> },
      { key: "completed_units", label: "Completed units", render: (r: Row) => <strong>{quantity(r.completed_units)}</strong> },
      { key: "completed_job_count", label: "Jobs completed", render: (r: Row) => quantity(r.completed_job_count) },
      { key: "completion_count", label: "Completion batches", render: (r: Row) => quantity(r.completion_count) }
    ],
    vendors: [
      { key: "vendor_name", label: "Vendor", render: (r: Row) => <div className="report-primary-cell"><strong>{r.vendor_name}</strong><small>{r.vendor_code}</small></div> },
      { key: "grn_number", label: "GRN / receipt", render: (r: Row) => <div className="report-primary-cell"><strong>{r.grn_number}</strong><small>{r.po_number ?? "No linked PO"}</small></div> },
      { key: "received_date", label: "Received", render: (r: Row) => dateLabel(r.received_date) },
      { key: "receipt_status", label: "Status", render: (r: Row) => <StatusBadge status={r.receipt_status} /> },
      { key: "receipt_line_count", label: "Lines", render: (r: Row) => quantity(r.receipt_line_count) },
      { key: "rejected_line_rate_pct", label: "Rejected line rate", render: (r: Row) => <strong>{quantity(r.rejected_line_rate_pct)}%</strong> },
      { key: "lead_time_days", label: "Lead time", render: (r: Row) => r.lead_time_days == null ? "—" : `${quantity(r.lead_time_days)} days` },
      { key: "delivery_variance_days", label: "Vs. expected", render: (r: Row) => r.delivery_variance_days == null ? "—" : `${quantity(r.delivery_variance_days)} days` }
    ],
    custody: [
      { key: "worker_name", label: "Worker", render: (r: Row) => <div className="report-primary-cell"><strong>{r.worker_name}</strong><small>{r.worker_code} · {r.worker_is_active ? "Active" : "Inactive"}</small></div> },
      { key: "material_name", label: "Material", render: (r: Row) => <div className="report-primary-cell"><strong>{r.material_name}</strong><small>{r.material_code}</small></div> },
      { key: "location_code", label: "Custody location" },
      { key: "on_hand_quantity", label: "Outstanding", render: (r: Row) => <strong>{quantity(r.on_hand_quantity)} {r.canonical_unit_code}</strong> },
      { key: "balance_updated_at", label: "Updated", render: (r: Row) => dateLabel(r.balance_updated_at) }
    ]
  };

  const submitFilters = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (draft.fromDate && draft.toDate && draft.fromDate > draft.toDate) return;
    setApplied({ ...draft });
  };
  const clearFilters = () => {
    setDraft(EMPTY_FILTERS);
    setApplied(EMPTY_FILTERS);
    setSearch("");
  };
  const exportReport = () => downloadCsv(`packwise-${tab}-report.csv`, reportRows);
  const activeTab = tabs.find((item) => item.id === tab);

  return <div className="page-stack analytics-page">
    <PageHeader
      eyebrow="REPORTING & ANALYTICS"
      title="Operations intelligence"
      description="Inventory, production, consumption and supplier performance from authenticated, RLS-scoped PostgreSQL reports."
      actions={<>
        <Button variant="secondary" onClick={state.reload}><RefreshCw size={15}/> Refresh</Button>
        <Button variant="secondary" onClick={() => window.print()}><Printer size={15}/> Print / Save PDF</Button>
        <Button onClick={exportReport}><Download size={15}/> Export CSV</Button>
      </>}
    />
    {state.error ? <Alert kind="error">{state.error}</Alert> : null}
    <Card className="report-filter-card">
      <div className="report-section-heading"><div><h2>Report filters</h2><p>Filters are applied on the server for date-, shift-, material-, worker- and vendor-based reports.</p></div><Badge tone="blue">Live query</Badge></div>
      <form className="report-filter-grid" onSubmit={submitFilters}>
        <Field label="From date" type="date" value={draft.fromDate} onChange={(value) => setDraft({ ...draft, fromDate: value })} />
        <Field label="To date" type="date" value={draft.toDate} onChange={(value) => setDraft({ ...draft, toDate: value })} />
        <SelectField label="Shift" value={draft.shiftCode} onChange={(value) => setDraft({ ...draft, shiftCode: value })} placeholder="All shifts" options={[{ value: "SHIFT_1", label: "Shift 1" }, { value: "SHIFT_2", label: "Shift 2" }, { value: "GENERAL", label: "General" }]} />
        <SelectField label="Material" value={draft.materialId} onChange={(value) => setDraft({ ...draft, materialId: value })} placeholder="All materials" options={materials.map((r) => ({ value: String(r.id), label: `${r.material_code} · ${r.name}` }))} />
        <SelectField label="Worker" value={draft.workerId} onChange={(value) => setDraft({ ...draft, workerId: value })} placeholder="All workers" options={workers.map((r) => ({ value: String(r.id), label: `${r.worker_code} · ${r.name}` }))} />
        <SelectField label="Vendor" value={draft.vendorId} onChange={(value) => setDraft({ ...draft, vendorId: value })} placeholder="All vendors" options={vendors.map((r) => ({ value: String(r.id), label: `${r.vendor_code} · ${r.name}` }))} />
        <div className="report-filter-actions"><Button type="submit"><FileBarChart2 size={15}/> Apply filters</Button><Button variant="ghost" onClick={clearFilters}>Clear</Button></div>
      </form>
      {draft.fromDate && draft.toDate && draft.fromDate > draft.toDate ? <p className="report-validation-error">From date cannot be after the to date.</p> : null}
    </Card>

    <div className="metric-grid metric-grid-four report-metric-grid">
      <MetricCard label="Stock positions" value={stock.length} detail="Material × leaf-location rows" icon={<PackageSearch size={17}/>} tone="blue" />
      <MetricCard label="Worker custody lines" value={custody.length} detail="Outstanding material balances" icon={<Users size={17}/>} tone="green" />
      <MetricCard label="Consumption reviews" value={unresolved} detail="Unverified or non-zero variance" icon={<ShieldAlert size={17}/>} tone="amber" />
      <MetricCard label="Completed output" value={quantity(completedUnits)} detail={`${completionBatches} completion batches`} icon={<Factory size={17}/>} tone="purple" />
    </div>

    <div className="report-visual-grid">
      <Card className="report-visual-card">
        <div className="report-section-heading"><div><h2>Inventory distribution</h2><p>Count of material/location rows by inventory segment.</p></div><Activity size={17}/></div>
        <div className="report-bars">{segmentCounts.map((item) => <div className="report-bar-row" key={item.segment}>
          <div className="report-bar-label"><span>{item.segment.replaceAll("_", " ")}</span><strong>{item.count}</strong></div>
          <div className="report-bar-track"><span className={`report-bar-fill ${item.segment.toLowerCase()}`} style={{ width: `${item.count / maxSegmentCount * 100}%` }}/></div>
        </div>)}</div>
      </Card>
      <Card className="report-visual-card">
        <div className="report-section-heading"><div><h2>Shift completion trend</h2><p>Latest plans · completed output against authorized units.</p></div><Factory size={17}/></div>
        {production.length ? <div className="report-bars">{production.slice(0, 6).map((row) => {
          const target = Number(row.authorized_units ?? 0);
          const done = Number(row.completed_units ?? 0);
          const pct = target > 0 ? Math.min(100, Math.max(0, done / target * 100)) : 0;
          return <div className="report-bar-row" key={String(row.plan_id)}>
            <div className="report-bar-label"><span>{row.plan_number} · {row.shift_code}</span><strong>{pct.toFixed(0)}%</strong></div>
            <div className="report-bar-track"><span className="report-bar-fill production" style={{ width: `${pct}%` }}/></div>
            <small className="report-bar-meta">{quantity(row.completed_units)} completed of {quantity(row.authorized_units)} authorized</small>
          </div>;
        })}</div> : <p className="report-chart-empty">Production summaries appear here when released daily plans have jobs.</p>}
      </Card>
    </div>

    <Card padding={false} className="report-table-card">
      <div className="panel-tabs report-tabs">{tabs.map((item) => <button key={item.id} className={tab === item.id ? "selected" : ""} onClick={() => { setTab(item.id); setSearch(""); }}>
        {item.label}<span>{item.rows.length}</span>
      </button>)}</div>
      <div className="table-toolbar"><Toolbar><SearchBox value={search} onChange={setSearch} placeholder="Search displayed report rows…"/><span className="table-count">{reportRows.length} rows</span></Toolbar></div>
      <div className="report-table-caption"><strong>{activeTab?.label}</strong><span>{reportRows.length === sourceRows.length ? "All returned rows" : `${reportRows.length} of ${sourceRows.length} matching displayed rows`} · Maximum 1,000 rows per query</span></div>
      {state.loading ? <div className="loading-state"><RefreshCw size={18} className="spin"/> Loading report data…</div> : <DataTable rows={reportRows} columns={columns[tab]} rowKey={(row: Row) => tab === "stock" ? `${row.location_id}-${row.material_id}` : tab === "consumption" ? String(row.consumption_id) : tab === "production" ? String(row.plan_id) : tab === "worker-output" ? `${row.plan_id}-${row.worker_id}` : tab === "vendors" ? String(row.goods_receipt_id) : `${row.worker_id}-${row.material_id}` } emptyTitle="No report data" emptyDescription="No records matched this report. Try a wider date range or clear a filter." />}
    </Card>
    <div className="info-footnote report-footnote"><FileBarChart2 size={15}/><span>Missing physical consumption stays marked unverified; it is never inferred as zero. Inventory quantities stay attached to their canonical units and inventory segment.</span></div>
  </div>;
}
