import { useMemo, useState } from "react";
import { Activity, AlertTriangle, ArrowDownRight, ArrowUpRight, Boxes, ClipboardCheck, Factory, Package, RefreshCw, ShieldAlert } from "lucide-react";
import { apiGet } from "../lib/api";
import { formatQuantity } from "../lib/domain";
import { Badge, Button, Card, DataTable, MetricCard, PageHeader, SectionTitle, StatusBadge, Toolbar, Alert } from "../components/ui";
import { displayDate, Row, selectRows, useAsyncData } from "./shared";
import { Link } from "react-router-dom";

type Balance = Row & { availableQuantity: number; onHandQuantity: number; reservedQuantity: number; locationType: string };
type Plan = Row & { packing_jobs?: Row[] };

export function DashboardPage({ role, shift }: { role: string; shift: string }) {
  const [search, setSearch] = useState("");
  const load = async () => {
    const [balances, plans, custody] = await Promise.all([
      apiGet<Balance[]>("/stock/balances"),
      selectRows("daily_plans", "id,plan_number,plan_date,shift_code,status,packing_jobs(id,job_code,party_id,product_id,status,current_revised_quantity,completed_quantity,pending_quantity,assigned_worker_id)", "plan_date", 150),
      apiGet<Row[]>("/stock/worker-custody")
    ]);
    return { balances, plans, custody };
  };
  const state = useAsyncData(load, role);
  const { balances = [], plans = [], custody = [] } = state.data ?? {};
  const filteredPlans = plans.filter((p) => shift === "ALL" || p.shift_code === shift || shift === "GENERAL" && p.shift_code === "GENERAL");
  const jobs = filteredPlans.flatMap((plan) => (plan.packing_jobs ?? []).map((job: Row) => ({ ...job, plan })));
  const activeJobs = jobs.filter((job) => ["RELEASED","IN_PROGRESS","PARTIALLY_COMPLETED"].includes(String(job.status)));
  const visibleJobs = activeJobs.filter((job) => `${job.job_code} ${job.product_id} ${job.party_id}`.toLowerCase().includes(search.toLowerCase())).slice(0, 8);
  const planned = jobs.reduce((sum, job) => sum + Number(job.current_revised_quantity ?? 0), 0);
  const completed = jobs.reduce((sum, job) => sum + Number(job.completed_quantity ?? 0), 0);
  const critical = balances.filter((b) => b.locationType !== "DAMAGE_QUARANTINE" && Number(b.availableQuantity) <= 0 && Number(b.onHandQuantity) > 0).length;
  const quarantineQty = balances.filter((b) => b.locationType === "DAMAGE_QUARANTINE").reduce((sum,b)=>sum+Number(b.onHandQuantity ?? 0),0);
  const custodyQty = custody.reduce((sum,row)=>sum+Number(row.onHandQuantity ?? 0),0);
  const shiftText = shift === "ALL" ? "all shifts" : shift.replace("_"," ").toLowerCase();
  const progress = planned > 0 ? Math.min(100, Math.round(completed / planned * 100)) : 0;
  const columns = [
    { key:"job_code", label:"Job", render:(row:Row)=><div className="job-cell"><span className="job-dot"/><div><strong>{row.job_code}</strong><small>{row.plan?.plan_number ?? "Daily plan"}</small></div></div> },
    { key:"product_id", label:"Product / party", render:(row:Row)=><div><strong>{String(row.product_id ?? "").slice(0,8) || "—"}</strong><small>Party {String(row.party_id ?? "").slice(0,8) || "—"}</small></div> },
    { key:"current_revised_quantity", label:"Planned", render:(row:Row)=>formatQuantity(row.current_revised_quantity,0) },
    { key:"completed_quantity", label:"Packed", render:(row:Row)=><span className="success-text">{formatQuantity(row.completed_quantity,0)}</span> },
    { key:"pending_quantity", label:"Pending", render:(row:Row)=>formatQuantity(row.pending_quantity,0) },
    { key:"status", label:"Status", render:(row:Row)=><StatusBadge status={row.status}/> },
    { key:"open", label:"", render:(row:Row)=><Link className="table-link" to={`/daily-plans/jobs/${row.id}`}>Open →</Link> }
  ];
  return <div className="page-stack">
    <PageHeader eyebrow="OPERATIONS OVERVIEW" title="Good shift, let's keep it moving." description={`A live snapshot of materials and production for ${shiftText}.`} actions={<Button variant="secondary" onClick={state.reload}><RefreshCw size={15}/> Refresh data</Button>}/>
    {state.error ? <Alert kind="error">{state.error}</Alert> : null}
    <div className="hero-summary"><div className="hero-copy"><div className="hero-kicker"><span className="hero-pulse"/> SHIFT PERFORMANCE</div><h2>Production is a team sport.</h2><p>Track today's plan, see where the next bottleneck is, and keep every unit accounted for.</p><div className="hero-progress-head"><span>Planned output completion</span><strong>{progress}%</strong></div><div className="hero-progress"><span style={{width:`${progress}%`}}/></div><div className="hero-progress-foot"><span>{formatQuantity(completed,0)} packed</span><span>{formatQuantity(Math.max(0,planned-completed),0)} units remaining</span></div></div><div className="hero-visual"><div className="hero-ring"><div><Package size={25}/><strong>{progress}%</strong><small>shift goal</small></div></div><div className="floating-pill pill-one"><span className="pill-dot green-dot"/> Inventory tracked</div><div className="floating-pill pill-two"><ClipboardCheck size={13}/> Traceable output</div></div></div>
    <div className="metric-grid">
      <MetricCard label="Planned units" value={state.loading ? "…" : formatQuantity(planned,0)} detail={`Scheduled for ${shiftText}`} icon={<CalendarDaysFallback/>} tone="blue"/>
      <MetricCard label="Units completed" value={state.loading ? "…" : formatQuantity(completed,0)} detail={`${progress}% of current target`} icon={<Factory size={19}/>} tone="green"/>
      <MetricCard label="Active packing jobs" value={state.loading ? "…" : activeJobs.length} detail="Released or in progress" icon={<Activity size={19}/>} tone="purple"/>
      <MetricCard label="Stock alerts" value={state.loading ? "…" : critical} detail="Items with no available stock" icon={<AlertTriangle size={19}/>} tone="amber"/>
      <MetricCard label="Quarantined quantity" value={state.loading ? "…" : formatQuantity(quarantineQty)} detail="Physically tracked, not usable" icon={<ShieldAlert size={19}/>} tone="red"/>
      <MetricCard label="Worker custody" value={state.loading ? "…" : formatQuantity(custodyQty)} detail="Material currently with operators" icon={<Boxes size={19}/>} tone="blue"/>
    </div>
    <div className="dashboard-grid">
      <Card className="dashboard-jobs" padding={false}><div className="panel-heading padded"><div><div className="eyebrow">SHOP FLOOR</div><h2>Active packing jobs</h2><p>Open a job to revise output or record production.</p></div><Link className="text-link" to="/daily-plans/jobs">All jobs <span>→</span></Link></div><div className="table-toolbar"><Toolbar><span className="table-count">{activeJobs.length} active jobs</span><input className="toolbar-input" value={search} onChange={(e)=>setSearch(e.target.value)} placeholder="Search job or product…"/></Toolbar></div><DataTable rows={visibleJobs} columns={columns} rowKey={(row)=>String(row.id)} emptyTitle="No active jobs" emptyDescription="Release a daily plan to get jobs onto the shop floor."/></Card>
      <Card className="alerts-card"><SectionTitle title="Operations pulse" detail="Things worth a look this shift."/><div className="pulse-list"><div className="pulse-row"><div className="pulse-icon pulse-amber"><AlertTriangle size={17}/></div><div><strong>{critical ? `${critical} stock items need attention` : "No zero-availability stock alerts"}</strong><p>{critical ? "Check inventory before issuing more material." : "Available stock checks are looking clear."}</p></div></div><div className="pulse-row"><div className="pulse-icon pulse-red"><ShieldAlert size={17}/></div><div><strong>{formatQuantity(quarantineQty)} units in quarantine</strong><p>Quarantined material stays out of available-to-promise stock.</p></div></div><div className="pulse-row"><div className="pulse-icon pulse-blue"><ClipboardCheck size={17}/></div><div><strong>Physical consumption verification</strong><p>Unverified theoretical backflush must be checked before a clean close.</p></div></div></div><div className="pulse-actions"><Link to="/inventory/stock">Open inventory <span>→</span></Link><Link to="/closings">Run shift closing <span>→</span></Link></div><div className="data-note"><span className="online-dot"/> Live data · {displayDate(new Date())} <Badge tone="blue">{role.replaceAll("_"," ")}</Badge></div></Card>
    </div>
  </div>;
}

function CalendarDaysFallback() { return <Package size={19}/>; }