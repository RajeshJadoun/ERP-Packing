import { useMemo, useState, type FormEvent } from "react";
import { useParams } from "react-router-dom";
import { Edit3, Plus, RefreshCw, Search, ToggleLeft, ToggleRight } from "lucide-react";
import { supabase } from "../lib/supabase";
import { validateCategory } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, Modal, PageHeader, SearchBox, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, selectRows, useAsyncData, safeJson } from "./shared";

type FieldDef = { key: string; label: string; kind?: "text"|"number"|"select"|"json"|"checkbox"; required?: boolean; placeholder?: string; optionsSource?: string; options?: Array<{value:string;label:string}>; hint?: string; min?: number; step?: number };
type CatalogDef = { table:string; title:string; description:string; code:string; name:string; fields:FieldDef[]; columns:Array<{key:string;label:string;render?:(row:Row)=>React.ReactNode}>; active?:boolean };

const categoryFields: FieldDef[] = [
  {key:"code",label:"Category code",required:true,placeholder:"POLY_BAG"},
  {key:"name",label:"Category name",required:true,placeholder:"Poly Bags"},
  {key:"description",label:"Description",placeholder:"Material grouping"},
  {key:"is_active",label:"Active",kind:"checkbox"}
];
const definitions: Record<string, CatalogDef> = {
  categories: {table:"material_categories",title:"Material categories",description:"Keep the catalog flexible—new material families should not require a code change.",code:"code",name:"name",active:true,fields:categoryFields,columns:[
    {key:"code",label:"Category code",render:(r)=><code className="code-chip">{r.code}</code>},
    {key:"name",label:"Category",render:(r)=><div><strong>{r.name}</strong><small>{r.description || "No description"}</small></div>},
    {key:"count",label:"Materials",render:()=> <span className="muted-text">Managed by catalog</span>},
    {key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active ? "ACTIVE":"INACTIVE"}/>}
  ]},
  materials: {table:"materials",title:"Materials catalog",description:"Define material variants, canonical units and flexible JSON specifications.",code:"material_code",name:"name",active:true,fields:[
    {key:"material_code",label:"Material code",required:true,placeholder:"POLY-8X4"},
    {key:"name",label:"Material name",required:true,placeholder:"Poly Bag 8×4"},
    {key:"category_id",label:"Category",kind:"select",optionsSource:"material_categories",required:true},
    {key:"canonical_unit_id",label:"Canonical unit",kind:"select",optionsSource:"units",required:true},
    {key:"specifications",label:"Dynamic specifications (JSON)",kind:"json",placeholder:'{"gauge":"80","widthMm":200}',hint:"Store variant attributes here; the database canonical unit stays fixed after stock activity."},
    {key:"is_active",label:"Active",kind:"checkbox"}
  ],columns:[
    {key:"material_code",label:"Material code",render:(r)=><code className="code-chip">{r.material_code}</code>},
    {key:"name",label:"Material",render:(r)=><div><strong>{r.name}</strong><small>{r.specifications ? JSON.stringify(r.specifications) : "No extra specifications"}</small></div>},
    {key:"category_id",label:"Category",render:(r)=><span>{r.category?.name ?? r.category_id?.slice(0,8) ?? "—"}</span>},
    {key:"canonical_unit_id",label:"Canonical unit",render:(r)=><span>{r.unit?.code ?? r.canonical_unit_id?.slice(0,8) ?? "—"}</span>},
    {key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>}
  ]},
  parties: {table:"parties",title:"Customer parties",description:"Maintain customers and party-specific packing context.",code:"code",name:"name",active:true,fields:[
    {key:"code",label:"Party code",required:true,placeholder:"PTY-001"},
    {key:"name",label:"Party name",required:true,placeholder:"Customer name"},
    {key:"contact_info",label:"Contact details (JSON)",kind:"json",placeholder:'{"email":"buyer@example.com"}'},
    {key:"is_active",label:"Active",kind:"checkbox"}
  ],columns:[{key:"code",label:"Party code",render:(r)=><code className="code-chip">{r.code}</code>},{key:"name",label:"Party",render:(r)=><strong>{r.name}</strong>},{key:"contact_info",label:"Contact",render:(r)=><span className="muted-text">{r.contact_info?JSON.stringify(r.contact_info):"Not provided"}</span>},{key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>} ]},
  products: {table:"products",title:"Products catalog",description:"Finished products available for BOM authoring and daily planning.",code:"sku_code",name:"name",active:true,fields:[
    {key:"sku_code",label:"SKU code",required:true,placeholder:"SKU-001"},
    {key:"name",label:"Product name",required:true,placeholder:"Product or packing kit"},
    {key:"description",label:"Description"},
    {key:"default_party_id",label:"Default party",kind:"select",optionsSource:"parties"},
    {key:"is_active",label:"Active",kind:"checkbox"}
  ],columns:[{key:"sku_code",label:"SKU",render:(r)=><code className="code-chip">{r.sku_code}</code>},{key:"name",label:"Product",render:(r)=><div><strong>{r.name}</strong><small>{r.description||"No description"}</small></div>},{key:"default_party_id",label:"Default party",render:(r)=><span>{r.party?.name ?? r.default_party_id?.slice(0,8) ?? "—"}</span>},{key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>} ]},
  vendors: {table:"vendors",title:"Vendors",description:"Maintain suppliers used by purchase orders and inward receipts.",code:"vendor_code",name:"name",active:true,fields:[
    {key:"vendor_code",label:"Vendor code",required:true,placeholder:"VEN-001"},
    {key:"name",label:"Vendor name",required:true,placeholder:"Supplier name"},
    {key:"contact_details",label:"Contact details (JSON)",kind:"json",placeholder:'{"phone":"...","email":"..."}'},
    {key:"is_active",label:"Active",kind:"checkbox"}
  ],columns:[{key:"vendor_code",label:"Vendor code",render:(r)=><code className="code-chip">{r.vendor_code}</code>},{key:"name",label:"Vendor",render:(r)=><div><strong>{r.name}</strong><small>{r.contact_details?JSON.stringify(r.contact_details):"No contact details"}</small></div>},{key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>} ]},
  locations: {table:"locations",title:"Facility locations",description:"Model shelves, receiving bays, worker custody and quarantine as explicit leaf locations.",code:"location_code",name:"name",active:true,fields:[
    {key:"location_code",label:"Location code",required:true,placeholder:"SHELF-A1"},
    {key:"name",label:"Location name",required:true,placeholder:"Shelf A-1"},
    {key:"location_type",label:"Facility type",kind:"select",required:true,options:[
      {value:"STORE_SHELF",label:"Store shelf"},{value:"RECEIVING_BAY",label:"Receiving bay"},{value:"SHOP_FLOOR_BUFFER",label:"Shop-floor buffer"},
      {value:"WORKER_CUSTODY",label:"Worker custody"},{value:"DAMAGE_QUARANTINE",label:"Damage quarantine"},{value:"DISPATCH",label:"Dispatch"}
    ]},
    {key:"parent_location_id",label:"Parent location",kind:"select",optionsSource:"locations"},
    {key:"is_leaf",label:"Leaf location",kind:"checkbox"},
    {key:"is_active",label:"Active",kind:"checkbox"}
  ],columns:[{key:"location_code",label:"Location code",render:(r)=><code className="code-chip">{r.location_code}</code>},{key:"name",label:"Location",render:(r)=><div><strong>{r.name}</strong><small>{r.location_type?.replaceAll("_"," ")}</small></div>},{key:"is_leaf",label:"Leaf",render:(r)=><Badge tone={r.is_leaf?"green":"neutral"}>{r.is_leaf?"Yes":"Parent"}</Badge>},{key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>} ]},
  workers: {table:"workers",title:"Workers & operators",description:"Assign each active worker to a dedicated custody location.",code:"worker_code",name:"name",active:true,fields:[
    {key:"worker_code",label:"Worker code",required:true,placeholder:"OP-001"},
    {key:"name",label:"Full name",required:true,placeholder:"Operator name"},
    {key:"assigned_location_id",label:"Assigned custody location",kind:"select",optionsSource:"locations",required:true},
    {key:"is_active",label:"Active",kind:"checkbox"}
  ],columns:[{key:"worker_code",label:"Worker code",render:(r)=><code className="code-chip">{r.worker_code}</code>},{key:"name",label:"Worker",render:(r)=><strong>{r.name}</strong>},{key:"assigned_location_id",label:"Custody location",render:(r)=><span>{r.location?.name ?? r.assigned_location_id?.slice(0,8) ?? "—"}</span>},{key:"is_active",label:"Status",render:(r)=><StatusBadge status={r.is_active?"ACTIVE":"INACTIVE"}/>} ]},
  units: {table:"units",title:"Units of measure",description:"Canonical quantity units supported by material records and frozen BOM snapshots.",code:"code",name:"name",fields:[
    {key:"code",label:"Unit code",required:true,placeholder:"PCS"},
    {key:"name",label:"Unit name",required:true,placeholder:"Pieces"},
    {key:"dimension",label:"Dimension",required:true,placeholder:"COUNT / MASS / LENGTH"}
  ],columns:[{key:"code",label:"Unit",render:(r)=><code className="code-chip">{r.code}</code>},{key:"name",label:"Name",render:(r)=><strong>{r.name}</strong>},{key:"dimension",label:"Dimension",render:(r)=><Badge tone="blue">{r.dimension}</Badge>} ]}
};

function initialValues(def: CatalogDef, row?: Row): Record<string, string | boolean> {
  return Object.fromEntries(def.fields.map((field) => {
    const value = row?.[field.key];
    if (field.kind === "checkbox") return [field.key, value === undefined ? true : Boolean(value)];
    if (field.kind === "json") return [field.key, value ? JSON.stringify(value, null, 2) : ""];
    return [field.key, value === null || value === undefined ? "" : String(value)];
  }));
}

export function CatalogPage({ role }: { role: string }) {
  const { resource = "categories" } = useParams();
  const [mode, setMode] = useState(resource);
  const [search, setSearch] = useState("");
  const [editorOpen, setEditorOpen] = useState(false);
  const [editing, setEditing] = useState<Row | null>(null);
  const [values, setValues] = useState<Record<string, string | boolean>>({});
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{kind:"success"|"error";text:string}|null>(null);
  const combined = resource === "parties-products" || resource === "locations-workers";
  const aliases: Record<string,string> = {"parties-products":mode === "products" ? "products":"parties","locations-workers":mode === "workers" ? "workers":"locations"};
  const key = combined ? aliases[resource] : resource;
  const def = definitions[key] ?? definitions.categories;
  const {data:records=[],loading,error,reload} = useAsyncData(async () => {
    let query = supabase.from(def.table).select("*").limit(200);
    if (def.table !== "units") query = query.order("created_at",{ascending:false});
    const {data,error} = await query;
    if (error) throw error;
    const rows = (data ?? []) as Row[];
    const ids = rows.map((r)=>r.id).filter(Boolean);
    if (!ids.length) return rows;
    if (def.table === "materials") {
      const categories = await supabase.from("material_categories").select("id,name").in("id", rows.map((r)=>r.category_id).filter(Boolean));
      const units = await supabase.from("units").select("id,code").in("id", rows.map((r)=>r.canonical_unit_id).filter(Boolean));
      return rows.map((r)=>({...r,category:categories.data?.find(x=>x.id===r.category_id),unit:units.data?.find(x=>x.id===r.canonical_unit_id)}));
    }
    if (def.table === "products") {
      const parties = await supabase.from("parties").select("id,name").in("id", rows.map((r)=>r.default_party_id).filter(Boolean));
      return rows.map((r)=>({...r,party:parties.data?.find(x=>x.id===r.default_party_id)}));
    }
    if (def.table === "workers") {
      const locs = await supabase.from("locations").select("id,name").in("id", rows.map((r)=>r.assigned_location_id).filter(Boolean));
      return rows.map((r)=>({...r,location:locs.data?.find(x=>x.id===r.assigned_location_id)}));
    }
    return rows;
  }, key);
  const canWrite = key === "categories" || key === "parties" || key === "products" || key === "units"
    ? role === "ADMIN"
    : key === "materials" || key === "vendors" || key === "locations" || key === "workers"
      ? ["ADMIN","STOREKEEPER"].includes(role)
      : ["ADMIN","STOREKEEPER"].includes(role);
  const lookupTables = Array.from(new Set(def.fields.map((f)=>f.optionsSource).filter(Boolean))) as string[];
  const {data:lookups={}} = useAsyncData(async () => {
    const entries = await Promise.all(lookupTables.map(async (table) => {
      const {data,error} = await supabase.from(table).select("*").limit(250);
      if (error) throw error;
      return [table, (data ?? []) as Row[]] as const;
    }));
    return Object.fromEntries(entries);
  }, lookupTables.join("|"));
  const filtered = useMemo(()=>records.filter((row)=>def.fields.some((f)=>String(row[f.key] ?? "").toLowerCase().includes(search.toLowerCase()))),[records,def,search]);
  const options = (field:FieldDef) => {
    if(field.options) return field.options;
    const table=field.optionsSource;
    return (lookups[table ?? ""] ?? []).map((r:Row)=>({value:String(r.id),label:String(r.name ?? r.code ?? r.location_code ?? r.unit_code ?? r.id)}));
  };
  const startCreate = () => {setEditing(null);setValues(initialValues(def));setMessage(null);setEditorOpen(true);};
  const startEdit = (row:Row) => {setEditing(row);setValues(initialValues(def,row));setMessage(null);setEditorOpen(true);};
  const submit = async (event:FormEvent) => {
    event.preventDefault(); if(!canWrite) return;
    setBusy(true);setMessage(null);
    try {
      if (key==="categories") {
        const error=validateCategory(String(values.code ?? ""),String(values.name ?? ""));
        if(error) throw new Error(error);
      }
      const payload:Record<string,unknown>={};
      for(const field of def.fields){
        const raw=values[field.key];
        if(field.kind==="checkbox") payload[field.key]=Boolean(raw);
        else if(field.kind==="json") payload[field.key]=String(raw ?? "").trim()?safeJson(String(raw),field.label):null;
        else if(field.kind==="number") payload[field.key]=raw===""?null:Number(raw);
        else payload[field.key]=typeof raw==="string"?raw.trim()||null:raw;
      }
      const query = editing ? supabase.from(def.table).update(payload).eq("id",editing.id) : supabase.from(def.table).insert(payload);
      const {error}=await query;
      if(error) throw error;
      setMessage({kind:"success",text:editing?"Record updated.":"Record created."});
      setEditorOpen(false);reload();
    } catch(reason) {setMessage({kind:"error",text:reason instanceof Error?reason.message:"The record could not be saved."});}
    finally {setBusy(false);}
  };
  const toggleActive = async (row:Row) => {
    if(!def.active) return;
    setBusy(true);setMessage(null);
    const {error}=await supabase.from(def.table).update({is_active:!row.is_active}).eq("id",row.id);
    if(error) setMessage({kind:"error",text:error.message}); else {setMessage({kind:"success",text:`${row.name ?? row[def.code]} is now ${!row.is_active?"active":"inactive"}.`});reload();}
    setBusy(false);
  };
  const columns=[...def.columns,{key:"actions",label:"",render:(row:Row)=><div className="row-actions">{canWrite?<button className="icon-button small-icon" aria-label={`Edit ${row[def.name] ?? row[def.code]}`} onClick={(e)=>{e.stopPropagation();startEdit(row);}}><Edit3 size={15}/></button>:null}{def.active&&canWrite?<button className="icon-button small-icon" aria-label={`Toggle active ${row[def.name] ?? row[def.code]}`} onClick={(e)=>{e.stopPropagation();void toggleActive(row);}}>{row.is_active?<ToggleRight size={17}/>:<ToggleLeft size={17}/>}</button>:null}</div>}];
  const title = combined ? (resource==="parties-products"?"Parties & products":"Locations & workers") : def.title;
  return <div className="page-stack">
    <PageHeader eyebrow="MASTER DATA" title={title} description={combined?"Manage linked operational master records while preserving database constraints.":def.description} actions={canWrite?<Button onClick={startCreate}><Plus size={16}/> Add record</Button>:undefined}/>
    {message ? <Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert> : null}
    {error ? <Alert kind="error">{error}</Alert>:null}
    {combined ? <div className="segmented-tabs">{(resource==="parties-products"?["parties","products"]:["locations","workers"]).map((item)=><button key={item} className={mode===item?"selected":""} onClick={()=>setMode(item)}>{item.replaceAll("-"," ")}</button>)}</div>:null}
    <Card padding={false}><div className="table-toolbar"><Toolbar><SearchBox value={search} onChange={setSearch}/><span className="table-count">{filtered.length} records</span><Button variant="ghost" onClick={reload}><RefreshCw size={15}/> Refresh</Button></Toolbar></div>
      {loading ? <div className="padded"><span className="muted-text">Loading catalog…</span></div>:<DataTable rows={filtered} columns={columns} rowKey={(row)=>String(row.id)} emptyTitle="Catalog is empty" emptyDescription="Add the first master record to begin."/>}
    </Card>
    {editorOpen ? <Modal title={editing?"Edit record":`Add ${def.title.toLowerCase().replace(/s$/,"")}`} description="Changes are submitted through Supabase RLS; database rules remain authoritative." onClose={()=>setEditorOpen(false)} wide><form className="form-grid" onSubmit={submit}>
      {def.fields.map((field)=><div className={field.kind==="json"?"span-2":""} key={field.key}>
        {field.kind==="select"?<SelectField label={field.label} value={String(values[field.key]??"")} onChange={(v)=>setValues((x)=>({...x,[field.key]:v}))} options={options(field)} required={field.required} placeholder="Select an option"/>:
        field.kind==="json"?<TextArea label={field.label} value={String(values[field.key]??"")} onChange={(v)=>setValues((x)=>({...x,[field.key]:v}))} rows={5} placeholder={field.placeholder} hint={field.hint}/>:
        field.kind==="checkbox"?<label className="checkbox-field"><input type="checkbox" checked={Boolean(values[field.key])} onChange={(e)=>setValues((x)=>({...x,[field.key]:e.target.checked}))}/><span>{field.label}</span></label>:
        <Field label={field.label} value={String(values[field.key]??"")} onChange={(v)=>setValues((x)=>({...x,[field.key]:v}))} type={field.kind==="number"?"number":"text"} min={field.min} step={field.step} placeholder={field.placeholder} required={field.required}/>}
      </div>)}
      <div className="form-footer span-2"><Button variant="secondary" onClick={()=>setEditorOpen(false)}>Cancel</Button><Button type="submit" loading={busy}>{editing?"Save changes":"Create record"}</Button></div>
    </form></Modal>:null}
  </div>;
}