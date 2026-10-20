import { useMemo, useState, type FormEvent } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { CalendarDays, ClipboardList, Plus, RefreshCw, Rocket, SlidersHorizontal } from "lucide-react";
import { apiGet, apiPost } from "../lib/api";
import { quantityBalanced, quantityEquation, formatQuantity } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, Modal, PageHeader, SearchBox, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, displayDate, selectRows, useAsyncData } from "./shared";

type PlanLine={materialId:string;quantityPerUnit:string;unitId:string};
type JobDraft={mode:"standard"|"custom";partyId:string;productId:string;bomId:string;quantity:string;customLines:PlanLine[];notes:string};
const line=():PlanLine=>({materialId:"",quantityPerUnit:"1",unitId:""});
const job=():JobDraft=>({mode:"standard",partyId:"",productId:"",bomId:"",quantity:"100",customLines:[line()],notes:""});
export function PlanningPage({role,shift}:{role:string;shift:string}) {
  const navigate=useNavigate();
  const [search,setSearch]=useState("");
  const [createOpen,setCreateOpen]=useState(false);
  const [planDate,setPlanDate]=useState(new Date().toISOString().slice(0,10));
  const [shiftCode,setShiftCode]=useState(shift==="ALL"?"SHIFT_1":shift);
  const [notes,setNotes]=useState("");
  const [draftJobs,setDraftJobs]=useState<JobDraft[]>([job()]);
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const [selectedPlan,setSelectedPlan]=useState<Row|null>(null);
  const [planDetail,setPlanDetail]=useState<Row|null>(null);
  const [detailLoading,setDetailLoading]=useState(false);
  const canWrite=["ADMIN","PLANNER"].includes(role);
  const state=useAsyncData(async()=>{
    const [plans,parties,products,boms,materials,units]=await Promise.all([
      selectRows("daily_plans","id,plan_number,plan_date,shift_code,status,notes,released_at,created_at,packing_jobs(id,job_code,party_id,product_id,master_bom_id,status,original_planned_quantity,current_revised_quantity,completed_quantity,pending_quantity,cancelled_quantity,assigned_worker_id)","plan_date",300),
      selectRows("parties","id,code,name,is_active","name",500),
      selectRows("products","id,sku_code,name,default_party_id,is_active","name",500),
      selectRows("boms","id,bom_code,product_id,party_id,packing_variant_name,version_number,status","created_at",500),
      selectRows("materials","id,material_code,name,canonical_unit_id,is_active","name",500),
      selectRows("units","id,code,name,dimension","code",250)
    ]);
    return {plans,parties,products,boms,materials,units};
  },role);
  const {plans=[],parties=[],products=[],boms=[],materials=[],units=[]}=state.data??{};
  const activeBoms=boms.filter(b=>b.status==="ACTIVE");
  const visiblePlans=useMemo(()=>plans.filter(p=>(shift==="ALL"||p.shift_code===shift)&&`${p.plan_number} ${p.shift_code} ${p.status} ${p.plan_date}`.toLowerCase().includes(search.toLowerCase())),[plans,shift,search]);
  const activeJobs=selectedPlan?.packing_jobs??[];
  const openPlan=async(plan:Row)=>{setSelectedPlan(plan);setPlanDetail(null);setDetailLoading(true);try{setPlanDetail(await apiGet<Row>(`/daily-plans/${plan.id}`));}catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not open the plan."});}finally{setDetailLoading(false);}};
  const release=async(plan:Row)=>{setBusy(true);setMessage(null);try{await apiPost(`/daily-plans/${plan.id}/release`,{});setMessage({kind:"success",text:`${plan.plan_number} released. BOM snapshots and stock reservations were created transactionally.`});state.reload();if(selectedPlan?.id===plan.id)await openPlan(plan);}catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not release the plan."});}finally{setBusy(false);}};
  const createPlan=async(e:FormEvent)=>{e.preventDefault();setBusy(true);setMessage(null);try{
    const ready=draftJobs.filter(j=>j.partyId&&j.productId&&Number(j.quantity)>0);
    if(ready.length===0)throw new Error("Add at least one job with a party, product and positive quantity.");
    for(const j of ready){if(j.mode==="standard"&&!j.bomId)throw new Error("Select an active BOM for each standard job.");if(j.mode==="custom"){if(!j.customLines.length||j.customLines.some((x)=>!x.materialId||!x.unitId||!Number.isFinite(Number(x.quantityPerUnit))||Number(x.quantityPerUnit)<=0))throw new Error("Each custom job needs one or more complete material lines with positive quantities.");const ids=j.customLines.map((x)=>x.materialId);if(new Set(ids).size!==ids.length)throw new Error("A material may appear only once in a custom job recipe.");}}
    const masterDerivedJobs=ready.filter(j=>j.mode==="standard").map(j=>({partyId:j.partyId,productId:j.productId,masterBomId:j.bomId,plannedQuantity:Number(j.quantity)}));
    const customJobs=ready.filter(j=>j.mode==="custom").map(j=>({partyId:j.partyId,productId:j.productId,plannedQuantity:Number(j.quantity),customizationNotes:j.notes||"Custom job recipe created from daily planner",customBomLines:j.customLines.map((customLine)=>({materialId:customLine.materialId,quantityPerUnit:Number(customLine.quantityPerUnit),unitId:customLine.unitId,isOptional:false,applicationNotes:null}))}));
    const result=await apiPost<Row>("/daily-plans",{planDate,shiftCode,notes:notes||null,masterDerivedJobs,customJobs});
    setMessage({kind:"success",text:`Daily plan ${result.planNumber??result.id} created in draft status.`});setCreateOpen(false);setDraftJobs([job()]);setNotes("");state.reload();
  }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"The daily plan could not be created."});}finally{setBusy(false);}};
  const columns=[
    {key:"plan_number",label:"Plan",render:(r:Row)=><div><strong>{r.plan_number}</strong><small>{displayDate(r.plan_date)}</small></div>},
    {key:"shift_code",label:"Shift",render:(r:Row)=><Badge tone="blue">{r.shift_code.replaceAll("_"," ")}</Badge>},
    {key:"packing_jobs",label:"Jobs",render:(r:Row)=><strong>{(r.packing_jobs??[]).length}</strong>},
    {key:"current_revised_quantity",label:"Target output",render:(r:Row)=>formatQuantity((r.packing_jobs??[]).reduce((sum:number,j:Row)=>sum+Number(j.current_revised_quantity??0),0),0)},
    {key:"completed_quantity",label:"Packed",render:(r:Row)=><span className="success-text">{formatQuantity((r.packing_jobs??[]).reduce((sum:number,j:Row)=>sum+Number(j.completed_quantity??0),0),0)}</span>},
    {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>},
    {key:"actions",label:"Actions",render:(r:Row)=><div className="row-actions"><Button variant="ghost" onClick={()=>void openPlan(r)}>View</Button>{canWrite&&r.status==="DRAFT"?<Button variant="secondary" onClick={()=>void release(r)} loading={busy}><Rocket size={14}/> Release</Button>:null}</div>}
  ];
  return <div className="page-stack"><PageHeader eyebrow="DAILY SCHEDULING" title="Daily packing plans" description="Create shift-aware job batches from active BOM versions, then reserve material and release the schedule." actions={canWrite?<Button onClick={()=>{setCreateOpen(true);setMessage(null);}}><Plus size={16}/> Create daily plan</Button>:undefined}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}{state.error?<Alert kind="error">{state.error}</Alert>:null}
    <div className="metric-grid metric-grid-four"><Card className="mini-metric"><div className="mini-metric-icon"><CalendarDays size={17}/></div><span>Plans in view</span><strong>{visiblePlans.length}</strong><small>Across selected shift</small></Card><Card className="mini-metric"><div className="mini-metric-icon"><ClipboardList size={17}/></div><span>Total planned units</span><strong>{formatQuantity(visiblePlans.reduce((s,p)=>s+(p.packing_jobs??[]).reduce((x:number,j:Row)=>x+Number(j.current_revised_quantity??0),0),0),0)}</strong><small>Authorized job targets</small></Card><Card className="mini-metric"><div className="mini-metric-icon green-mini"><Rocket size={17}/></div><span>Released plans</span><strong>{visiblePlans.filter(p=>p.status==="RELEASED").length}</strong><small>Ready for production</small></Card><Card className="mini-metric"><div className="mini-metric-icon amber-mini"><SlidersHorizontal size={17}/></div><span>Draft plans</span><strong>{visiblePlans.filter(p=>p.status==="DRAFT").length}</strong><small>Need validation + release</small></Card></div>
    <Card padding={false}><div className="table-toolbar"><Toolbar><SearchBox value={search} onChange={setSearch} placeholder="Search plan, shift or status…"/><span className="table-count">{visiblePlans.length} plans</span><Button variant="ghost" onClick={state.reload}><RefreshCw size={15}/> Refresh</Button></Toolbar></div><DataTable rows={visiblePlans} columns={columns} rowKey={r=>String(r.id)} emptyTitle="No daily plans" emptyDescription="Create a plan with one or more jobs. The same party/product can be listed multiple times with different BOMs."/></Card>
    {selectedPlan?<Card><div className="panel-heading"><div><div className="eyebrow">PLAN DETAIL</div><h2>{selectedPlan.plan_number}</h2><p>{displayDate(selectedPlan.plan_date)} · {selectedPlan.shift_code?.replaceAll("_"," ")} · <StatusBadge status={selectedPlan.status}/></p></div><div className="page-actions"><Button variant="secondary" onClick={()=>navigate("/daily-plans/jobs")}>Job details</Button><Button variant="ghost" onClick={()=>{setSelectedPlan(null);setPlanDetail(null);}}>Close</Button></div></div>{detailLoading?<div className="padded">Loading plan detail…</div>:<DataTable rows={planDetail?.jobs??activeJobs} rowKey={(j:Row)=>String(j.id)} columns={[
      {key:"jobCode",label:"Job",render:(r:Row)=><strong>{r.jobCode??r.job_code}</strong>},
      {key:"partyId",label:"Party",render:(r:Row)=>parties.find(p=>p.id===(r.partyId??r.party_id))?.name??String(r.partyId??r.party_id??"").slice(0,8)},
      {key:"productId",label:"Product",render:(r:Row)=>products.find(p=>p.id===(r.productId??r.product_id))?.name??String(r.productId??r.product_id??"").slice(0,8)},
      {key:"currentRevisedQuantity",label:"Target",render:(r:Row)=>formatQuantity(r.quantityStatus?.currentRevisedQuantity??r.current_revised_quantity,0)},
      {key:"pendingQuantity",label:"Pending",render:(r:Row)=>formatQuantity(r.quantityStatus?.pendingQuantity??r.pending_quantity,0)},
      {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>},
      {key:"open",label:"",render:(r:Row)=><Button variant="ghost" onClick={()=>navigate(`/daily-plans/jobs/${r.id}`)}>Open job →</Button>}
    ]}/>}</Card>:null}
    {createOpen?<Modal title="Create daily plan" description="A single plan can contain multiple jobs, including repeated product/party pairs with different recipe variants." onClose={()=>setCreateOpen(false)} wide><form className="page-stack compact-stack" onSubmit={createPlan}><div className="form-grid"><Field label="Plan date" value={planDate} onChange={setPlanDate} type="date" required/><SelectField label="Shift" value={shiftCode} onChange={setShiftCode} options={[{value:"GENERAL",label:"General"},{value:"SHIFT_1",label:"Shift 1"},{value:"SHIFT_2",label:"Shift 2"}]} required/><div className="span-2"><TextArea label="Plan notes" value={notes} onChange={setNotes} rows={2} placeholder="Customer schedule or shift handover notes"/></div></div>
      <div className="line-editor-head"><h3>Plan jobs</h3><Button variant="secondary" onClick={()=>setDraftJobs(old=>[...old,job()])}><Plus size={14}/> Add job</Button></div>
      {draftJobs.map((j,index)=><div className="plan-job-editor" key={index}><div className="plan-job-title"><span>JOB {String(index+1).padStart(2,"0")}</span><SelectField label="Recipe type" value={j.mode} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,mode:v as "standard"|"custom"}:x))} options={[{value:"standard",label:"Active master BOM"},{value:"custom",label:"Custom recipe"}]}/><Button variant="ghost" disabled={draftJobs.length===1} onClick={()=>setDraftJobs(old=>old.filter((_,i)=>i!==index))}>Remove</Button></div>
        <div className="form-grid"><SelectField label="Customer party" value={j.partyId} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,partyId:v}:x))} options={parties.filter(p=>p.is_active).map(p=>({value:p.id,label:`${p.code} · ${p.name}`}))} required/><SelectField label="Product" value={j.productId} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,productId:v}:x))} options={products.filter(p=>p.is_active).map(p=>({value:p.id,label:`${p.sku_code} · ${p.name}`}))} required/><Field label="Planned quantity" value={j.quantity} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,quantity:v}:x))} type="number" min={1} max={2000000} step={1} required/>
        {j.mode==="standard"?<SelectField label="Active BOM version" value={j.bomId} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,bomId:v}:x))} options={activeBoms.filter(b=>b.product_id===j.productId&&(!j.partyId||!b.party_id||b.party_id===j.partyId)).map(b=>({value:b.id,label:`${b.bom_code} · ${b.packing_variant_name} v${b.version_number}`}))} required/>:<>
          {j.customLines.map((customLine,lineIndex)=><div className="line-editor" key={lineIndex}>
            <SelectField label="Custom material" value={customLine.materialId} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,customLines:x.customLines.map((lineItem,k)=>k===lineIndex?{...lineItem,materialId:v,unitId:materials.find(m=>m.id===v)?.canonical_unit_id??lineItem.unitId}:lineItem)}:x))} options={materials.filter(m=>m.is_active).map(m=>({value:m.id,label:`${m.material_code} · ${m.name}`}))} required/>
            <Field label="Qty per finished unit" value={customLine.quantityPerUnit} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,customLines:x.customLines.map((lineItem,k)=>k===lineIndex?{...lineItem,quantityPerUnit:v}:lineItem)}:x))} type="number" min={0.00000001} step="any" required/>
            <SelectField label="Custom unit" value={customLine.unitId} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,customLines:x.customLines.map((lineItem,k)=>k===lineIndex?{...lineItem,unitId:v}:lineItem)}:x))} options={units.map(u=>({value:u.id,label:`${u.code} · ${u.name}`}))} required/>
            <Button variant="ghost" disabled={j.customLines.length===1} onClick={()=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,customLines:x.customLines.filter((_,k)=>k!==lineIndex)}:x))}>Remove</Button>
          </div>)}
          <Button variant="secondary" onClick={()=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,customLines:[...x.customLines,line()]}:x))}><Plus size={14}/> Add custom material</Button>
          <Field label="Customization note" value={j.notes} onChange={v=>setDraftJobs(old=>old.map((x,i)=>i===index?{...x,notes:v}:x))} placeholder="Custom packing spec"/>
        </>
        </div>{j.mode==="custom"?<div className="form-note"><SlidersHorizontal size={15}/> A custom recipe stays source-less. Release validates and freezes the entered line instead of creating a fake master BOM.</div>:null}
      </div>)}
      <div className="form-footer"><Button variant="secondary" onClick={()=>setCreateOpen(false)}>Cancel</Button><Button type="submit" loading={busy}>Create draft plan</Button></div>
    </form></Modal>:null}
  </div>;
}

export function JobDetailPage() {
  const {id}=useParams();
  const navigate=useNavigate();
  const [selectedId,setSelectedId]=useState(id??"");
  const [openModal,setOpenModal]=useState<"revise"|"cancel"|null>(null);
  const [quantity,setQuantity]=useState("");
  const [reason,setReason]=useState("");
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const list=useAsyncData(()=>selectRows("packing_jobs","id,job_code,daily_plan_id,status,current_revised_quantity,completed_quantity,pending_quantity,cancelled_quantity,original_planned_quantity,party_id,product_id","created_at",500));
  const detail=useAsyncData(async()=>selectedId?apiGet<Row>(`/packing-jobs/${selectedId}`):null,selectedId);
  const job=detail.data;
  const q=job?.quantityStatus;
  const balanced=q?quantityBalanced(q):false;
  const conservation=q?quantityEquation(q):"";
  const saveAction=async(e:FormEvent)=>{e.preventDefault();if(!job)return;setBusy(true);setMessage(null);try{
    if(openModal==="revise"){
      const qty=Number(quantity);
      if(!Number.isInteger(qty)||qty<q.completedQuantity)throw new Error(`New target cannot be below ${q.completedQuantity} completed units.`);
      await apiPost(`/packing-jobs/${job.id}/revise-quantity`,{revisedQuantity:qty,reason});
      setMessage({kind:"success",text:"Authorized target and reservations were updated."});
    }else{
      if(!reason.trim())throw new Error("Cancellation reason is required.");
      await apiPost(`/packing-jobs/${job.id}/cancel`,{reason});
      setMessage({kind:"success",text:"Pending units were cancelled. Completed production history remains unchanged."});
    }
    setOpenModal(null);detail.reload();list.reload();
  }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"The job operation failed."});}finally{setBusy(false);}};
  const jobColumns=[
    {key:"job_code",label:"Job code",render:(r:Row)=><strong>{r.job_code}</strong>},
    {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>},
    {key:"current_revised_quantity",label:"Authorized target",render:(r:Row)=>formatQuantity(r.current_revised_quantity,0)},
    {key:"completed_quantity",label:"Completed",render:(r:Row)=>formatQuantity(r.completed_quantity,0)},
    {key:"pending_quantity",label:"Pending",render:(r:Row)=>formatQuantity(r.pending_quantity,0)},
    {key:"open",label:"",render:(r:Row)=><Button variant="ghost" onClick={()=>{setSelectedId(r.id);navigate(`/daily-plans/jobs/${r.id}`);}}>Open →</Button>}
  ];
  return <div className="page-stack"><PageHeader eyebrow="JOB CONTROL" title="Packing job detail" description="Review frozen material requirements and maintain the 5-variable quantity conservation invariant." actions={job?<><Button variant="secondary" onClick={()=>{setOpenModal("revise");setQuantity(String(q.currentRevisedQuantity));setReason("");}}>Revise target</Button><Button variant="danger" onClick={()=>{setOpenModal("cancel");setReason("");}}>Cancel remainder</Button><Button onClick={()=>navigate(`/daily-plans/jobs/${job.id}/complete`)}>Record production →</Button></>:undefined}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}{detail.error?<Alert kind="error">{detail.error}</Alert>:null}
    {!id?<Card><div className="table-toolbar"><Toolbar><strong>Choose a packing job</strong><span className="table-count">{list.data?.length??0} jobs</span></Toolbar></div><DataTable rows={list.data??[]} columns={jobColumns} rowKey={r=>String(r.id)} emptyTitle="No packing jobs" emptyDescription="Create a daily plan and release it to generate jobs."/></Card>:null}
    {id&&!job&&!detail.loading?<Alert kind="info">Select a job from the list to load its live detail.</Alert>:null}
    {detail.loading?<Card><div className="padded">Loading job and frozen recipe…</div></Card>:null}
    {job&&q?<><Card><div className="job-detail-head"><div><div className="eyebrow">PACKING JOB</div><h2>{job.jobCode}</h2><p>Daily plan {String(job.dailyPlanId).slice(0,8)} · {job.isCustomized?"Custom frozen recipe":`Master BOM ${job.masterBomId?String(job.masterBomId).slice(0,8):"—"}`}</p></div><StatusBadge status={job.status}/></div><div className="quantity-stat-grid"><div><span>Original planned</span><strong>{formatQuantity(q.originalPlannedQuantity,0)}</strong></div><div><span>Current target</span><strong>{formatQuantity(q.currentRevisedQuantity,0)}</strong></div><div><span>Completed</span><strong className="success-text">{formatQuantity(q.completedQuantity,0)}</strong></div><div><span>Pending</span><strong className="blue-text">{formatQuantity(q.pendingQuantity,0)}</strong></div><div><span>Cancelled</span><strong className="warning-text">{formatQuantity(q.cancelledQuantity,0)}</strong></div></div><div className="conservation-panel"><div className={balanced?"balance-mark":"balance-mark unbalanced"}>{balanced?"✓":"!"}</div><div><strong>{balanced?"Quantity conservation balanced":"Quantity conservation mismatch"}</strong><p>{conservation}{balanced?" · Current target = completed + pending + cancelled":" · Review the server record before continuing."}</p></div><Badge tone={balanced?"green":"red"}>{balanced?"Balanced":"Check required"}</Badge></div><div className="quantity-progress"><span className="progress-completed" style={{width:`${q.currentRevisedQuantity?Math.min(100,q.completedQuantity/q.currentRevisedQuantity*100):0}%`}}/><span className="progress-pending" style={{width:`${q.currentRevisedQuantity?Math.min(100,q.pendingQuantity/q.currentRevisedQuantity*100):0}%`}}/><span className="progress-cancelled" style={{width:`${q.currentRevisedQuantity?Math.min(100,q.cancelledQuantity/q.currentRevisedQuantity*100):0}%`}}/></div><div className="progress-legend"><span><i className="legend-completed"/> Completed</span><span><i className="legend-pending"/> Pending</span><span><i className="legend-cancelled"/> Cancelled</span><small>Original target {q.originalPlannedQuantity} · Authorized target {q.currentRevisedQuantity}</small></div></Card>
      <Card><div className="panel-heading"><div><h2>Frozen BOM snapshot</h2><p>Required usage is calculated from snapshot quantities, not the latest master recipe.</p></div><Badge tone="purple">{job.snapshot?.lines?.length??0} lines</Badge></div><DataTable rows={job.snapshot?.lines??[]} rowKey={(r:Row)=>String(r.materialId)} columns={[
        {key:"materialId",label:"Material",render:(r:Row)=>String(r.materialId).slice(0,8)},
        {key:"quantityPerUnit",label:"Qty / unit",render:(r:Row)=>formatQuantity(r.quantityPerUnit)},
        {key:"canonicalQuantityPerUnit",label:"Canonical qty / unit",render:(r:Row)=><strong>{formatQuantity(r.canonicalQuantityPerUnit)}</strong>},
        {key:"required",label:"Total required",render:(r:Row)=>formatQuantity(Number(r.canonicalQuantityPerUnit)*q.currentRevisedQuantity)},
        {key:"canonicalUnitId",label:"Canonical unit",render:(r:Row)=>String(r.canonicalUnitId).slice(0,8)},
        {key:"isOptional",label:"Line",render:(r:Row)=><Badge tone={r.isOptional?"neutral":"blue"}>{r.isOptional?"Optional":"Required"}</Badge>}
      ]}/></Card><Card><div className="panel-heading"><div><h2>Production & history</h2><p>Every completion records the worker, ledger movements and consumption verification status.</p></div><Button onClick={()=>navigate(`/daily-plans/jobs/${job.id}/complete`)}>New completion <Rocket size={14}/></Button></div><div className="workflow-cards"><div><span>1</span><strong>Issue materials</strong><p>Issue stock to the worker custody location.</p><Button variant="secondary" onClick={()=>navigate("/worker-custody")}>Open custody</Button></div><div><span>2</span><strong>Record packed units</strong><p>Save the output and estimated/physical consumption.</p><Button variant="secondary" onClick={()=>navigate(`/daily-plans/jobs/${job.id}/complete`)}>Production entry</Button></div><div><span>3</span><strong>Reconcile the shift</strong><p>Verify any unmeasured quantities before closing.</p><Button variant="secondary" onClick={()=>navigate("/closings")}>Closing console</Button></div></div></Card></>:null}
    {openModal&&job?<Modal title={openModal==="revise"?"Revise authorized target":"Cancel pending remainder"} description={openModal==="revise"?"The target cannot be lower than already completed production.":"Cancellation preserves completed units and marks only the pending quantity as cancelled."} onClose={()=>setOpenModal(null)}><form className="stack-form" onSubmit={saveAction}>{openModal==="revise"?<Field label="New authorized target" value={quantity} onChange={setQuantity} type="number" min={q.completedQuantity} step={1} required hint={`Minimum permitted value: ${q.completedQuantity} completed units.`}/>:<div className="info-footnote"><ClipboardList size={15}/><span>{q.pendingQuantity} units will be cancelled; {q.completedQuantity} completed units remain recorded.</span></div>}<TextArea label={openModal==="revise"?"Revision reason":"Cancellation reason"} value={reason} onChange={setReason} rows={3} required placeholder="Write a traceable reason (minimum 3 characters)."/><div className="form-footer"><Button variant="secondary" onClick={()=>setOpenModal(null)}>Go back</Button><Button type="submit" variant={openModal==="cancel"?"danger":"primary"} loading={busy}>{openModal==="revise"?"Confirm revision":"Confirm cancellation"}</Button></div></form></Modal>:null}
  </div>;
}