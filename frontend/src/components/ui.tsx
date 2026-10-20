import type { ReactNode, FormEvent } from "react";
import { X, Search, RefreshCw, ChevronDown, Plus, Download, ArrowRight, AlertCircle, CheckCircle2, Info } from "lucide-react";

export type TableColumn<T> = { key: string; label: string; render?: (row: T) => ReactNode; className?: string };

export function Button({
  children, onClick, type = "button", variant = "primary", disabled = false, loading = false, className = ""
}: {
  children: ReactNode; onClick?: () => void; type?: "button" | "submit" | "reset";
  variant?: "primary" | "secondary" | "ghost" | "danger" | "success"; disabled?: boolean; loading?: boolean; className?: string;
}) {
  return <button type={type} onClick={onClick} disabled={disabled || loading} className={`btn btn-${variant} ${className}`}>
    {loading ? <RefreshCw size={15} className="spin" /> : null}{children}
  </button>;
}

export function Card({ children, className = "", padding = true }: { children: ReactNode; className?: string; padding?: boolean }) {
  return <section className={`card ${padding ? "card-pad" : ""} ${className}`}>{children}</section>;
}

export function PageHeader({ eyebrow, title, description, actions }: { eyebrow?: string; title: string; description?: string; actions?: ReactNode }) {
  return <div className="page-heading">
    <div><div className="eyebrow">{eyebrow ?? "PACKWISE ERP"}</div><h1>{title}</h1>{description ? <p>{description}</p> : null}</div>
    {actions ? <div className="page-actions">{actions}</div> : null}
  </div>;
}

export function Field({ label, value, onChange, type = "text", placeholder, required, min, max, step, hint, disabled, autoComplete }: {
  label: string; value: string | number; onChange: (value: string) => void; type?: string; placeholder?: string;
  required?: boolean; min?: number | string; max?: number | string; step?: number | string; hint?: string; disabled?: boolean; autoComplete?: string;
}) {
  return <label className="field"><span>{label}{required ? <i> *</i> : null}</span>
    <input type={type} value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder}
      required={required} min={min} max={max} step={step} disabled={disabled} autoComplete={autoComplete} />
    {hint ? <small>{hint}</small> : null}
  </label>;
}

export function SelectField({ label, value, onChange, options, required, hint, disabled, placeholder = "Choose…", className = "" }: {
  label: string; value: string; onChange: (value: string) => void;
  options: Array<{ value: string; label: string }>; required?: boolean; hint?: string; disabled?: boolean; placeholder?: string; className?: string;
}) {
  return <label className={`field ${className}`}><span>{label}{required ? <i> *</i> : null}</span>
    <div className="select-wrap"><select value={value} onChange={(e) => onChange(e.target.value)} required={required} disabled={disabled}>
      <option value="">{placeholder}</option>{options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select><ChevronDown size={15} /></div>
    {hint ? <small>{hint}</small> : null}
  </label>;
}

export function TextArea({ label, value, onChange, rows = 3, placeholder, required, hint }: {
  label: string; value: string; onChange: (value: string) => void; rows?: number; placeholder?: string; required?: boolean; hint?: string;
}) {
  return <label className="field"><span>{label}{required ? <i> *</i> : null}</span>
    <textarea value={value} onChange={(e) => onChange(e.target.value)} rows={rows} placeholder={placeholder} required={required} />
    {hint ? <small>{hint}</small> : null}
  </label>;
}

export function SearchBox({ value, onChange, placeholder = "Search records…" }: { value: string; onChange: (value: string) => void; placeholder?: string }) {
  return <div className="search-box"><Search size={16} /><input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} aria-label={placeholder} />{value ? <button onClick={() => onChange("")} aria-label="Clear search"><X size={14}/></button> : null}</div>;
}

export function Badge({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "green" | "amber" | "red" | "blue" | "purple" }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function StatusBadge({ status }: { status?: string | null }) {
  const value = status || "UNKNOWN";
  const normalized = value.toUpperCase();
  const tone = ["ACTIVE", "POSTED", "RELEASED", "COMPLETED", "VERIFIED_ZERO", "HEALTHY"].includes(normalized) ? "green"
    : ["DRAFT", "UNVERIFIED", "IN_PROGRESS", "PARTIALLY_COMPLETED", "PENDING"].includes(normalized) ? "amber"
    : ["CANCELLED", "ARCHIVED", "VARIANCE_RECORDED", "FAILED"].includes(normalized) ? "red"
    : ["CLOSED", "SUPERSEDED"].includes(normalized) ? "blue" : "neutral";
  return <Badge tone={tone}>{value.replaceAll("_", " ")}</Badge>;
}

export function DataTable<T>({ columns, rows, rowKey, emptyTitle = "No records found", emptyDescription = "Try changing the filters or refresh the list.", onRowClick }: {
  columns: Array<TableColumn<T>>; rows: T[]; rowKey: (row: T, index: number) => string;
  emptyTitle?: string; emptyDescription?: string; onRowClick?: (row: T) => void;
}) {
  if (!rows.length) return <div className="empty-state"><div className="empty-icon"><Search size={22}/></div><strong>{emptyTitle}</strong><p>{emptyDescription}</p></div>;
  return <div className="table-wrap"><table><thead><tr>{columns.map((c) => <th key={c.key} className={c.className}>{c.label}</th>)}</tr></thead>
    <tbody>{rows.map((row, index) => <tr key={rowKey(row, index)} onClick={() => onRowClick?.(row)} className={onRowClick ? "clickable-row" : ""}>
      {columns.map((column) => <td key={column.key} className={column.className}>{column.render ? column.render(row) : String((row as Record<string, unknown>)[column.key] ?? "—")}</td>)}
    </tr>)}</tbody>
  </table></div>;
}

export function MetricCard({ label, value, detail, icon, tone = "blue" }: { label: string; value: string | number; detail?: string; icon: ReactNode; tone?: string }) {
  return <Card className="metric-card"><div className={`metric-icon metric-${tone}`}>{icon}</div><div className="metric-label">{label}</div><div className="metric-value">{value}</div>{detail ? <div className="metric-detail">{detail}</div> : null}</Card>;
}

export function Alert({ kind = "info", children, onClose }: { kind?: "info" | "success" | "warning" | "error"; children: ReactNode; onClose?: () => void }) {
  const Icon = kind === "success" ? CheckCircle2 : kind === "error" ? AlertCircle : Info;
  return <div className={`alert alert-${kind}`} role="status"><Icon size={18}/><div>{children}</div>{onClose ? <button onClick={onClose} aria-label="Dismiss message"><X size={15}/></button> : null}</div>;
}

export function Loading({ label = "Loading operational data…" }: { label?: string }) {
  return <div className="loading-state"><RefreshCw size={20} className="spin"/><span>{label}</span></div>;
}

export function Modal({ title, description, children, onClose, wide = false }: { title: string; description?: string; children: ReactNode; onClose: () => void; wide?: boolean }) {
  return <div className="modal-backdrop" role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
    <section className={`modal ${wide ? "modal-wide" : ""}`} role="dialog" aria-modal="true" aria-label={title}>
      <header className="modal-header"><div><h2>{title}</h2>{description ? <p>{description}</p> : null}</div><button className="icon-button" onClick={onClose} aria-label="Close modal"><X size={19}/></button></header>
      <div className="modal-content">{children}</div>
    </section>
  </div>;
}

export function SectionTitle({ title, detail, action }: { title: string; detail?: string; action?: ReactNode }) {
  return <div className="section-title"><div><h2>{title}</h2>{detail ? <p>{detail}</p> : null}</div>{action}</div>;
}

export function Toolbar({ children }: { children: ReactNode }) { return <div className="toolbar">{children}</div>; }

export function InlineNotice({ title, detail, icon = <ArrowRight size={17}/> }: { title: string; detail: string; icon?: ReactNode }) {
  return <div className="inline-notice"><span>{icon}</span><div><strong>{title}</strong><p>{detail}</p></div></div>;
}

export function ExportButton({ onClick, children = "Export CSV" }: { onClick: () => void; children?: ReactNode }) {
  return <Button variant="secondary" onClick={onClick}><Download size={15}/>{children}</Button>;
}

export function formSubmit(event: FormEvent<HTMLFormElement>, submit: () => void) {
  event.preventDefault();
  submit();
}

export function asString(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}