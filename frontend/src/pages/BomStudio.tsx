import { useMemo, useState, type FormEvent } from "react";
import { GitCompare, Layers3, Plus, Rocket, Sparkles, Tag, RefreshCw } from "lucide-react";
import { supabase } from "../lib/supabase";
import { apiPost } from "../lib/api";
import { Alert, Badge, Button, Card, DataTable, Field, Modal, PageHeader, SearchBox, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, selectRows, useAsyncData } from "./shared";

type BomLineDraft={materialId:string;quantity:string;unitId:string;optional:boolean;notes:string};
const newLine=():BomLineDraft=>({materialId:"",quantity:"1",unitId:"",optional:false,notes:""});
export function BomStudioPage({role}:{role:string}) {
  const [search,setSearch]=useState("");
  const [createOpen,setCreateOpen]=useState(false);
  const [versionOf,setVersionOf]=useState<Row|null>(null);
  const [selected,setSelected]=useState<Row|null>(null);
  const [productId,setProductId]=useState("");
  const [partyId,setPartyId]=useState("");
  const [variant,setVariant]=useState("");
  const [notes,setNotes]=useState("");
  const [revisionReason,setRevisionReason]=useState("");
  const [lines,setLines]=useState<BomLineDraft[]>([newLine()]);
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const masters=useAsyncData(async()=>{
    const [b,p,parties,materials,units]=await Promise.all([
      supabase.from("boms").select("id,bom_code,product_id,party_id,packing_variant_name,version_number,status,notes,created_at,bom_lines(id,material_id,quantity_per_unit,unit_id,is_optional,notes)").order("created_at",{ascending:false}).limit(300),
      selectRows("products","id,sku_code,name,is_active","name",500),
      selectRows("parties","id,code,name,is_active","name",500),
      selectRows("materials","id,material_code,name,canonical_unit_id,is_active","name",500),
      selectRows("units","id,code,name,dimension","code",250)
    ]);
    if(b.error)throw b.error;
    return {boms:(b.data??[]) as Row[],products:p,parties,materials,units};
  },role);
  const {boms=[],products=[],parties=[],materials=[],units=[]}=masters.data??{};
  const canWrite=["ADMIN","PLANNER"].includes(role);
  const filtered=useMemo(()=>boms.filter(b=>`${b.bom_code} ${b.packing_variant_name} ${b.status} ${products.find(p=>p.id===b.product_id)?.name??""}`.toLowerCase().includes(search.toLowerCase())),[boms,products,search]);
  const selectedLines=selected?.bom_lines??[];
  const related=selected?boms.filter(b=>b.product_id===selected.product_id&&(b.party_id??null)===(selected.party_id??null)&&b.packing_variant_name===selected.packing_variant_name).sort((a,b)=>Number(b.version_number)-Number(a.version_number)):[];

  const openCreate=()=>{setVersionOf(null);setSelected(null);setProductId("");setPartyId("");setVariant("");setNotes("");setRevisionReason("");setLines([newLine()]);setMessage(null);setCreateOpen(true);};
  const openVersion=(bom:Row)=>{setVersionOf(bom);setProductId(String(bom.product_id));setPartyId(String(bom.party_id??""));setVariant(String(bom.packing_variant_name));setNotes("");setRevisionReason("");setLines((bom.bom_lines??[]).map((l:Row)=>({materialId:l.material_id,quantity:String(l.quantity_per_unit),unitId:l.unit_id,optional:Boolean(l.is_optional),notes:l.notes??""})));setMessage(null);setCreateOpen(true);};
  const submit=async(e:FormEvent)=>{
    e.preventDefault();setBusy(true);setMessage(null);
    try{
      const ready=lines.filter(l=>l.materialId&&l.unitId&&Number(l.quantity)>0);
      if(!productId)throw new Error("Choose a product.");
      if(!variant.trim())throw new Error("Packing variant name is required.");
      if(!ready.length)throw new Error("Add at least one BOM material line.");
      const payloadLines=ready.map(l=>({materialId:l.materialId,quantityPerUnit:Number(l.quantity),unitId:l.unitId,isOptional:l.optional,applicationNotes:l.notes||null}));
      const result=versionOf
        ? await apiPost<Row>(`/boms/${versionOf.id}/new-version`,{revisionReason,lines:payloadLines})
        : await apiPost<Row>("/boms",{productId,partyId:partyId||null,packingVariantName:variant,versionNotes:notes||null,lines:payloadLines});
      setMessage({kind:"success",text:`BOM ${result.bomCode??result.id} saved as version ${result.versionNumber??"draft"}.`});
      setCreateOpen(false);masters.reload();
    }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"The BOM could not be saved."});}finally{setBusy(false);}
  };
  const activate=async(bom:Row)=>{
    setBusy(true);setMessage(null);
    try{await apiPost(`/boms/${bom.id}/activate`,{});setMessage({kind:"success",text:`${bom.bom_code} v${bom.version_number} is now active. Existing frozen job snapshots are unchanged.`});masters.reload();}
    catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not activate BOM version."});}finally{setBusy(false);}
  };
  const columns=[
    {key:"bom_code",label:"Recipe",render:(r:Row)=><div className="material-cell"><span className="material-avatar bom-avatar"><Layers3 size={16}/></span><div><strong>{r.bom_code}</strong><small>{r.packing_variant_name}</small></div></div>},
    {key:"product_id",label:"Product",render:(r:Row)=>{const p=products.find(x=>x.id===r.product_id);return <div><strong>{p?.name??String(r.product_id).slice(0,8)}</strong><small>{p?.sku_code??"SKU"}</small></div>;}},
    {key:"party_id",label:"Party",render:(r:Row)=>parties.find(p=>p.id===r.party_id)?.name??<span className="muted-text">Generic recipe</span>},
    {key:"version_number",label:"Version",render:(r:Row)=><Badge tone="purple">v{r.version_number}</Badge>},
    {key:"bom_lines",label:"Material lines",render:(r:Row)=><span>{(r.bom_lines??[]).length} lines</span>},
    {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>},
    {key:"actions",label:"Actions",render:(r:Row)=><div className="row-actions"><Button variant="ghost" onClick={()=>setSelected(r)}><GitCompare size={14}/> Compare</Button>{canWrite&&r.status!=="ACTIVE"?<Button variant="secondary" onClick={()=>void activate(r)} loading={busy}><Rocket size={14}/> Activate</Button>:null}{canWrite?<button className="icon-button small-icon" aria-label="Create new BOM version" title="Create new version" onClick={()=>openVersion(r)}><Plus size={16}/></button>:null}</div>}
  ];
  return <div className="page-stack"><PageHeader eyebrow="RECIPE GOVERNANCE" title="BOM studio" description="Version-controlled packing recipes with party overrides and immutable released-job snapshots." actions={canWrite?<Button onClick={openCreate}><Plus size={16}/> Create BOM</Button>:undefined}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}{masters.error?<Alert kind="error">{masters.error}</Alert>:null}
    <div className="bom-banner"><div className="bom-banner-icon"><Sparkles size={22}/></div><div><strong>Recipes are versioned, not overwritten.</strong><p>Activating a new version changes the active catalog recipe; jobs already released keep the exact BOM and conversion factors frozen at their release date.</p></div><Badge tone="green">Snapshot-safe</Badge></div>
    <Card padding={false}><div className="table-toolbar"><Toolbar><SearchBox value={search} onChange={setSearch} placeholder="Search recipe, product, version…"/><span className="table-count">{filtered.length} versions</span><Button variant="ghost" onClick={masters.reload}><RefreshCw size={15}/> Refresh</Button></Toolbar></div><DataTable rows={filtered} columns={columns} rowKey={r=>String(r.id)} emptyTitle="No BOM recipes" emptyDescription="Create the first recipe from an active product and its required materials."/></Card>
    {selected?<Card><div className="panel-heading"><div><div className="eyebrow">VERSION DIFF VIEWER</div><h2>{selected.bom_code} · {selected.packing_variant_name}</h2><p>Compare the selected version against the previous recipe version.</p></div><Button variant="ghost" onClick={()=>setSelected(null)}>Close</Button></div><div className="version-chips">{related.map(b=><button key={b.id} className={selected.id===b.id?"selected":""} onClick={()=>setSelected(b)}>v{b.version_number} · {b.status}</button>)}</div><DataTable rows={selectedLines} rowKey={(r:Row)=>String(r.id??r.material_id)} columns={[
      {key:"material_id",label:"Material",render:(r:Row)=>materials.find(m=>m.id===r.material_id)?.name??String(r.material_id).slice(0,8)},
      {key:"quantity_per_unit",label:"Qty per finished unit",render:(r:Row)=><strong>{r.quantity_per_unit} {units.find(u=>u.id===r.unit_id)?.code??""}</strong>},
      {key:"is_optional",label:"Requirement",render:(r:Row)=><Badge tone={r.is_optional?"neutral":"blue"}>{r.is_optional?"Optional":"Required"}</Badge>},
      {key:"notes",label:"Notes"}
    ]}/></Card>:null}
    {createOpen?<Modal title={versionOf?`Create new version from ${versionOf.bom_code}`:"Create master BOM"} description="Every BOM needs at least one positive material line. Activation is a separate audited action." onClose={()=>setCreateOpen(false)} wide><form className="page-stack compact-stack" onSubmit={submit}>
      {!versionOf?<div className="form-grid"><SelectField label="Product" value={productId} onChange={setProductId} options={products.filter(p=>p.is_active).map(p=>({value:p.id,label:`${p.sku_code} · ${p.name}`}))} required/><SelectField label="Party override (optional)" value={partyId} onChange={setPartyId} options={parties.filter(p=>p.is_active).map(p=>({value:p.id,label:`${p.code} · ${p.name}`}))} /><Field label="Packing variant" value={variant} onChange={setVariant} required placeholder="Standard carton / screw kit"/><TextArea label="Version notes" value={notes} onChange={setNotes} rows={2}/></div>:<TextArea label="Revision reason" value={revisionReason} onChange={setRevisionReason} rows={2} required placeholder="Explain why the recipe is changing"/>}
      <div className="line-editor-head"><h3>Material recipe</h3><Button variant="secondary" onClick={()=>setLines(old=>[...old,newLine()])}><Plus size={14}/> Add material</Button></div>
      {lines.map((line,index)=><div className="line-editor" key={index}><SelectField label="Material" value={line.materialId} onChange={v=>setLines(old=>old.map((x,i)=>i===index?{...x,materialId:v,unitId:materials.find(m=>m.id===v)?.canonical_unit_id??x.unitId}:x))} options={materials.filter(m=>m.is_active).map(m=>({value:m.id,label:`${m.material_code} · ${m.name}`}))} required/><Field label="Quantity per unit" value={line.quantity} onChange={v=>setLines(old=>old.map((x,i)=>i===index?{...x,quantity:v}:x))} type="number" min={0.00000001} step="any" required/><SelectField label="Unit" value={line.unitId} onChange={v=>setLines(old=>old.map((x,i)=>i===index?{...x,unitId:v}:x))} options={units.map(u=>({value:u.id,label:`${u.code} · ${u.name}`}))} required/><label className="checkbox-field"><input type="checkbox" checked={line.optional} onChange={e=>setLines(old=>old.map((x,i)=>i===index?{...x,optional:e.target.checked}:x))}/><span>Optional line</span></label><Field label="Application notes" value={line.notes} onChange={v=>setLines(old=>old.map((x,i)=>i===index?{...x,notes:v}:x))}/><Button variant="ghost" disabled={lines.length===1} onClick={()=>setLines(old=>old.filter((_,i)=>i!==index))}>Remove</Button></div>)}
      <div className="form-footer"><Button variant="secondary" onClick={()=>setCreateOpen(false)}>Cancel</Button><Button type="submit" loading={busy}>{versionOf?"Create version":"Create BOM draft"}</Button></div>
    </form></Modal>:null}
  </div>;
}