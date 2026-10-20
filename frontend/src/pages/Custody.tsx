import { useState, type FormEvent } from "react";
import { ArrowDownToLine, ArrowUpFromLine, ClipboardCheck, RefreshCw, UserRound, Users } from "lucide-react";
import { apiGet, apiPost } from "../lib/api";
import { formatQuantity } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, PageHeader, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, selectRows, useAsyncData } from "./shared";

export function CustodyPage({role}:{role:string}) {
  const [tab,setTab]=useState<"issue"|"return">("issue");
  const [workerId,setWorkerId]=useState("");
  const [jobId,setJobId]=useState("");
  const [materialId,setMaterialId]=useState("");
  const [sourceId,setSourceId]=useState("");
  const [destinationId,setDestinationId]=useState("");
  const [quantity,setQuantity]=useState("1");
  const [unitId,setUnitId]=useState("");
  const [method,setMethod]=useState("MANUALLY_COUNTED");
  const [evidence,setEvidence]=useState("");
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const state=useAsyncData(async()=>{
    const [workers,materials,locations,jobs,custody]=await Promise.all([
      selectRows("workers","id,worker_code,name,assigned_location_id,is_active","name",500),
      selectRows("materials","id,material_code,name,canonical_unit_id,is_active","name",500),
      selectRows("locations","id,location_code,name,location_type,is_leaf,is_active","location_code",500),
      selectRows("packing_jobs","id,job_code,status,party_id,product_id,assigned_worker_id,daily_plan_id,pending_quantity,current_revised_quantity","created_at",500),
      apiGet<Row[]>("/stock/worker-custody")
    ]);
    return {workers,materials,locations,jobs,custody};
  },role);
  const {workers=[],materials=[],locations=[],jobs=[],custody=[]}=state.data??{};
  const activeWorkers=workers.filter(w=>w.is_active);
  const activeMaterials=materials.filter(m=>m.is_active);
  const activeJobs=jobs.filter(j=>["RELEASED","IN_PROGRESS","PARTIALLY_COMPLETED"].includes(j.status));
  const leafLocations=locations.filter(l=>l.is_active&&l.is_leaf);
  const sources=leafLocations.filter(l=>["STORE_SHELF","SHOP_FLOOR_BUFFER"].includes(l.location_type));
  const returnTargets=leafLocations.filter(l=>["STORE_SHELF","SHOP_FLOOR_BUFFER","DAMAGE_QUARANTINE"].includes(l.location_type));
  const worker=activeWorkers.find(w=>w.id===workerId);
  const unit=activeMaterials.find(m=>m.id===materialId)?.canonical_unit_id??"";
  const workerRows=custody.filter(r=>!workerId||r.workerId===workerId);
  const materialOptions=tab==="issue"?activeMaterials:activeMaterials.filter(m=>workerRows.some(r=>r.materialId===m.id&&Number(r.onHandQuantity)>0));
  const sourceOptions=tab==="issue"?sources:worker?[{id:worker.assigned_location_id,location_code:locations.find(l=>l.id===worker.assigned_location_id)?.location_code??"CUSTODY",name:"Worker custody"}]:[];
  const canIssue=["ADMIN","STOREKEEPER","PLANNER"].includes(role);
  const canReturn=["ADMIN","STOREKEEPER","OPERATOR"].includes(role);
  const submit=async(e:FormEvent)=>{
    e.preventDefault();setBusy(true);setMessage(null);
    try{
      if(!worker)throw new Error("Choose an active worker.");
      const material=activeMaterials.find(m=>m.id===materialId);if(!material)throw new Error("Choose a material.");
      const source=tab==="issue"?sourceId:worker.assigned_location_id;
      const destination=tab==="issue"?worker.assigned_location_id:destinationId;
      if(!source||!destination)throw new Error("Choose a source and destination.");
      if(tab==="issue"){
        const body={workerId:worker.id,jobId,materialId,sourceLocationId:source,destinationLocationId:destination,quantity:Number(quantity),unitId:material.canonical_unit_id,measurementMethod:method,measurementEvidence:evidence||null};
        const result=await apiPost<Row>("/stock/issue-to-worker",body);
        setMessage({kind:"success",text:`Issued ${formatQuantity(result.canonicalQuantity)} units to ${worker.name}. Transaction ${String(result.stockTransactionId).slice(0,8)} recorded.`});
      }else{
        const body={workerId:worker.id,jobId,materialId,sourceLocationId:source,destinationLocationId:destination,quantity:Number(quantity),unitId:material.canonical_unit_id,measurementMethod:method,measurementEvidence:evidence||null};
        const result=await apiPost<Row>("/stock/return-from-worker",body);
        setMessage({kind:"success",text:`Return posted. Transaction ${String(result.stockTransactionId).slice(0,8)} recorded.`});
      }
      setEvidence("");state.reload();
    }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Material movement failed."});}finally{setBusy(false);}
  };
  const columns=[
    {key:"workerCode",label:"Worker",render:(r:Row)=><div className="material-cell"><span className="material-avatar"><UserRound size={15}/></span><div><strong>{r.workerName}</strong><small>{r.workerCode}</small></div></div>},
    {key:"materialCode",label:"Material",render:(r:Row)=><div><strong>{r.materialName}</strong><small>{r.materialCode}</small></div>},
    {key:"onHandQuantity",label:"Custody quantity",render:(r:Row)=><strong>{formatQuantity(r.onHandQuantity)} {r.canonicalUnitCode}</strong>},
    {key:"availableQuantity",label:"Available",render:(r:Row)=>formatQuantity(r.availableQuantity)},
    {key:"workerIsActive",label:"Worker status",render:(r:Row)=><StatusBadge status={r.workerIsActive?"ACTIVE":"INACTIVE"}/>}
  ];
  return <div className="page-stack"><PageHeader eyebrow="SHOP-FLOOR MATERIALS" title="Worker custody" description="Trace materials issued to operators and bring unused or damaged items back to the right stock location." actions={<Button variant="secondary" onClick={state.reload}><RefreshCw size={15}/> Refresh</Button>}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}{state.error?<Alert kind="error">{state.error}</Alert>:null}
    <div className="metric-grid metric-grid-four"><Card className="mini-metric"><div className="mini-metric-icon"><Users size={17}/></div><span>Active workers</span><strong>{activeWorkers.length}</strong><small>Workers with an active master record</small></Card><Card className="mini-metric"><div className="mini-metric-icon blue-mini"><ArrowDownToLine size={17}/></div><span>Custody balances</span><strong>{custody.length}</strong><small>Worker/material combinations</small></Card><Card className="mini-metric"><div className="mini-metric-icon amber-mini"><ClipboardCheck size={17}/></div><span>Material on hand</span><strong>{formatQuantity(custody.reduce((s,r)=>s+Number(r.onHandQuantity??0),0))}</strong><small>Across assigned custody locations</small></Card><Card className="mini-metric"><div className="mini-metric-icon green-mini"><ArrowUpFromLine size={17}/></div><span>Return destinations</span><strong>{returnTargets.length}</strong><small>Shelves, buffers and quarantine bays</small></Card></div>
    <div className="two-column-layout"><Card padding={false}><div className="panel-tabs"><button className={tab==="issue"?"selected":""} onClick={()=>setTab("issue")}>Issue to worker</button><button className={tab==="return"?"selected":""} onClick={()=>setTab("return")}>Return from worker</button></div><form className="stack-form card-pad" onSubmit={submit}><div className="form-intro"><div className="form-symbol blue-symbol">{tab==="issue"?<ArrowDownToLine size={18}/>:<ArrowUpFromLine size={18}/>}</div><div><strong>{tab==="issue"?"Issue reserved material":"Receive unused material"}</strong><p>Stock transactions are posted atomically; the UI never edits the balance directly.</p></div></div>
      <SelectField label="Worker" value={workerId} onChange={v=>{setWorkerId(v);setSourceId("");}} options={activeWorkers.map(w=>({value:w.id,label:`${w.worker_code} · ${w.name}`}))} required/>
      <SelectField label="Packing job" value={jobId} onChange={setJobId} options={activeJobs.filter(j=>!workerId||!j.assigned_worker_id||j.assigned_worker_id===workerId).map(j=>({value:j.id,label:`${j.job_code} · ${j.status}`}))} required/>
      <SelectField label="Material" value={materialId} onChange={v=>{setMaterialId(v);setUnitId(activeMaterials.find(m=>m.id===v)?.canonical_unit_id??"");}} options={materialOptions.map(m=>({value:m.id,label:`${m.material_code} · ${m.name}`}))} required/>
      {tab==="issue"?<SelectField label="Source shelf / buffer" value={sourceId} onChange={setSourceId} options={sourceOptions.map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/>:<SelectField label="Worker custody source" value={worker?.assigned_location_id??""} onChange={setSourceId} options={sourceOptions.map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/>}
      <SelectField label={tab==="issue"?"Destination custody location":"Return destination"} value={tab==="issue"?(worker?.assigned_location_id??""):destinationId} onChange={tab==="issue"?()=>{}:setDestinationId} disabled={tab==="issue"} options={(tab==="issue"?leafLocations.filter(l=>l.id===worker?.assigned_location_id):returnTargets).map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/>
      <div className="form-grid"><Field label="Quantity" value={quantity} onChange={setQuantity} type="number" min={0.000001} step="any" required/><SelectField label="Measurement method" value={method} onChange={setMethod} options={[{value:"SCALE_WEIGHED",label:"Scale weighed"},{value:"SEALED_BUNDLE",label:"Sealed bundle"},{value:"MANUALLY_COUNTED",label:"Manually counted"}]} required/></div>
      <TextArea label="Measurement evidence" value={evidence} onChange={setEvidence} rows={2} required={method!=="SCALE_WEIGHED"} placeholder="Bundle label, scale slip or count note"/>
      <Button type="submit" loading={busy} disabled={tab==="issue"?!canIssue:!canReturn}>{tab==="issue"?"Confirm material issue":"Confirm material return"}</Button>
      {tab==="issue"&&!canIssue||tab==="return"&&!canReturn?<p className="field-error">Your role does not have permission for this movement.</p>:null}
    </form></Card><Card padding={false}><div className="panel-heading padded"><div><h2>Active worker custody</h2><p>Current physical material assigned to operator locations.</p></div><Badge tone="blue">{workerRows.length} lines</Badge></div><div className="table-toolbar"><Toolbar><SelectField label="Filter worker" value={workerId} onChange={setWorkerId} options={activeWorkers.map(w=>({value:w.id,label:w.name}))} placeholder="All workers"/></Toolbar></div><DataTable rows={workerRows} columns={columns} rowKey={(r:Row)=>`${r.workerId}-${r.materialId}`} emptyTitle="No custody balance" emptyDescription="Issue stock to an operator to create a custody balance."/></Card></div>
    <div className="info-footnote"><ClipboardCheck size={15}/><span>Physical issue/return requires a job reference and canonical unit. For sealed bundles or manual counts, enter evidence so the stock movement remains auditable.</span></div>
  </div>;
}