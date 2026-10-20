import { useEffect, useMemo, useState, type FormEvent } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { AlertTriangle, ArrowLeft, CheckCircle2, ClipboardCheck, Factory, LockKeyhole, RefreshCw, RotateCcw, Scale, ShieldAlert } from "lucide-react";
import { apiGet, apiPost } from "../lib/api";
import { formatQuantity, variancePreview } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, MetricCard, PageHeader, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, displayDate, selectRows, useAsyncData } from "./shared";

export function ProductionPage({role}:{role:string}) {
  const {id=""}=useParams();
  const navigate=useNavigate();
  const [units,setUnits]=useState("1");
  const [workerId,setWorkerId]=useState("");
  const [policy,setPolicy]=useState<"AUTO_BOM_THEORETICAL"|"CONFIRMED_ACTUAL_ENTRY">("AUTO_BOM_THEORETICAL");
  const [actuals,setActuals]=useState<Record<string,string>>({});
  const [methods,setMethods]=useState<Record<string,string>>({});
  const [evidence,setEvidence]=useState<Record<string,string>>({});
  const [remarks,setRemarks]=useState("");
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const [result,setResult]=useState<Row|null>(null);
  const state=useAsyncData(async()=>{
    const [job,workers]=await Promise.all([
      apiGet<Row>(`/packing-jobs/${id}`),
      selectRows("workers","id,worker_code,name,is_active","name",500)
    ]);
    return {job,workers};
  },id);
  const job=state.data?.job;
  const workers=(state.data?.workers??[]).filter((w:Row)=>w.is_active);
  const lines=(job?.snapshot?.lines??[]).filter((l:Row)=>!l.isOptional);
  useEffect(()=>{if(job?.assignedWorkerId&&!workerId)setWorkerId(job.assignedWorkerId);},[job?.assignedWorkerId,workerId]);
  const completedUnits=Math.floor(Number(units)||0);
  const canComplete=["ADMIN","OPERATOR","PLANNER"].includes(role);
  const submit=async(e:FormEvent)=>{
    e.preventDefault();setBusy(true);setMessage(null);setResult(null);
    try{
      if(!job)throw new Error("Load a valid packing job first.");
      if(!Number.isInteger(Number(units))||completedUnits<1)throw new Error("Completed units must be a positive whole number.");
      if(completedUnits>Number(job.quantityStatus.pendingQuantity))throw new Error("Completed units cannot exceed this job’s pending quantity.");
      if(!workerId)throw new Error("Select the operator who packed this batch.");
      const actualMaterialUsage=policy==="CONFIRMED_ACTUAL_ENTRY"?lines.map((line:Row)=>{
        const raw=actuals[line.materialId];
        if(raw===undefined||raw.trim()===""||!Number.isFinite(Number(raw))||Number(raw)<0)throw new Error(`Enter a non-negative physical count for material ${String(line.materialId).slice(0,8)}.`);
        return {materialId:line.materialId,physicallyConfirmedQuantity:Number(raw),unitId:line.canonicalUnitId,measurementMethod:methods[line.materialId]??"MANUALLY_COUNTED",measurementEvidence:evidence[line.materialId]||null};
      }):[];
      const response=await apiPost<Row>("/production/completions",{packingJobId:job.id,completedUnits,workerId,completionPolicy:policy,actualMaterialUsage,remarks:remarks||null});
      setResult(response);setMessage({kind:"success",text:`Completion ${response.completionNumber??response.id} recorded. The stock ledger and job quantities were updated atomically.`});
      setUnits("1");setRemarks("");state.reload();
    }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Production could not be recorded."});}finally{setBusy(false);}
  };
  if(state.loading)return <div className="page-stack"><PageHeader eyebrow="PRODUCTION ENTRY" title="Record packed units" description="Load the job and verify batch details."/><Card><div className="padded">Loading frozen job snapshot…</div></Card></div>;
  return <div className="page-stack"><PageHeader eyebrow="PRODUCTION ENTRY" title="Record packed units" description="Finish-goods output is recorded together with the theoretical ledger deduction and optional physical consumption measurement." actions={<Button variant="secondary" onClick={()=>navigate(id?`/daily-plans/jobs/${id}`:"/daily-plans/jobs")}><ArrowLeft size={15}/> Back to job</Button>}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}{state.error?<Alert kind="error">{state.error}</Alert>:null}
    {job?<><Card><div className="job-detail-head"><div><div className="eyebrow">JOB {job.jobCode}</div><h2>Production batch</h2><p>Target {formatQuantity(job.quantityStatus.currentRevisedQuantity,0)} · {formatQuantity(job.quantityStatus.pendingQuantity,0)} pending · Worker must be active.</p></div><StatusBadge status={job.status}/></div><div className="quantity-stat-grid four-stats"><div><span>Authorized target</span><strong>{formatQuantity(job.quantityStatus.currentRevisedQuantity,0)}</strong></div><div><span>Already packed</span><strong className="success-text">{formatQuantity(job.quantityStatus.completedQuantity,0)}</strong></div><div><span>Remaining</span><strong className="blue-text">{formatQuantity(job.quantityStatus.pendingQuantity,0)}</strong></div><div><span>Frozen BOM lines</span><strong>{job.snapshot?.lines?.length??0}</strong></div></div></Card>
    <form className="page-stack" onSubmit={submit}><div className="two-column-layout"><Card><div className="panel-heading"><div><h2>Batch details</h2><p>Record actual packed output and the operator responsible.</p></div><div className="form-symbol green-symbol"><Factory size={18}/></div></div><div className="stack-form"><Field label="Completed units" value={units} onChange={setUnits} type="number" min={1} max={job.quantityStatus.pendingQuantity} step={1} required hint={`Cannot exceed ${job.quantityStatus.pendingQuantity} pending units.`}/><SelectField label="Packing operator" value={workerId} onChange={setWorkerId} options={workers.map((w:Row)=>({value:w.id,label:`${w.worker_code} · ${w.name}`}))} required/><TextArea label="Batch remarks" value={remarks} onChange={setRemarks} rows={3} placeholder="Optional output notes"/></div><div className="consumption-policy"><div className="eyebrow">CONSUMPTION POLICY</div><div className="policy-switch"><button type="button" className={policy==="AUTO_BOM_THEORETICAL"?"selected":""} onClick={()=>setPolicy("AUTO_BOM_THEORETICAL")}><Factory size={16}/><span><strong>Auto-BOM backflush</strong><small>Post frozen theoretical usage as estimated; keep physical count unverified.</small></span></button><button type="button" className={policy==="CONFIRMED_ACTUAL_ENTRY"?"selected":""} onClick={()=>setPolicy("CONFIRMED_ACTUAL_ENTRY")}><Scale size={16}/><span><strong>Confirmed physical count</strong><small>Enter an actual count for every required material in its canonical unit.</small></span></button></div></div><Button type="submit" loading={busy} disabled={!canComplete}><CheckCircle2 size={16}/> Record production completion</Button>{!canComplete?<p className="field-error">Your role cannot record production output.</p>:null}</Card>
      <Card><div className="panel-heading"><div><h2>Material consumption</h2><p>Theoretical values are derived from the frozen snapshot and batch size.</p></div><Badge tone={policy==="AUTO_BOM_THEORETICAL"?"amber":"green"}>{policy==="AUTO_BOM_THEORETICAL"?"Estimated backflush":"Physical verification"}</Badge></div><div className="consumption-list">{lines.map((line:Row)=>{
        const theoretical=Number(line.canonicalQuantityPerUnit)*completedUnits;
        const preview=variancePreview(actuals[line.materialId]??"",theoretical);
        return <div className="consumption-line" key={line.materialId}><div className="consumption-line-head"><div><strong>{String(line.materialId).slice(0,8)}</strong><small>{formatQuantity(line.canonicalQuantityPerUnit)} per unit · canonical {String(line.canonicalUnitId).slice(0,8)}</small></div><div className="theory-number"><span>Theoretical</span><strong>{formatQuantity(theoretical)}</strong></div></div>
          {policy==="CONFIRMED_ACTUAL_ENTRY"?<div className="form-grid"><Field label="Physically confirmed quantity" value={actuals[line.materialId]??""} onChange={v=>setActuals(old=>({...old,[line.materialId]:v}))} type="number" min={0} step="any" required/><SelectField label="Measurement method" value={methods[line.materialId]??"MANUALLY_COUNTED"} onChange={v=>setMethods(old=>({...old,[line.materialId]:v}))} options={[{value:"SCALE_WEIGHED",label:"Scale weighed"},{value:"SEALED_BUNDLE",label:"Sealed bundle"},{value:"MANUALLY_COUNTED",label:"Manually counted"}]} required/><div className="span-2"><Field label="Evidence / scale-slip reference" value={evidence[line.materialId]??""} onChange={v=>setEvidence(old=>({...old,[line.materialId]:v}))} placeholder="Optional evidence (max 500 characters)"/></div><div className="variance-preview"><span>Live variance</span><strong className={preview.status==="VERIFIED_ZERO"?"success-text":"warning-text"}>{preview.variance===null?"—":formatQuantity(preview.variance)}</strong><StatusBadge status={preview.status}/></div></div>:<div className="theory-note"><AlertTriangle size={14}/><span>Posted ledger quantity: {formatQuantity(theoretical)} · variance remains <b>UNVERIFIED</b> until a physical count is recorded.</span></div>}
        </div>;
      })}{!lines.length?<Alert kind="warning">The frozen snapshot has no required material lines. Verify this job before recording production.</Alert>:null}</div></Card></div></form>
    {result?<Card><div className="panel-heading"><div><div className="eyebrow">SERVER RESPONSE</div><h2>Completion recorded</h2><p>{result.completionNumber??result.id}</p></div><Badge tone="green">Saved</Badge></div><DataTable rows={result.consumptions??[]} rowKey={(r:Row)=>String(r.id??r.materialId)} columns={[
      {key:"materialId",label:"Material",render:(r:Row)=>String(r.materialId).slice(0,8)},
      {key:"theoreticalQuantity",label:"Theoretical",render:(r:Row)=>formatQuantity(r.theoreticalQuantity)},
      {key:"postedLedgerQuantity",label:"Ledger",render:(r:Row)=>formatQuantity(r.postedLedgerQuantity)},
      {key:"physicallyConfirmedQuantity",label:"Physical",render:(r:Row)=>r.physicallyConfirmedQuantity==null?<Badge tone="amber">Unverified</Badge>:formatQuantity(r.physicallyConfirmedQuantity)},
      {key:"varianceQuantity",label:"Variance",render:(r:Row)=>r.varianceQuantity==null?"—":formatQuantity(r.varianceQuantity)},
      {key:"varianceStatus",label:"Status",render:(r:Row)=><StatusBadge status={r.varianceStatus}/>}
    ]}/><div className="form-footer"><Button variant="secondary" onClick={()=>navigate(`/daily-plans/jobs/${id}`)}>Back to job</Button><Button onClick={()=>navigate("/closings")}>Go to shift closing →</Button></div></Card>:null}
    </>:<Alert kind="error">Job detail could not be found.</Alert>}
  </div>;
}

type Disposition={disposition:"CARRY_FORWARD"|"RESCHEDULE"|"CANCEL";reason:string;date:string;shift:string};
export function ClosingPage({role}:{role:string}) {
  const [selectedPlanId,setSelectedPlanId]=useState("");
  const [detail,setDetail]=useState<Row|null>(null);
  const [dispositions,setDispositions]=useState<Record<string,Disposition>>({});
  const [override,setOverride]=useState(false);
  const [overrideReason,setOverrideReason]=useState("");
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const [selectedClosing,setSelectedClosing]=useState<Row|null>(null);
  const plansState=useAsyncData(()=>selectRows("daily_plans","id,plan_number,plan_date,shift_code,status,notes,packing_jobs(id,job_code,status,pending_quantity,current_revised_quantity,completed_quantity,cancelled_quantity)","plan_date",500));
  const closingsState=useAsyncData(()=>selectRows("daily_closings","id,daily_plan_id,shift_code,closing_date,total_planned_units,total_completed_units,total_pending_units,total_cancelled_units,unresolved_discrepancies_count,override_reason,closed_at,is_reopened,reopen_reason,pending_dispositions,discrepancy_details","closed_at",300));
  const plans=plansState.data??[];
  const closings=closingsState.data??[];
  const canClose=["ADMIN","STOREKEEPER"].includes(role);
  const canOverride=role==="ADMIN";
  const chosenPlan=plans.find(p=>p.id===selectedPlanId);
  const pendingJobs=(detail?.jobs??[]).filter((j:Row)=>Number(j.quantityStatus?.pendingQuantity??j.pending_quantity??0)>0);
  const loadPlan=async(planId:string)=>{setSelectedPlanId(planId);setDetail(null);setMessage(null);if(!planId)return;try{const response=await apiGet<Row>(`/daily-plans/${planId}`);setDetail(response);const initial:Record<string,Disposition>={};for(const j of response.jobs??[]){if(Number(j.quantityStatus?.pendingQuantity??0)>0)initial[j.id]={disposition:"CARRY_FORWARD",reason:"",date:new Date(Date.now()+86400000).toISOString().slice(0,10),shift:response.shiftCode??"SHIFT_1"};}setDispositions(initial);}catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not load daily plan."});}};
  const closePlan=async(e:FormEvent)=>{e.preventDefault();if(!detail)return;setBusy(true);setMessage(null);try{
    const pendingDispositions=pendingJobs.map((j:Row)=>{
      const d=dispositions[j.id]??{disposition:"CARRY_FORWARD" as const,reason:"",date:"",shift:detail.shiftCode};
      if(["CANCEL","RESCHEDULE"].includes(d.disposition)&&d.reason.trim().length<3)throw new Error(`Job ${j.jobCode} requires a reason for ${d.disposition.toLowerCase()}.`);
      if(d.disposition==="RESCHEDULE"&&(!d.date||!d.shift||d.date<=detail.planDate))throw new Error("Reschedule target date must be later than the source plan date.");
      return {packingJobId:j.id,disposition:d.disposition,reason:d.reason||undefined,...(d.disposition==="RESCHEDULE"?{targetPlanDate:d.date,targetShiftCode:d.shift}: {})};
    });
    const result=await apiPost<Row>("/closings",{dailyPlanId:detail.id,shiftCode:detail.shiftCode,allowDiscrepancyOverride:override,supervisorOverrideReason:override?overrideReason.trim():null,pendingDispositions});
    setMessage({kind:"success",text:`Shift closing saved. ${result.unresolvedDiscrepanciesCount??0} discrepancy item(s) are recorded.`});plansState.reload();closingsState.reload();setSelectedClosing(result);
  }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Daily closing could not be completed."});}finally{setBusy(false);}};
  const reopen=async(closing:Row)=>{const reason=window.prompt("Reason to reopen this closing (minimum 3 characters):");if(!reason||reason.trim().length<3)return;setBusy(true);setMessage(null);try{const result=await apiPost<Row>(`/closings/${closing.id}/reopen`,{reopenReason:reason.trim()});setMessage({kind:"success",text:"Closing reopened. The reason was written to the audit log."});setSelectedClosing(result);plansState.reload();closingsState.reload();}catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not reopen closing."});}finally{setBusy(false);}};
  const planColumns=[
    {key:"plan_number",label:"Daily plan",render:(r:Row)=><div><strong>{r.plan_number}</strong><small>{displayDate(r.plan_date)}</small></div>},
    {key:"shift_code",label:"Shift",render:(r:Row)=><Badge tone="blue">{r.shift_code}</Badge>},
    {key:"packing_jobs",label:"Jobs",render:(r:Row)=>(r.packing_jobs??[]).length},
    {key:"target",label:"Target",render:(r:Row)=>formatQuantity((r.packing_jobs??[]).reduce((s:number,j:Row)=>s+Number(j.current_revised_quantity??0),0),0)},
    {key:"done",label:"Packed",render:(r:Row)=>formatQuantity((r.packing_jobs??[]).reduce((s:number,j:Row)=>s+Number(j.completed_quantity??0),0),0)},
    {key:"pending",label:"Pending",render:(r:Row)=><strong className="warning-text">{formatQuantity((r.packing_jobs??[]).reduce((s:number,j:Row)=>s+Number(j.pending_quantity??0),0),0)}</strong>},
    {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>},
    {key:"action",label:"",render:(r:Row)=><Button variant="secondary" onClick={()=>void loadPlan(r.id)} disabled={r.status!=="RELEASED"}>Reconcile →</Button>}
  ];
  const closingColumns=[
    {key:"closing_date",label:"Closed date",render:(r:Row)=>displayDate(r.closing_date)},
    {key:"daily_plan_id",label:"Daily plan",render:(r:Row)=>String(r.daily_plan_id).slice(0,8)},
    {key:"shift_code",label:"Shift",render:(r:Row)=><Badge tone="blue">{r.shift_code}</Badge>},
    {key:"total_planned_units",label:"Planned",render:(r:Row)=>formatQuantity(r.total_planned_units,0)},
    {key:"total_completed_units",label:"Packed",render:(r:Row)=><span className="success-text">{formatQuantity(r.total_completed_units,0)}</span>},
    {key:"total_pending_units",label:"Pending",render:(r:Row)=>formatQuantity(r.total_pending_units,0)},
    {key:"unresolved_discrepancies_count",label:"Discrepancies",render:(r:Row)=><Badge tone={Number(r.unresolved_discrepancies_count)>0?"amber":"green"}>{r.unresolved_discrepancies_count}</Badge>},
    {key:"is_reopened",label:"State",render:(r:Row)=><StatusBadge status={r.is_reopened?"REOPENED":"CLOSED"}/>},
    {key:"actions",label:"",render:(r:Row)=><div className="row-actions"><Button variant="ghost" onClick={()=>setSelectedClosing(r)}>Detail</Button>{canOverride&&!r.is_reopened?<Button variant="secondary" onClick={()=>void reopen(r)} loading={busy}><RotateCcw size={14}/> Reopen</Button>:null}</div>}
  ];
  return <div className="page-stack"><PageHeader eyebrow="SHIFT RECONCILIATION" title="Closing & material verification" description="A clean close requires every discrepancy to be resolved or an explicit authorized override recorded." actions={<Button variant="secondary" onClick={()=>{plansState.reload();closingsState.reload();}}><RefreshCw size={15}/> Refresh</Button>}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}
    <div className="metric-grid metric-grid-four"><MetricCard label="Released plans" value={plans.filter(p=>p.status==="RELEASED").length} detail="Eligible for closing" icon={<ClipboardCheck size={18}/>} tone="blue"/><MetricCard label="Closed shifts" value={closings.filter(c=>!c.is_reopened).length} detail="Finalized daily plans" icon={<LockKeyhole size={18}/>} tone="green"/><MetricCard label="Recorded discrepancies" value={closings.reduce((s,c)=>s+Number(c.unresolved_discrepancies_count??0),0)} detail="Historical unresolved items" icon={<AlertTriangle size={18}/>} tone="amber"/><MetricCard label="Reopened closings" value={closings.filter(c=>c.is_reopened).length} detail="Require a follow-up close" icon={<RotateCcw size={18}/>} tone="purple"/></div>
    {plansState.error||closingsState.error?<Alert kind="error">{plansState.error||closingsState.error}</Alert>:null}
    <Card padding={false}><div className="panel-heading padded"><div><h2>Released plans</h2><p>Select a plan to reconcile open job quantities and consumption.</p></div><Badge tone="blue">{plans.filter(p=>p.status==="RELEASED").length} ready</Badge></div><DataTable rows={plans.filter(p=>p.status==="RELEASED")} columns={planColumns} rowKey={r=>String(r.id)} emptyTitle="No plans ready to close" emptyDescription="Released plans will appear when a shift has been scheduled and started."/></Card>
    {detail?<Card><div className="panel-heading"><div><div className="eyebrow">CLOSING WORKSHEET</div><h2>{detail.planNumber}</h2><p>{displayDate(detail.planDate)} · {detail.shiftCode}</p></div><Button variant="ghost" onClick={()=>{setDetail(null);setSelectedPlanId("");}}>Close worksheet</Button></div>
      <form className="page-stack compact-stack" onSubmit={closePlan}><div className="closing-summary"><div><span>Planned units</span><strong>{formatQuantity(pendingJobs.reduce((s:number,j:Row)=>s+Number(j.quantityStatus?.currentRevisedQuantity??0),0),0)}</strong></div><div><span>Pending jobs</span><strong>{pendingJobs.length}</strong></div><div><span>Completed output</span><strong>{formatQuantity((detail.jobs??[]).reduce((s:number,j:Row)=>s+Number(j.quantityStatus?.completedQuantity??0),0),0)}</strong></div></div>
        <div className="panel-heading"><div><h3>Pending-unit disposition</h3><p>Carry-forward defaults to the next calendar day on the same shift. Reschedule creates a new job from the frozen recipe.</p></div></div>
        {pendingJobs.map((job:Row)=><div className="disposition-row" key={job.id}><div className="disposition-job"><strong>{job.jobCode}</strong><small>{formatQuantity(job.quantityStatus.pendingQuantity,0)} pending units</small></div><SelectField label="Disposition" value={(dispositions[job.id]?.disposition??"CARRY_FORWARD")} onChange={v=>setDispositions(old=>({...old,[job.id]:{...(old[job.id]??{reason:"",date:new Date(Date.now()+86400000).toISOString().slice(0,10),shift:detail.shiftCode}),disposition:v as Disposition["disposition"]}}))} options={[{value:"CARRY_FORWARD",label:"Carry forward"},{value:"RESCHEDULE",label:"Reschedule"},{value:"CANCEL",label:"Cancel remainder"}]}/>
          {dispositions[job.id]?.disposition==="RESCHEDULE"?<><Field label="Target date" value={dispositions[job.id]?.date??""} onChange={v=>setDispositions(old=>({...old,[job.id]:{...old[job.id],date:v}}))} type="date" min={detail.planDate} required/><SelectField label="Target shift" value={dispositions[job.id]?.shift??detail.shiftCode} onChange={v=>setDispositions(old=>({...old,[job.id]:{...old[job.id],shift:v}}))} options={[{value:"GENERAL",label:"General"},{value:"SHIFT_1",label:"Shift 1"},{value:"SHIFT_2",label:"Shift 2"}]} required/></>:null}
          {["CANCEL","RESCHEDULE"].includes(dispositions[job.id]?.disposition??"")?<div className="disposition-reason"><Field label="Reason" value={dispositions[job.id]?.reason??""} onChange={v=>setDispositions(old=>({...old,[job.id]:{...old[job.id],reason:v}}))} required placeholder="Explain the operational reason"/></div>:null}
        </div>)}
        {!pendingJobs.length?<Alert kind="success">There are no pending units. Review the discrepancy checklist below before closing.</Alert>:null}
        <Card className="closing-checklist"><div className="panel-heading"><div><h3>Material verification checklist</h3><p>The server checks unverified consumption, recorded variances, outstanding job-linked worker custody and quarantined material.</p></div><ShieldAlert size={19}/></div><div className="checklist-line"><span><AlertTriangle size={15}/></span><div><strong>Unverified physical consumption</strong><p>Estimated backflush stays unverified until an actual count is recorded.</p></div><Badge tone="amber">Server checked</Badge></div><div className="checklist-line"><span><ClipboardCheck size={15}/></span><div><strong>Worker custody and quarantined stock</strong><p>Outstanding balances are included in the server discrepancy result.</p></div><Badge tone="blue">Server checked</Badge></div></Card>
        {canOverride?<div className="override-panel"><label className="checkbox-field"><input type="checkbox" checked={override} onChange={e=>setOverride(e.target.checked)}/><span>Admin override: close with unresolved discrepancies</span></label>{override?<TextArea label="Supervisor override reason" value={overrideReason} onChange={setOverrideReason} rows={2} required placeholder="Document review, approval and follow-up plan"/>:null}</div>:null}
        <div className="form-footer"><Button variant="secondary" onClick={()=>setDetail(null)}>Cancel</Button><Button type="submit" loading={busy} disabled={!canClose}>Validate & close shift</Button></div>
      </form>
    </Card>:null}
    <Card padding={false}><div className="panel-heading padded"><div><h2>Closing history</h2><p>Audit-friendly daily summaries, variance details and admin reopen actions.</p></div><Badge>{closings.length} records</Badge></div><DataTable rows={closings} columns={closingColumns} rowKey={r=>String(r.id)} emptyTitle="No closing history" emptyDescription="Completed shift reconciliations will appear here."/></Card>
    {selectedClosing?<Card><div className="panel-heading"><div><div className="eyebrow">CLOSING DETAIL</div><h2>{selectedClosing.shift_code??selectedClosing.shiftCode} · {displayDate(selectedClosing.closing_date??selectedClosing.closingDate)}</h2><p>Plan {String(selectedClosing.daily_plan_id??selectedClosing.dailyPlanId).slice(0,8)} · {(selectedClosing.closed_at??selectedClosing.closedAt)?displayDate(selectedClosing.closed_at??selectedClosing.closedAt):"—"}</p></div><Button variant="ghost" onClick={()=>setSelectedClosing(null)}>Close detail</Button></div><div className="closing-summary"><div><span>Planned</span><strong>{formatQuantity(selectedClosing.total_planned_units,0)}</strong></div><div><span>Packed</span><strong>{formatQuantity(selectedClosing.total_completed_units,0)}</strong></div><div><span>Pending</span><strong>{formatQuantity(selectedClosing.total_pending_units,0)}</strong></div><div><span>Cancelled</span><strong>{formatQuantity(selectedClosing.total_cancelled_units,0)}</strong></div></div><div className="panel-heading"><div><h3>Discrepancy details</h3><p>Items saved when the close was recorded.</p></div><Badge tone={Number(selectedClosing.unresolved_discrepancies_count)>0?"amber":"green"}>{selectedClosing.unresolved_discrepancies_count} items</Badge></div><DataTable rows={selectedClosing.discrepancy_details??selectedClosing.discrepancyDetails??[]} rowKey={(r:Row,i:number)=>String(r.id??`${r.type}-${i}`)} columns={[
      {key:"type",label:"Type",render:(r:Row)=><StatusBadge status={r.type}/>},
      {key:"materialId",label:"Material",render:(r:Row)=>String(r.materialId??"—").slice(0,8)},
      {key:"packingJobId",label:"Job",render:(r:Row)=>String(r.packingJobId??"—").slice(0,8)},
      {key:"theoreticalQuantity",label:"Theoretical",render:(r:Row)=>r.theoreticalQuantity==null?"—":formatQuantity(r.theoreticalQuantity)},
      {key:"physicallyConfirmedQuantity",label:"Physical",render:(r:Row)=>r.physicallyConfirmedQuantity==null?"Unverified":formatQuantity(r.physicallyConfirmedQuantity)},
      {key:"outstandingQuantity",label:"Outstanding",render:(r:Row)=>r.outstandingQuantity==null?"—":formatQuantity(r.outstandingQuantity)}
    ]}/><TextArea label="Override / reopen reason" value={selectedClosing.reopen_reason??selectedClosing.reopenReason??selectedClosing.override_reason??selectedClosing.supervisorOverrideReason??""} onChange={()=>{}} rows={2} hint="Read-only audit context saved for this closing."/></Card>:null}
  </div>;
}