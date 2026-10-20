import { useState, type FormEvent } from "react";
import { AlertTriangle, ArrowDownToLine, CheckCircle2, FileText, Plus, Receipt, RefreshCw, Truck } from "lucide-react";
import { supabase } from "../lib/supabase";
import { apiPost } from "../lib/api";
import { Alert, Badge, Button, Card, DataTable, Field, PageHeader, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, displayDate, selectRows, useAsyncData } from "./shared";

type LineDraft={materialId:string;quantity:string;unitId:string;price:string};
const freshLine=():LineDraft=>({materialId:"",quantity:"1",unitId:"",price:"0"});

export function PurchasingPage({ role }: { role:string }) {
  const [tab,setTab]=useState<"orders"|"receipts">("orders");
  const [createMode,setCreateMode]=useState<"po"|"grn"|null>(null);
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState<{kind:"success"|"error";text:string}|null>(null);
  const [vendors,setVendors]=useState<string>("");
  const [orderDate,setOrderDate]=useState(new Date().toISOString().slice(0,10));
  const [deliveryDate,setDeliveryDate]=useState(new Date(Date.now()+7*86400000).toISOString().slice(0,10));
  const [poNumber,setPoNumber]=useState(`PO-${new Date().toISOString().slice(0,10).replaceAll("-","")}-001`);
  const [poNotes,setPoNotes]=useState("");
  const [poLines,setPoLines]=useState<LineDraft[]>([freshLine()]);
  const [grnVendor,setGrnVendor]=useState("");
  const [poId,setPoId]=useState("");
  const [invoice,setInvoice]=useState("");
  const [invoiceDate,setInvoiceDate]=useState(new Date().toISOString().slice(0,10));
  const [receivedDate,setReceivedDate]=useState(new Date().toISOString().slice(0,10));
  const [locationId,setLocationId]=useState("");
  const [grnMaterial,setGrnMaterial]=useState("");
  const [enteredQty,setEnteredQty]=useState("1");
  const [enteredUnit,setEnteredUnit]=useState("");
  const [rejectedQty,setRejectedQty]=useState("0");
  const [rejectedUnit,setRejectedUnit]=useState("");
  const [boxCount,setBoxCount]=useState("");
  const [weightKg,setWeightKg]=useState("");
  const [pcsCount,setPcsCount]=useState("");
  const [lotNumber,setLotNumber]=useState("");
  const [remarks,setRemarks]=useState("");
  const [preview,setPreview]=useState<{accepted:number;canonical:number;unit:string;estimated:boolean;factor:number;direction:string}|null>(null);

  const masters=useAsyncData(async()=>{
    const [v,m,u,l,p,grn]=await Promise.all([
      selectRows("vendors","id,vendor_code,name,is_active","name",500),
      selectRows("materials","id,material_code,name,canonical_unit_id,is_active","name",500),
      selectRows("units","id,code,name,dimension","code",250),
      selectRows("locations","id,location_code,name,location_type,is_leaf,is_active","location_code",500),
      selectRows("purchase_orders","id,po_number,vendor_id,order_date,expected_delivery_date,status,remarks,purchase_order_lines(id,material_id,ordered_quantity,received_quantity,unit_id,unit_price)","order_date",500),
      selectRows("goods_receipts","id,grn_number,vendor_id,po_id,invoice_number,invoice_date,received_date,destination_location_id,status,posted_at,created_at","created_at",500)
    ]);
    return {vendors:v,materials:m,units:u,locations:l,pos:p,grns:grn};
  },role);
  const {vendors:vendorRows=[],materials:materialRows=[],units:unitRows=[],locations:locationRows=[],pos=[],grns=[]}=masters.data??{};
  const activeVendors=vendorRows.filter((x)=>x.is_active);
  const activeMaterials=materialRows.filter((x)=>x.is_active);
  const leafLocations=locationRows.filter((x)=>x.is_active&&x.is_leaf);
  const shelfLocations=leafLocations.filter((x)=>["STORE_SHELF","RECEIVING_BAY"].includes(x.location_type));
  const postable=role==="ADMIN"||role==="STOREKEEPER";

  const submitPO=async(e:FormEvent)=>{
    e.preventDefault();setBusy(true);setMessage(null);
    try{
      if(!vendors)throw new Error("Choose a vendor.");
      if(orderDate>deliveryDate)throw new Error("Expected delivery cannot be earlier than the order date.");
      const lines=poLines.filter(l=>l.materialId&&l.unitId&&Number(l.quantity)>0);
      if(lines.length===0)throw new Error("Add at least one complete purchase-order line.");
      const result=await apiPost<Row>("/purchase-orders",{poNumber, vendorId:vendors,orderDate,expectedDeliveryDate:deliveryDate,notes:poNotes||null,lines:lines.map(l=>({materialId:l.materialId,orderedQuantity:Number(l.quantity),unitId:l.unitId,unitPrice:Number(l.price||0)}))});
      setMessage({kind:"success",text:`Purchase order ${result.poNumber??result.id} created as a draft.`});
      setCreateMode(null);setPoLines([freshLine()]);setPoNotes("");masters.reload();
    }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not create purchase order."});}finally{setBusy(false);}
  };

  const preparePreview=async()=>{
    setPreview(null);
    const material=activeMaterials.find(m=>m.id===grnMaterial);
    if(!material||!enteredUnit||Number(enteredQty)<=0)return;
    const entered=Number(enteredQty), rejected=Number(rejectedQty||0);
    if(enteredUnit!==rejectedUnit&&rejected>0)throw new Error("For a draft GRN, received and rejected quantities must use the same unit. The server recalculates accepted quantity on posting.");
    const accepted=entered-rejected;
    if(accepted<0)throw new Error("Rejected quantity cannot exceed entered quantity.");
    const canonicalUnit=String(material.canonical_unit_id);
    if(enteredUnit===canonicalUnit){setPreview({accepted,canonical:accepted,unit:unitRows.find(u=>u.id===canonicalUnit)?.code??"canonical",estimated:false,factor:1,direction:"NONE"});return;}
    const {data:direct}=await supabase.from("material_conversions").select("id,conversion_factor,is_exact,from_unit_id,to_unit_id").eq("material_id",grnMaterial).eq("from_unit_id",enteredUnit).eq("to_unit_id",canonicalUnit).is("effective_to",null).order("effective_from",{ascending:false}).limit(1).maybeSingle();
    if(direct){const factor=Number(direct.conversion_factor);setPreview({accepted,canonical:accepted*factor,unit:unitRows.find(u=>u.id===canonicalUnit)?.code??"canonical",estimated:!direct.is_exact,factor,direction:"MULTIPLY"});return;}
    const {data:inverse}=await supabase.from("material_conversions").select("id,conversion_factor,is_exact").eq("material_id",grnMaterial).eq("from_unit_id",canonicalUnit).eq("to_unit_id",enteredUnit).is("effective_to",null).order("effective_from",{ascending:false}).limit(1).maybeSingle();
    if(inverse){const factor=Number(inverse.conversion_factor);setPreview({accepted,canonical:accepted/factor,unit:unitRows.find(u=>u.id===canonicalUnit)?.code??"canonical",estimated:!inverse.is_exact,factor,direction:"DIVIDE"});return;}
    throw new Error("No current conversion rule connects this entered unit to the material’s canonical unit. Choose the canonical unit or add a conversion rule first.");
  };

  const createGRN=async(e:FormEvent)=>{
    e.preventDefault();setBusy(true);setMessage(null);
    try{
      await preparePreview();
      const material=activeMaterials.find(m=>m.id===grnMaterial);
      if(!material)throw new Error("Choose a material.");
      const entered=Number(enteredQty),rejected=Number(rejectedQty||0),accepted=entered-rejected;
      if(accepted<=0)throw new Error("Accepted quantity must be greater than zero.");
      if(!grnVendor||!locationId||!invoice.trim())throw new Error("Vendor, receiving location and invoice number are required.");
      // Preliminary conversion is stored only on the draft. Posting RPC recomputes authoritative values.
      let factor=1, direction="NONE", isEstimated=false, conversionRuleId:string|null=null, canonical=accepted;
      if(enteredUnit!==material.canonical_unit_id){
        const {data:direct}=await supabase.from("material_conversions").select("id,conversion_factor,is_exact").eq("material_id",grnMaterial).eq("from_unit_id",enteredUnit).eq("to_unit_id",material.canonical_unit_id).is("effective_to",null).order("effective_from",{ascending:false}).limit(1).maybeSingle();
        if(direct){factor=Number(direct.conversion_factor);direction="MULTIPLY";isEstimated=!direct.is_exact;conversionRuleId=direct.id;canonical=accepted*factor;}
        else{
          const {data:inverse}=await supabase.from("material_conversions").select("id,conversion_factor,is_exact").eq("material_id",grnMaterial).eq("from_unit_id",material.canonical_unit_id).eq("to_unit_id",enteredUnit).is("effective_to",null).order("effective_from",{ascending:false}).limit(1).maybeSingle();
          if(!inverse)throw new Error("No conversion rule found. Select the canonical unit or create a conversion rule.");
          factor=Number(inverse.conversion_factor);direction="DIVIDE";isEstimated=!inverse.is_exact;conversionRuleId=inverse.id;canonical=accepted/factor;
        }
      }
      const grnNumber=`GRN-${new Date().toISOString().slice(0,10).replaceAll("-","")}-${Math.random().toString(36).slice(2,7).toUpperCase()}`;
      const {data:header,error:headerError}=await supabase.from("goods_receipts").insert({grn_number:grnNumber,vendor_id:grnVendor,po_id:poId||null,invoice_number:invoice.trim(),invoice_date:invoiceDate,received_date:receivedDate,destination_location_id:locationId,status:"DRAFT",remarks:remarks.trim()||null}).select("id,grn_number").single();
      if(headerError)throw headerError;
      const line={grn_id:header.id,purchase_order_line_id:null,material_id:grnMaterial,entered_qty:entered,entered_unit_id:enteredUnit,rejected_qty:rejected,rejected_unit_id:rejectedUnit,accepted_qty:accepted,canonical_quantity:canonical,canonical_unit_id:material.canonical_unit_id,box_count:boxCount?Number(boxCount):null,weight_kg:weightKg?Number(weightKg):null,pcs_count:pcsCount?Number(pcsCount):null,conversion_rule_id:conversionRuleId,conversion_factor_used:factor,conversion_direction:direction,conversion_type_used:isEstimated?"ESTIMATED":"EXACT",is_estimated_conversion:isEstimated,batch_lot_number:lotNumber.trim()||null};
      const {error:lineError}=await supabase.from("goods_receipt_lines").insert(line);
      if(lineError){await supabase.from("goods_receipts").delete().eq("id",header.id);throw lineError;}
      setMessage({kind:"success",text:`Draft ${header.grn_number} saved. Preview values are provisional; the database recomputes canonical quantities when it is posted.`});
      setCreateMode(null);setPreview(null);setRemarks("");masters.reload();
    }catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Could not save the draft receipt."});}finally{setBusy(false);}
  };
  const postGRN=async(row:Row)=>{
    if(!postable)return;setBusy(true);setMessage(null);
    try{const result=await apiPost<Row>("/goods-receipts/post",{goodsReceiptId:row.id});setMessage({kind:"success",text:`${result.goodsReceiptId??row.grn_number} posted. Canonical quantities and ledger transactions were confirmed by the server.`});masters.reload();}
    catch(error){setMessage({kind:"error",text:error instanceof Error?error.message:"Goods receipt could not be posted."});}finally{setBusy(false);}
  };
  const poColumns=[
    {key:"po_number",label:"PO number",render:(r:Row)=><div><strong>{r.po_number}</strong><small>{displayDate(r.order_date)}</small></div>},
    {key:"vendor_id",label:"Vendor",render:(r:Row)=>vendorRows.find(v=>v.id===r.vendor_id)?.name??String(r.vendor_id).slice(0,8)},
    {key:"lines",label:"Lines",render:(r:Row)=><Badge tone="blue">{(r.purchase_order_lines??[]).length} items</Badge>},
    {key:"total",label:"Order value",render:(r:Row)=>new Intl.NumberFormat("en-IN",{style:"currency",currency:"INR",maximumFractionDigits:0}).format((r.purchase_order_lines??[]).reduce((s: number,l:Row)=>s+Number(l.ordered_quantity??0)*Number(l.unit_price??0),0))},
    {key:"expected_delivery_date",label:"Expected",render:(r:Row)=>displayDate(r.expected_delivery_date)},
    {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>}
  ];
  const grnColumns=[
    {key:"grn_number",label:"Receipt",render:(r:Row)=><div><strong>{r.grn_number}</strong><small>Invoice {r.invoice_number}</small></div>},
    {key:"vendor_id",label:"Vendor",render:(r:Row)=>vendorRows.find(v=>v.id===r.vendor_id)?.name??String(r.vendor_id).slice(0,8)},
    {key:"received_date",label:"Received",render:(r:Row)=>displayDate(r.received_date)},
    {key:"destination_location_id",label:"Receiving location",render:(r:Row)=>locationRows.find(l=>l.id===r.destination_location_id)?.location_code??String(r.destination_location_id).slice(0,8)},
    {key:"status",label:"Status",render:(r:Row)=><StatusBadge status={r.status}/>},
    {key:"actions",label:"Action",render:(r:Row)=>r.status==="DRAFT"?<Button variant="success" onClick={()=>void postGRN(r)} loading={busy}><ArrowDownToLine size={14}/> Post GRN</Button>:<span className="muted-text">{r.posted_at?displayDate(r.posted_at):"Posted"}</span>}
  ];
  return <div className="page-stack"><PageHeader eyebrow="PROCUREMENT" title="Purchasing & inward receipts" description="Create purchase orders, record dock measurements and post accepted quantities through a transactional GRN workflow." actions={<Button onClick={()=>setCreateMode(tab==="orders"?"po":"grn")}><Plus size={16}/>{tab==="orders"?"New purchase order":"New inward receipt"}</Button>}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}
    {masters.error?<Alert kind="error">{masters.error}</Alert>:null}
    <div className="metric-grid metric-grid-four"><Card className="mini-metric"><div className="mini-metric-icon"><FileText size={17}/></div><span>Purchase orders</span><strong>{pos.length}</strong><small>{pos.filter(p=>p.status==="DRAFT").length} drafts awaiting follow-up</small></Card><Card className="mini-metric"><div className="mini-metric-icon"><Receipt size={17}/></div><span>Inward receipts</span><strong>{grns.length}</strong><small>{grns.filter(g=>g.status==="DRAFT").length} drafts ready to post</small></Card><Card className="mini-metric"><div className="mini-metric-icon green-mini"><CheckCircle2 size={17}/></div><span>Posted receipts</span><strong>{grns.filter(g=>g.status==="POSTED").length}</strong><small>Ledger-confirmed receipts</small></Card><Card className="mini-metric"><div className="mini-metric-icon amber-mini"><Truck size={17}/></div><span>Active vendors</span><strong>{activeVendors.length}</strong><small>Supplier master records</small></Card></div>
    <Card padding={false}><div className="panel-tabs"><button className={tab==="orders"?"selected":""} onClick={()=>{setTab("orders");setCreateMode(null);}}>Purchase orders <span>{pos.length}</span></button><button className={tab==="receipts"?"selected":""} onClick={()=>{setTab("receipts");setCreateMode(null);}}>Inward GRNs <span>{grns.length}</span></button></div>
      <div className="table-toolbar"><Toolbar><span className="table-count">{tab==="orders"?pos.length:grns.length} records</span><Button variant="ghost" onClick={masters.reload}><RefreshCw size={15}/> Refresh</Button></Toolbar></div>
      {tab==="orders"?<DataTable rows={pos} columns={poColumns} rowKey={(r)=>String(r.id)} emptyTitle="No purchase orders yet" emptyDescription="Create a purchase order before arranging an inward receipt."/>:<DataTable rows={grns} columns={grnColumns} rowKey={(r)=>String(r.id)} emptyTitle="No inward receipts" emptyDescription="Create a draft receipt from an invoice, then post it to the stock ledger."/>}
    </Card>
    {createMode==="po"?<Card><div className="panel-heading"><div><div className="eyebrow">NEW PURCHASE ORDER</div><h2>Order materials from a vendor</h2><p>Creates a draft PO only; it does not change stock.</p></div><Button variant="ghost" onClick={()=>setCreateMode(null)}>Cancel</Button></div>
      <form className="page-stack compact-stack" onSubmit={submitPO}><div className="form-grid"><Field label="PO number" value={poNumber} onChange={setPoNumber} required/><SelectField label="Vendor" value={vendors} onChange={setVendors} options={activeVendors.map(v=>({value:v.id,label:`${v.vendor_code} · ${v.name}`}))} required/><Field label="Order date" value={orderDate} onChange={setOrderDate} type="date" required/><Field label="Expected delivery" value={deliveryDate} onChange={setDeliveryDate} type="date" required/></div>
        <div className="line-editor-head"><h3>Order lines</h3><Button variant="secondary" onClick={()=>setPoLines(old=>[...old,freshLine()])}><Plus size={14}/> Add line</Button></div>
        {poLines.map((line,index)=><div className="line-editor" key={index}><SelectField label="Material" value={line.materialId} onChange={(v)=>setPoLines(old=>old.map((x,i)=>i===index?{...x,materialId:v}:x))} options={activeMaterials.map(m=>({value:m.id,label:`${m.material_code} · ${m.name}`}))} required/><Field label="Ordered quantity" value={line.quantity} onChange={(v)=>setPoLines(old=>old.map((x,i)=>i===index?{...x,quantity:v}:x))} type="number" min={0.000001} step="any" required/><SelectField label="Unit" value={line.unitId} onChange={(v)=>setPoLines(old=>old.map((x,i)=>i===index?{...x,unitId:v}:x))} options={unitRows.map(u=>({value:u.id,label:`${u.code} · ${u.name}`}))} required/><Field label="Unit price (₹)" value={line.price} onChange={(v)=>setPoLines(old=>old.map((x,i)=>i===index?{...x,price:v}:x))} type="number" min={0} step="any" required/><Button variant="ghost" onClick={()=>setPoLines(old=>old.filter((_,i)=>i!==index))} disabled={poLines.length===1}>Remove</Button></div>)}
        <TextArea label="Notes" value={poNotes} onChange={setPoNotes} rows={2} placeholder="Delivery or purchasing notes"/><div className="form-footer"><Button variant="secondary" onClick={()=>setCreateMode(null)}>Cancel</Button><Button type="submit" loading={busy} disabled={!postable}>Create draft PO</Button></div>
      </form>
    </Card>:null}
    {createMode==="grn"?<Card><div className="panel-heading"><div><div className="eyebrow">NEW INWARD RECEIPT</div><h2>Record the supplier delivery</h2><p>Draft calculations are provisional; the posting RPC recalculates accepted and canonical quantities.</p></div><Button variant="ghost" onClick={()=>setCreateMode(null)}>Cancel</Button></div>
      <form className="page-stack compact-stack" onSubmit={createGRN}><div className="form-grid"><SelectField label="Vendor" value={grnVendor} onChange={setGrnVendor} options={activeVendors.map(v=>({value:v.id,label:`${v.vendor_code} · ${v.name}`}))} required/><SelectField label="Linked purchase order (optional)" value={poId} onChange={setPoId} options={pos.filter(p=>p.vendor_id===grnVendor&&p.status!=="CANCELLED").map(p=>({value:p.id,label:p.po_number}))}/><Field label="Invoice number" value={invoice} onChange={setInvoice} required/><SelectField label="Receiving location" value={locationId} onChange={setLocationId} options={shelfLocations.map(l=>({value:l.id,label:`${l.location_code} · ${l.name}`}))} required/><Field label="Invoice date" value={invoiceDate} onChange={setInvoiceDate} type="date" required/><Field label="Received date" value={receivedDate} onChange={setReceivedDate} type="date" required/></div>
      <div className="line-editor-head"><h3>Delivery measurement</h3><Badge tone="blue">1 line per draft</Badge></div><div className="form-grid"><SelectField label="Material" value={grnMaterial} onChange={(v)=>{setGrnMaterial(v);const m=activeMaterials.find(x=>x.id===v);setEnteredUnit(m?.canonical_unit_id??"");setRejectedUnit(m?.canonical_unit_id??"");setPreview(null);}} options={activeMaterials.map(m=>({value:m.id,label:`${m.material_code} · ${m.name}`}))} required/><Field label="Entered quantity" value={enteredQty} onChange={(v)=>{setEnteredQty(v);setPreview(null);}} type="number" min={0.000001} step="any" required/><SelectField label="Entered unit" value={enteredUnit} onChange={(v)=>{setEnteredUnit(v);setPreview(null);}} options={unitRows.map(u=>({value:u.id,label:`${u.code} · ${u.name}`}))} required/><Field label="Rejected quantity" value={rejectedQty} onChange={(v)=>{setRejectedQty(v);setPreview(null);}} type="number" min={0} step="any" required/><SelectField label="Rejected unit" value={rejectedUnit} onChange={setRejectedUnit} options={unitRows.map(u=>({value:u.id,label:`${u.code} · ${u.name}`}))} required/><Field label="Box / bundle count" value={boxCount} onChange={setBoxCount} type="number" min={0} step={1}/><Field label="Physical weight (kg)" value={weightKg} onChange={setWeightKg} type="number" min={0} step="any"/><Field label="Secondary piece count (estimate)" value={pcsCount} onChange={setPcsCount} type="number" min={0} step="any"/><Field label="Batch / lot number" value={lotNumber} onChange={setLotNumber}/></div>
      {preview?<div className="dual-unit-preview"><div><span>Accepted quantity</span><strong>{preview.accepted.toLocaleString("en-IN",{maximumFractionDigits:3})}</strong></div><ArrowDownToLine size={18}/><div><span>Canonical quantity preview</span><strong>{preview.canonical.toLocaleString("en-IN",{maximumFractionDigits:3})} {preview.unit}</strong><small>{preview.estimated?"Estimated conversion":"Exact conversion"} · factor {preview.factor} · {preview.direction}</small></div><Badge tone="amber">Provisional</Badge></div>:<div className="form-note"><AlertTriangle size={15}/>Use the preview to check units. Posted canonical quantities are recalculated by PostgreSQL, never trusted from this browser.</div>}
      <Button variant="secondary" onClick={async()=>{try{await preparePreview();}catch(e){setMessage({kind:"error",text:e instanceof Error?e.message:"Preview failed."});}}}><RefreshCw size={14}/> Preview dual units</Button><TextArea label="Receipt notes" value={remarks} onChange={setRemarks} rows={2}/><div className="form-footer"><Button variant="secondary" onClick={()=>setCreateMode(null)}>Cancel</Button><Button type="submit" loading={busy} disabled={!postable}>Save draft GRN</Button></div>
      </form>
    </Card>:null}
    <div className="info-footnote"><ArrowDownToLine size={15}/><span>Posting a GRN is the only step here that credits usable stock. Drafts remain editable only through allowed draft operations and are recalculated server-side at posting.</span></div>
  </div>;
}