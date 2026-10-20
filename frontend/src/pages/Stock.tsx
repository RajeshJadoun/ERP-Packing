import { useMemo, useState } from "react";
import { AlertTriangle, ArrowDownLeft, ArrowLeftRight, ArrowUpRight, Boxes, Download, Filter, RefreshCw, Search, ShieldAlert, Trash2 } from "lucide-react";
import { Link } from "react-router-dom";
import { apiGet, apiPost } from "../lib/api";
import { formatQuantity } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, MetricCard, PageHeader, SearchBox, SectionTitle, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, downloadCsv, displayDate, selectRows, useAsyncData } from "./shared";

type Balance = Row & { materialId:string;materialCode:string;materialName:string;locationId:string;locationCode:string;locationType:string;onHandQuantity:number;reservedQuantity:number;availableQuantity:number;canonicalUnitCode:string };

export function StockPage() {
  const [tab,setTab] = useState<"balances"|"ledger">("balances");
  const [search,setSearch] = useState("");
  const [nodeType,setNodeType] = useState("ALL");
  const [materialFilter,setMaterialFilter] = useState("");
  const [fromDate,setFromDate] = useState("");
  const [toDate,setToDate] = useState("");
  const [refreshKey,setRefreshKey]=useState(0);
  const loadBalances=()=>apiGet<Balance[]>("/stock/balances");
  const loadLedger=()=>apiGet<Row[]>(`/stock/ledger?limit=200&offset=0${materialFilter? `&materialId=${encodeURIComponent(materialFilter)}`:""}${fromDate?`&fromDate=${fromDate}`:""}${toDate?`&toDate=${toDate}`:""}`);
  const balancesState=useAsyncData(loadBalances,String(refreshKey));
  const ledgerState=useAsyncData(loadLedger,`${refreshKey}|${materialFilter}|${fromDate}|${toDate}`);
  const balances=balancesState.data??[];
  const ledger=ledgerState.data??[];
  const visibleBalances=useMemo(()=>balances.filter((r)=> (nodeType==="ALL"||r.locationType===nodeType) && `${r.materialCode} ${r.materialName} ${r.categoryName??""} ${r.locationCode} ${r.locationType}`.toLowerCase().includes(search.toLowerCase())),[balances,nodeType,search]);
  const physical=balances.reduce((s,r)=>s+Number(r.onHandQuantity??0),0);
  const reserved=balances.reduce((s,r)=>s+Number(r.reservedQuantity??0),0);
  const usable=balances.filter((r)=>["STORE_SHELF","SHOP_FLOOR_BUFFER"].includes(r.locationType)).reduce((s,r)=>s+Number(r.availableQuantity??0),0);
  const quarantined=balances.filter((r)=>r.locationType==="DAMAGE_QUARANTINE").reduce((s,r)=>s+Number(r.onHandQuantity??0),0);
  const columns=[
    {key:"materialCode",label:"Material",render:(r:Balance)=><div className="material-cell"><span className="material-avatar"><Boxes size={16}/></span><div><strong>{r.materialName}</strong><small>{r.materialCode}</small></div></div>},
    {key:"categoryName",label:"Category",render:(r:Balance)=>r.categoryName||"—"},
    {key:"locationCode",label:"Location",render:(r:Balance)=><div><strong>{r.locationCode}</strong><small>{r.locationType.replaceAll("_"," ")}</small></div>},
    {key:"onHandQuantity",label:"On hand",render:(r:Balance)=><strong>{formatQuantity(r.onHandQuantity)} <small>{r.canonicalUnitCode}</small></strong>},
    {key:"reservedQuantity",label:"Reserved",render:(r:Balance)=>formatQuantity(r.reservedQuantity)},
    {key:"availableQuantity",label:"Available",render:(r:Balance)=><span className={r.availableQuantity<=0&&r.locationType!=="DAMAGE_QUARANTINE"?"danger-text":"success-text"}>{r.locationType==="DAMAGE_QUARANTINE"?"—":formatQuantity(r.availableQuantity)}</span>},
    {key:"status",label:"Stock state",render:(r:Balance)=>r.locationType==="DAMAGE_QUARANTINE"?<Badge tone="red">Quarantined</Badge>:r.availableQuantity<=0?<Badge tone="amber">No ATP</Badge>:<Badge tone="green">Available</Badge>}
  ];
  const ledgerColumns=[
    {key:"createdAt",label:"Date",render:(r:Row)=>displayDate(r.createdAt)},
    {key:"movementType",label:"Movement",render:(r:Row)=><StatusBadge status={r.movementType}/>},
    {key:"materialName",label:"Material",render:(r:Row)=><div><strong>{r.materialName??r.materialCode??"Material"}</strong><small>{String(r.materialId??"").slice(0,8)}</small></div>},
    {key:"canonicalQuantity",label:"Quantity",render:(r:Row)=><span>{formatQuantity(r.canonicalQuantity)} {r.canonicalUnitCode??""}</span>},
    {key:"route",label:"From → to",render:(r:Row)=><span className="route-text">{r.sourceLocationCode??r.sourceLocationName??"—"} <b>→</b> {r.destinationLocationCode??r.destinationLocationName??"—"}</span>},
    {key:"measurementMethod",label:"Measurement",render:(r:Row)=><div>{r.isEstimated?<Badge tone="amber">Estimated</Badge>:null}<small>{String(r.measurementMethod??"—").replaceAll("_"," ")}</small></div>},
    {key:"reference",label:"Reference",render:(r:Row)=><span className="muted-text">{r.packingJobId? `Job ${String(r.packingJobId).slice(0,8)}`:r.goodsReceiptId? `GRN ${String(r.goodsReceiptId).slice(0,8)}`:String(r.id??"").slice(0,8)}</span>}
  ];
  return <div className="page-stack">
    <PageHeader eyebrow="INVENTORY CONTROL" title="Stock & immutable ledger" description="See physical balances by leaf location, reserved quantities and what can actually be issued." actions={<><Button variant="secondary" onClick={()=>{setRefreshKey((n)=>n+1);}}><RefreshCw size={15}/> Refresh</Button><Button variant="secondary" onClick={()=>downloadCsv(tab==="balances"?"stock-balances.csv":"stock-ledger.csv",(tab==="balances"?visibleBalances:ledger) as Row[])}><Download size={15}/> Export CSV</Button></>}/>
    {(balancesState.error||ledgerState.error)?<Alert kind="error">{balancesState.error||ledgerState.error}</Alert>:null}
    <div className="metric-grid metric-grid-four"><MetricCard label="Tracked inventory" value={formatQuantity(physical)} detail="Across all active leaf locations" icon={<Boxes size={18}/>} tone="blue"/><MetricCard label="Available to promise" value={formatQuantity(usable)} detail="Store shelves + line-side buffer" icon={<ArrowUpRight size={19}/>} tone="green"/><MetricCard label="Active reservations" value={formatQuantity(reserved)} detail="Held for released packing jobs" icon={<ShieldAlert size={18}/>} tone="purple"/><MetricCard label="Quarantined stock" value={formatQuantity(quarantined)} detail="Tracked but not available to issue" icon={<AlertTriangle size={18}/>} tone="red"/></div>
    <Card padding={false}><div className="panel-tabs"><button className={tab==="balances"?"selected":""} onClick={()=>setTab("balances")}>Current balances <span>{balances.length}</span></button><button className={tab==="ledger"?"selected":""} onClick={()=>setTab("ledger")}>Transaction ledger <span>{ledger.length}</span></button></div>
      {tab==="balances"?<><div className="table-toolbar"><Toolbar><SearchBox value={search} onChange={setSearch}/><div className="toolbar-select"><Filter size={15}/><select aria-label="Facility type filter" value={nodeType} onChange={(e)=>setNodeType(e.target.value)}><option value="ALL">All facility types</option>{["STORE_SHELF","RECEIVING_BAY","SHOP_FLOOR_BUFFER","WORKER_CUSTODY","DAMAGE_QUARANTINE","DISPATCH"].map(x=><option key={x} value={x}>{x.replaceAll("_"," ")}</option>)}</select></div><span className="table-count">{visibleBalances.length} balance rows</span></Toolbar></div><DataTable rows={visibleBalances} columns={columns} rowKey={(r)=>`${r.materialId}-${r.locationId}`} emptyTitle="No stock balances" emptyDescription="Stock appears here after a receipt, transfer, issue or adjustment is posted."/></>
      :<><div className="table-toolbar"><Toolbar><div className="field-inline"><label>From<input type="date" value={fromDate} onChange={(e)=>setFromDate(e.target.value)}/></label><label>To<input type="date" value={toDate} onChange={(e)=>setToDate(e.target.value)}/></label></div><input className="toolbar-input" value={materialFilter} onChange={(e)=>setMaterialFilter(e.target.value)} placeholder="Optional material UUID"/><Button variant="ghost" onClick={ledgerState.reload}><RefreshCw size={15}/> Apply filters</Button><span className="table-count">{ledger.length} transactions</span></Toolbar></div><DataTable rows={ledger} columns={ledgerColumns} rowKey={(r)=>String(r.id)} emptyTitle="No ledger transactions" emptyDescription="Try a wider date range or clear the material filter."/></>}
    </Card>
    <div className="info-footnote"><ShieldAlert size={15}/><span>Balances are shown from active leaf nodes only to avoid parent-location double counting. The transaction ledger is append-only; corrections should use approved adjustments or a new movement.</span></div>
  </div>;
}

export function QuarantinePage({ role }: { role:string }) {
  const [tab,setTab]=useState<"move"|"scrap">("move");
  const [materialId,setMaterialId]=useState("");
  const [sourceId,setSourceId]=useState("");
  const [destinationId,setDestinationId]=useState("");
  const [unitId,setUnitId]=useState("");
  const [quantity,setQuantity]=useState("1");
  const [reason,setReason]=useState("");
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const balancesState=useAsyncData(()=>apiGet<Balance[]>("/stock/balances"));
  const materialsState=useAsyncData(()=>selectRows("materials","id,material_code,name,canonical_unit_id,is_active","name",500));
  const locationsState=useAsyncData(()=>selectRows("locations","id,location_code,name,location_type,is_leaf,is_active","location_code",500));
  const balances=balancesState.data??[];
  const materials=materialsState.data??[];
  const locations=locationsState.data??[];
  const quarantineLocations=locations.filter(x=>x.location_type==="DAMAGE_QUARANTINE"&&x.is_active&&x.is_leaf);
  const activeMaterial=materials.find(x=>x.id===materialId);
  const sourceLocations=locations.filter(x=>["STORE_SHELF","SHOP_FLOOR_BUFFER","WORKER_CUSTODY"].includes(x.location_type)&&x.is_active&&x.is_leaf);
  const stockRows=balances.filter(x=>x.locationType==="DAMAGE_QUARANTINE");
  const scrapAllowed=role==="ADMIN";
  const submit=async(e:React.FormEvent)=>{e.preventDefault();setBusy(true);setMessage(null);try{
    if(!activeMaterial)throw new Error("Choose a material.");
    if(tab==="move"){
      if(!sourceId||!destinationId||sourceId===destinationId)throw new Error("Choose different source and quarantine locations.");
      await apiPost("/stock/damage-quarantine",{materialId,quantity:Number(quantity),unitId:activeMaterial.canonical_unit_id,sourceLocationId:sourceId,destinationLocationId:destinationId,quarantineReason:reason.trim()});
      setMessage({kind:"success",text:"Quarantine movement posted. Total physical stock is unchanged; usable stock has moved out."});
    } else {
      if(!scrapAllowed)throw new Error("Only an administrator can dispose of scrap.");
      await apiPost("/stock/scrap-disposal",{materialId,quantity:Number(quantity),unitId:activeMaterial.canonical_unit_id,sourceLocationId:sourceId,disposalReason:reason.trim()});
      setMessage({kind:"success",text:"Scrap disposal posted to the immutable ledger."});
    }
    setReason("");balancesState.reload();
  }catch(err){setMessage({kind:"error",text:err instanceof Error?err.message:"The stock movement failed."});}finally{setBusy(false);}};
  const columns=[
    {key:"materialCode",label:"Material",render:(r:Balance)=><div><strong>{r.materialName}</strong><small>{r.materialCode}</small></div>},
    {key:"locationCode",label:"Quarantine bay",render:(r:Balance)=><div><strong>{r.locationCode}</strong><small>{r.locationId.slice(0,8)}</small></div>},
    {key:"onHandQuantity",label:"Quantity",render:(r:Balance)=><strong className="danger-text">{formatQuantity(r.onHandQuantity)} {r.canonicalUnitCode}</strong>},
    {key:"categoryName",label:"Category",render:(r:Balance)=>r.categoryName||"—"}
  ];
  return <div className="page-stack"><PageHeader eyebrow="QUALITY & CONTROL" title="Quarantine & scrap disposal" description="Separate damaged material from usable inventory and preserve a traceable write-off trail."/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}
    <div className="two-column-layout"><Card><div className="panel-tabs"><button className={tab==="move"?"selected":""} onClick={()=>setTab("move")}>Move to quarantine</button><button className={tab==="scrap"?"selected":""} onClick={()=>setTab("scrap")}>Dispose of scrap</button></div><form className="stack-form card-pad" onSubmit={submit}>
      <div className="form-intro"><div className="form-symbol warning-symbol">{tab==="move"?<AlertTriangle size={18}/>:<Trash2 size={18}/>}</div><div><strong>{tab==="move"?"Quarantine a damaged lot":"Write off condemned stock"}</strong><p>{tab==="move"?"Moves stock without reducing total physical inventory.":"Reduces physical inventory permanently. Admin approval required."}</p></div></div>
      <SelectField label="Material" value={materialId} onChange={(v)=>{setMaterialId(v);setUnitId(materials.find(m=>m.id===v)?.canonical_unit_id??"");}} options={materials.filter(m=>m.is_active).map(m=>({value:m.id,label:`${m.material_code} · ${m.name}`}))} required/>
      {tab==="move"?<SelectField label="Source location" value={sourceId} onChange={setSourceId} options={sourceLocations.map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/>:<SelectField label="Quarantine source bay" value={sourceId} onChange={setSourceId} options={quarantineLocations.map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/>}
      {tab==="move"?<SelectField label="Destination quarantine bay" value={destinationId} onChange={setDestinationId} options={quarantineLocations.map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/>:null}
      <Field label={`Quantity (${materials.find(m=>m.id===materialId)?.canonical_unit_id===unitId?"canonical unit":"canonical"} )`} value={quantity} onChange={setQuantity} type="number" min={0.000001} step="any" required/>
      <TextArea label={tab==="move"?"Quarantine reason":"Disposal reason"} value={reason} onChange={setReason} rows={3} placeholder={tab==="move"?"e.g. Moisture damage found on receipt":"e.g. QC condemned after inspection"} required/>
      <Button type="submit" loading={busy} variant={tab==="scrap"?"danger":"primary"} disabled={tab==="scrap"&&!scrapAllowed}>{tab==="move"?"Confirm quarantine":"Confirm scrap disposal"}</Button>
      {tab==="scrap"&&!scrapAllowed?<p className="field-error">Your current role cannot dispose of scrap.</p>:null}
    </form></Card><Card><SectionTitle title="Quarantine overview" detail="Current balances in active quarantine bays"/><div className="quarantine-summary"><div><span>Total quarantined quantity</span><strong>{formatQuantity(stockRows.reduce((s,r)=>s+Number(r.onHandQuantity),0))}</strong></div><Badge tone="red">{stockRows.length} balance rows</Badge></div><DataTable rows={stockRows} columns={columns} rowKey={(r)=>`${r.materialId}-${r.locationId}`} emptyTitle="No quarantined stock" emptyDescription="Damaged material will appear here after it is moved into quarantine."/></Card></div>
  </div>;
}