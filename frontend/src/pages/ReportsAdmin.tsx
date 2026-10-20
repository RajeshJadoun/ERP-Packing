import { useMemo, useState, type FormEvent } from "react";
import { Activity, Download, FileBarChart2, FileClock, ShieldCheck, Users, RefreshCw, Search, UserCog } from "lucide-react";
import { apiGet, apiPost } from "../lib/api";
import { supabase } from "../lib/supabase";
import { formatQuantity } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, PageHeader, SearchBox, SectionTitle, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, downloadCsv, displayDate, selectRows, useAsyncData } from "./shared";

export function ReportsPage() {
  const [tab,setTab]=useState<"stock"|"consumption"|"vendors"|"custody">("stock");
  const [search,setSearch]=useState("");
  const state=useAsyncData(async()=>{
    const [balances,ledger,custody,consumptions,completions,vendors,receipts]=await Promise.all([
      apiGet<Row[]>("/stock/balances"),
      apiGet<Row[]>("/stock/ledger?limit=500&offset=0"),
      apiGet<Row[]>("/stock/worker-custody"),
      selectRows("material_consumption_records","id,production_completion_id,material_id,theoretical_quantity,posted_ledger_quantity,physically_confirmed_quantity,variance_quantity,variance_status,stock_transaction_id,created_at","created_at",1000),
      selectRows("production_completions","id,packing_job_id,completion_number,completed_units,completed_by_worker_id,completion_policy,completion_timestamp","completion_timestamp",1000),
      selectRows("vendors","id,vendor_code,name,is_active","name",500),
      selectRows("goods_receipts","id,grn_number,vendor_id,invoice_date,received_date,status,posted_at","received_date",500)
    ]);
    return {balances,ledger,custody,consumptions,completions,vendors,receipts};
  },"reports");
  const {balances=[],ledger=[],custody=[],consumptions=[],completions=[],vendors=[],receipts=[]}=state.data??{};
  const visibleBalances=useMemo(()=>balances.filter(r=>`${r.materialCode} ${r.materialName} ${r.locationCode} ${r.locationType}`.toLowerCase().includes(search.toLowerCase())),[balances,search]);
  const varianceRows=consumptions.filter(r=>r.variance_status!=="VERIFIED_ZERO"||r.physically_confirmed_quantity===null).map(r=>{
    const completion=completions.find(c=>c.id===r.production_completion_id);
    return {...r,completionNumber:completion?.completion_number??String(r.production_completion_id).slice(0,8),completedUnits:completion?.completed_units,policy:completion?.completion_policy};
  });
  const vendorRows=vendors.map(v=>{
    const grns=receipts.filter(g=>g.vendor_id===v.id);
    const posted=grns.filter(g=>g.status==="POSTED");
    return {vendorCode:v.vendor_code,vendorName:v.name,totalReceipts:grns.length,postedReceipts:posted.length,lastReceived:posted.sort((a,b)=>String(b.received_date).localeCompare(String(a.received_date)))[0]?.received_date??null,active:v.is_active};
  }).filter(r=>`${r.vendorCode} ${r.vendorName}`.toLowerCase().includes(search.toLowerCase()));
  const reportRows:Record<string,unknown>[] = tab==="stock"?visibleBalances as Record<string,unknown>[]:tab==="consumption"?varianceRows as Record<string,unknown>[]:tab==="vendors"?vendorRows as Record<string,unknown>[]:custody as Record<string,unknown>[];
  const totalStock=balances.reduce((s,r)=>s+Number(r.onHandQuantity??0),0);
  const totalAvailable=balances.reduce((s,r)=>s+Number(r.availableQuantity??0),0);
  const openVariance=consumptions.filter(r=>r.variance_status==="VARIANCE_RECORDED").length;
  const unverified=consumptions.filter(r=>r.variance_status==="UNVERIFIED").length;
  const columns:Record<typeof tab,Array<{key:string;label:string;render?:(row:Row)=>React.ReactNode}>>={
    stock:[
      {key:"materialName",label:"Material",render:r=><div><strong>{r.materialName}</strong><small>{r.materialCode}</small></div>},
      {key:"locationCode",label:"Location",render:r=><div><strong>{r.locationCode}</strong><small>{r.locationType?.replaceAll("_"," ")}</small></div>},
      {key:"onHandQuantity",label:"On hand",render:r=>formatQuantity(r.onHandQuantity)},
      {key:"reservedQuantity",label:"Reserved",render:r=>formatQuantity(r.reservedQuantity)},
      {key:"availableQuantity",label:"ATP",render:r=><strong>{formatQuantity(r.availableQuantity)}</strong>},
      {key:"canonicalUnitCode",label:"Unit"}
    ],
    consumption:[
      {key:"completionNumber",label:"Completion",render:r=><div><strong>{r.completionNumber}</strong><small>{r.completedUnits??"—"} units</small></div>},
      {key:"material_id",label:"Material",render:r=>String(r.material_id).slice(0,8)},
      {key:"theoretical_quantity",label:"Theoretical",render:r=>formatQuantity(r.theoretical_quantity)},
      {key:"physically_confirmed_quantity",label:"Physical",render:r=>r.physically_confirmed_quantity===null?<Badge tone="amber">Unverified</Badge>:formatQuantity(r.physically_confirmed_quantity)},
      {key:"variance_quantity",label:"Variance",render:r=>r.variance_quantity===null?"—":formatQuantity(r.variance_quantity)},
      {key:"variance_status",label:"Status",render:r=><StatusBadge status={r.variance_status}/>}
    ],
    vendors:[
      {key:"vendorCode",label:"Vendor",render:r=><div><strong>{r.vendorName}</strong><small>{r.vendorCode}</small></div>},
      {key:"totalReceipts",label:"GRNs",render:r=>r.totalReceipts},
      {key:"postedReceipts",label:"Posted",render:r=><span className="success-text">{r.postedReceipts}</span>},
      {key:"lastReceived",label:"Last receipt",render:r=>displayDate(r.lastReceived)},
      {key:"active",label:"Status",render:r=><StatusBadge status={r.active?"ACTIVE":"INACTIVE"}/>}
    ],
    custody:[
      {key:"workerName",label:"Worker",render:r=><div><strong>{r.workerName}</strong><small>{r.workerCode}</small></div>},
      {key:"materialName",label:"Material",render:r=><div><strong>{r.materialName}</strong><small>{r.materialCode}</small></div>},
      {key:"onHandQuantity",label:"Custody balance",render:r=>formatQuantity(r.onHandQuantity)},
      {key:"canonicalUnitCode",label:"Unit"},
      {key:"workerIsActive",label:"Worker status",render:r=><StatusBadge status={r.workerIsActive?"ACTIVE":"INACTIVE"}/>}
    ]
  };
  const title=tab==="stock"?"Stock by location":tab==="consumption"?"Consumption variance audit":tab==="vendors"?"Vendor delivery summary":"Worker consumption audit";
  const download=()=>downloadCsv(`packwise-${tab}-report.csv`,reportRows);
  return <div className="page-stack"><PageHeader eyebrow="REPORTING & ANALYTICS" title="Operations reports" description="Live report slices built from the authoritative stock ledger, completed batches and caller-scoped database reads." actions={<><Button variant="secondary" onClick={state.reload}><RefreshCw size={15}/> Refresh</Button><Button onClick={download}><Download size={15}/> Export CSV</Button></>}/>
    {state.error?<Alert kind="error">{state.error}</Alert>:null}
    <div className="metric-grid metric-grid-four"><Card className="mini-metric"><div className="mini-metric-icon"><Activity size={17}/></div><span>Tracked inventory</span><strong>{formatQuantity(totalStock)}</strong><small>Across all active leaf locations</small></Card><Card className="mini-metric"><div className="mini-metric-icon green-mini"><FileBarChart2 size={17}/></div><span>Available to promise</span><strong>{formatQuantity(totalAvailable)}</strong><small>After active reservations</small></Card><Card className="mini-metric"><div className="mini-metric-icon amber-mini"><FileClock size={17}/></div><span>Unverified consumption</span><strong>{unverified}</strong><small>Physical count still needed</small></Card><Card className="mini-metric"><div className="mini-metric-icon red-mini"><ShieldCheck size={17}/></div><span>Recorded variances</span><strong>{openVariance}</strong><small>Non-zero physical difference</small></Card></div>
    <Card padding={false}><div className="panel-tabs">{([{id:"stock",label:"Stock by location",count:balances.length},{id:"consumption",label:"Consumption variance",count:varianceRows.length},{id:"vendors",label:"Vendor quality",count:vendors.length},{id:"custody",label:"Worker custody",count:custody.length}] as Array<{id:typeof tab;label:string;count:number}>).map(x=><button key={x.id} className={tab===x.id?"selected":""} onClick={()=>{setTab(x.id);setSearch("");}}>{x.label} <span>{x.count}</span></button>)}</div><div className="table-toolbar"><Toolbar>{tab!=="vendors"?<SearchBox value={search} onChange={setSearch} placeholder="Filter this report…"/>:<SearchBox value={search} onChange={setSearch} placeholder="Search vendor…"/>}<span className="table-count">{reportRows.length} rows</span></Toolbar></div><DataTable rows={reportRows as Row[]} columns={columns[tab]} rowKey={(r:Row)=>String(r.id??r.materialId??r.vendorCode??`${r.workerId}-${r.materialId}`) } emptyTitle="No report data" emptyDescription="Records will appear here as operational transactions are posted."/></Card>
    <div className="info-footnote"><FileBarChart2 size={15}/><span>Exports contain the filtered rows displayed above. Variance reports never treat a missing physical count as zero; unverified records remain explicitly unverified.</span></div>
  </div>;
}

export function AdminPage({role,profile}:{role:string;profile:Row}) {
  const [search,setSearch]=useState("");
  const [targetId,setTargetId]=useState("");
  const [targetRole,setTargetRole]=useState("STOREKEEPER");
  const [isActive,setIsActive]=useState(true);
  const [reason,setReason]=useState("");
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const state=useAsyncData(async()=>{
    const [profiles,audit]=await Promise.all([
      supabase.from("profiles").select("id,full_name,role,is_active,created_at,updated_at").order("created_at",{ascending:false}).limit(300),
      selectRows("audit_logs","id,event_type,actor_id,target_entity_type,target_entity_id,created_at,new_state","created_at",250)
    ]);
    if(profiles.error)throw profiles.error;
    const rows=(profiles.data??[]) as Row[];
    return {profiles:rows,audit};
  },role);
  const {profiles=[],audit=[]}=state.data??{};
  const filtered=profiles.filter(p=>`${p.full_name??""} ${p.role} ${p.id}`.toLowerCase().includes(search.toLowerCase()));
  const submit=async(e:FormEvent)=>{
    e.preventDefault();if(role!=="ADMIN")return;
    setBusy(true);setMessage(null);
    try{
      if(!targetId.trim())throw new Error("Enter the target profile UUID.");
      if(reason.trim().length<10)throw new Error("Reason must contain at least 10 characters.");
      const result=await apiPost<Row>(`/admin/users/${targetId.trim()}/access`,{role:targetRole,isActive,reason:reason.trim()});
      setMessage({kind:"success",text:`Access updated for ${result.profile?.fullName??result.profile?.id??targetId}. Audit event ${String(result.auditLogId??"").slice(0,8)} recorded.`});setReason("");state.reload();
    }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not update access."});}finally{setBusy(false);}
  };
  const userColumns=[
    {key:"full_name",label:"Profile",render:(r:Row)=><div className="material-cell"><span className="material-avatar"><Users size={15}/></span><div><strong>{r.full_name||"Unnamed user"}</strong><small>{String(r.id).slice(0,8)}…</small></div></div>},
    {key:"role",label:"Application role",render:(r:Row)=><Badge tone={r.role==="ADMIN"?"purple":"blue"}>{r.role}</Badge>},
    {key:"is_active",label:"State",render:(r:Row)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>},
    {key:"created_at",label:"Created",render:(r:Row)=>displayDate(r.created_at)},
    {key:"actions",label:"Select",render:(r:Row)=><Button variant="ghost" onClick={()=>{setTargetId(r.id);setTargetRole(r.role??"VIEWER");setIsActive(Boolean(r.is_active));}}>Manage →</Button>}
  ];
  const auditColumns=[
    {key:"created_at",label:"Date",render:(r:Row)=>displayDate(r.created_at)},
    {key:"event_type",label:"Event",render:(r:Row)=><div><strong>{r.event_type}</strong><small>{r.target_entity_type??"System"}</small></div>},
    {key:"actor_id",label:"Actor",render:(r:Row)=>String(r.actor_id??"—").slice(0,8)},
    {key:"target_entity_id",label:"Target",render:(r:Row)=>String(r.target_entity_id??"—").slice(0,8)},
    {key:"new_state",label:"Change",render:(r:Row)=><span className="muted-text">{r.new_state?JSON.stringify(r.new_state).slice(0,100):"—"}</span>}
  ];
  if(role!=="ADMIN")return <Alert kind="error">System administration is restricted to administrators.</Alert>;
  return <div className="page-stack"><PageHeader eyebrow="GOVERNANCE" title="System administration" description="Manage application profile access and inspect the immutable audit log. Database role rules remain authoritative." actions={<Button variant="secondary" onClick={state.reload}><RefreshCw size={15}/> Refresh</Button>}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}{state.error?<Alert kind="error">{state.error}</Alert>:null}
    <div className="admin-banner"><div className="admin-icon"><ShieldCheck size={23}/></div><div><strong>Administrator session verified</strong><p>Current actor: {profile.full_name??profile.id} · Role changes are audited server-side and require a reason.</p></div><Badge tone="purple">ADMIN</Badge></div>
    <div className="two-column-layout"><Card><SectionTitle title="Update user access" detail="Change another user's role or active status."/><form className="stack-form" onSubmit={submit}><Field label="Target profile UUID" value={targetId} onChange={setTargetId} required placeholder="Paste profile UUID"/><SelectField label="Application role" value={targetRole} onChange={setTargetRole} options={["ADMIN","STOREKEEPER","PLANNER","OPERATOR","VIEWER"].map(v=>({value:v,label:v.replaceAll("_"," ")}))} required/><label className="checkbox-field"><input type="checkbox" checked={isActive} onChange={e=>setIsActive(e.target.checked)}/><span>Profile is active</span></label><TextArea label="Audit reason" value={reason} onChange={setReason} rows={3} required hint="At least 10 characters; the reason will be saved with the access-change audit event." placeholder="e.g. Promoted after warehouse training completed."/><Button type="submit" loading={busy}><UserCog size={15}/> Save access change</Button></form></Card><Card><SectionTitle title="Administrative guardrails" detail="Role changes use the protected Flask endpoint."/><div className="security-list"><div><ShieldCheck size={17}/><div><strong>Role is verified on the server</strong><p>Frontend-selected roles do not override database authorization.</p></div></div><div><FileClock size={17}/><div><strong>Access changes are audited</strong><p>Each update returns an audit-log reference for review.</p></div></div><div><Search size={17}/><div><strong>No client-side privileged key</strong><p>This UI uses the signed-in user session and public client configuration.</p></div></div></div></Card></div>
    <Card padding={false}><div className="panel-heading padded"><div><h2>User profiles</h2><p>Profiles visible under the current administrator RLS policy.</p></div><Badge>{profiles.length} users</Badge></div><div className="table-toolbar"><Toolbar><SearchBox value={search} onChange={setSearch} placeholder="Search user, role or UUID…"/><span className="table-count">{filtered.length} profiles</span></Toolbar></div><DataTable rows={filtered} columns={userColumns} rowKey={r=>String(r.id)} emptyTitle="No profiles visible" emptyDescription="Check the current session and the administrator profile RLS policy."/></Card>
    <Card padding={false}><div className="panel-heading padded"><div><h2>Audit event log</h2><p>Latest operational and access-control events visible to this role.</p></div><Badge tone="blue">{audit.length} events</Badge></div><DataTable rows={audit} columns={auditColumns} rowKey={r=>String(r.id)} emptyTitle="No audit events" emptyDescription="Protected business operations generate durable audit events."/></Card>
  </div>;
}