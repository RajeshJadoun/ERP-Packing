import { useMemo, useState, type FormEvent } from "react";
import { ArrowLeft, CheckCircle2, ClipboardCheck, RefreshCw, ShieldAlert } from "lucide-react";
import { useNavigate, useParams } from "react-router-dom";
import { apiGet, apiPost } from "../lib/api";
import { formatQuantity, variancePreview } from "../lib/domain";
import { Alert, Badge, Button, Card, DataTable, Field, PageHeader, SelectField, StatusBadge, TextArea } from "../components/ui";
import { Row, useAsyncData } from "./shared";

type UsageDraft = { quantity: string; method: string; evidence: string };

export function ConsumptionVerificationPage({ role }: { role: string }) {
  const { id = "" } = useParams();
  const navigate = useNavigate();
  const [drafts, setDrafts] = useState<Record<string, UsageDraft>>({});
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{kind:"success"|"error";text:string}|null>(null);
  const [saved, setSaved] = useState<Row|null>(null);
  const state = useAsyncData(() => apiGet<Row>("/production/completions/" + id), id);
  const completion = state.data;
  const consumptions: Row[] = completion?.consumptions ?? [];
  const unverified = consumptions.filter(row => row.varianceStatus === "UNVERIFIED");
  const allUnverified = consumptions.length > 0 && unverified.length === consumptions.length;
  const canVerify = ["ADMIN","OPERATOR","PLANNER"].includes(role);
  const ready = allUnverified && consumptions.every(row => {
    const value = drafts[row.materialId]?.quantity;
    return value !== undefined && value.trim() !== "" && Number.isFinite(Number(value)) && Number(value) >= 0;
  });
  const setDraft = (materialId: string, patch: Partial<UsageDraft>) => setDrafts(old => ({
    ...old,
    [materialId]: { quantity:"", method:"MANUALLY_COUNTED", evidence:"", ...old[materialId], ...patch }
  }));
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true); setMessage(null); setSaved(null);
    try {
      if (!completion || !allUnverified) throw new Error("This completion is no longer fully unverified. Refresh and review the saved counts.");
      const actualMaterialUsage = consumptions.map((row) => {
        const draft = drafts[row.materialId];
        if (!draft || draft.quantity.trim() === "" || !Number.isFinite(Number(draft.quantity)) || Number(draft.quantity) < 0) {
          throw new Error("Enter a non-negative physical count for material " + String(row.materialId).slice(0,8) + ".");
        }
        if (draft.evidence.length > 500) throw new Error("Evidence must be 500 characters or fewer.");
        return {
          materialId: row.materialId,
          physicallyConfirmedQuantity: Number(draft.quantity),
          unitId: row.canonicalUnitId,
          measurementMethod: draft.method,
          measurementEvidence: draft.evidence.trim() || null
        };
      });
      const result = await apiPost<Row>("/production/completions/" + completion.id + "/consumption/verify", { actualMaterialUsage });
      setSaved(result);
      setMessage({kind:"success",text:"Physical counts saved. The original theoretical stock ledger was not rewritten."});
      state.reload();
    } catch (error) {
      setMessage({kind:"error",text:error instanceof Error?error.message:"Consumption verification failed."});
    } finally { setBusy(false); }
  };
  const reviewColumns = useMemo(() => [
    {key:"materialId",label:"Material",render:(row:Row)=><div><strong>{String(row.materialId).slice(0,8)}</strong><small>Unit {String(row.canonicalUnitId??row.physicallyConfirmedUnitId??"—").slice(0,8)}</small></div>},
    {key:"theoreticalQuantity",label:"Theoretical",render:(row:Row)=>formatQuantity(row.theoreticalQuantity)},
    {key:"postedLedgerQuantity",label:"Ledger posted",render:(row:Row)=>formatQuantity(row.postedLedgerQuantity)},
    {key:"physicallyConfirmedQuantity",label:"Physical count",render:(row:Row)=>row.physicallyConfirmedQuantity==null?<Badge tone="amber">Not measured</Badge>:formatQuantity(row.physicallyConfirmedQuantity)},
    {key:"varianceQuantity",label:"Variance",render:(row:Row)=>row.varianceQuantity==null?"—":<strong className={Number(row.varianceQuantity)===0?"success-text":"danger-text"}>{formatQuantity(row.varianceQuantity)}</strong>},
    {key:"varianceStatus",label:"State",render:(row:Row)=><StatusBadge status={row.varianceStatus}/>}
  ], []);
  if (state.loading) return <div className="page-stack"><PageHeader eyebrow="MATERIAL RECONCILIATION" title="Verify physical consumption"/><Card><div className="padded">Loading completion detail…</div></Card></div>;
  if (state.error || !completion) return <div className="page-stack"><PageHeader eyebrow="MATERIAL RECONCILIATION" title="Verify physical consumption"/><Alert kind="error">{state.error || "Production completion not found."}</Alert><Button variant="secondary" onClick={()=>navigate(-1)}><ArrowLeft size={15}/> Back</Button></div>;
  return <div className="page-stack">
    <PageHeader eyebrow="MATERIAL RECONCILIATION" title="Verify physical consumption" description="Record physical counts for this batch in the frozen canonical units." actions={<><Button variant="secondary" onClick={state.reload}><RefreshCw size={15}/> Refresh</Button><Button variant="secondary" onClick={()=>navigate("/daily-plans/jobs/"+completion.packingJobId)}><ArrowLeft size={15}/> Back to job</Button></>}/>
    {message?<Alert kind={message.kind} onClose={()=>setMessage(null)}>{message.text}</Alert>:null}
    <Card><div className="job-detail-head"><div><div className="eyebrow">PRODUCTION COMPLETION</div><h2>{completion.completionNumber??String(completion.id).slice(0,8)}</h2><p>{formatQuantity(completion.completedUnits,0)} units packed · {completion.completionPolicy==="AUTO_BOM_THEORETICAL"?"Estimated theoretical backflush":"Physical entry at completion"}</p></div><StatusBadge status={allUnverified?"UNVERIFIED":unverified.length?"UNVERIFIED":consumptions.some(row=>row.varianceStatus==="VARIANCE_RECORDED")?"VARIANCE_RECORDED":"VERIFIED_ZERO"}/></div>
      <div className="closing-summary"><div><span>Packed units</span><strong>{formatQuantity(completion.completedUnits,0)}</strong></div><div><span>Material lines</span><strong>{consumptions.length}</strong></div><div><span>Awaiting count</span><strong className={unverified.length?"warning-text":"success-text"}>{unverified.length}</strong></div><div><span>Recorded variance lines</span><strong>{consumptions.filter(row=>row.varianceStatus==="VARIANCE_RECORDED").length}</strong></div></div>
    </Card>
    {allUnverified&&canVerify?<form className="page-stack" onSubmit={submit}><Card><div className="panel-heading"><div><h2>Physical count worksheet</h2><p>Every material must be measured exactly once. Partial verification is not accepted.</p></div><Badge tone="amber">{consumptions.length} unverified</Badge></div>
      <div className="consumption-list">{consumptions.map((row:Row)=>{
        const draft=drafts[row.materialId]??{quantity:"",method:"MANUALLY_COUNTED",evidence:""};
        const preview=variancePreview(draft.quantity,row.theoreticalQuantity);
        return <div className="consumption-line" key={row.materialId}><div className="consumption-line-head"><div><strong>Material {String(row.materialId).slice(0,8)}</strong><small>Canonical unit {String(row.canonicalUnitId).slice(0,8)} · transaction {String(row.stockTransactionId).slice(0,8)}</small></div><div className="theory-number"><span>Theoretical</span><strong>{formatQuantity(row.theoreticalQuantity)}</strong></div></div>
          <div className="form-grid"><Field label="Physically confirmed quantity" value={draft.quantity} onChange={value=>setDraft(row.materialId,{quantity:value})} type="number" min={0} step="any" required/><SelectField label="Measurement method" value={draft.method} onChange={value=>setDraft(row.materialId,{method:value})} options={[{value:"SCALE_WEIGHED",label:"Scale weighed"},{value:"SEALED_BUNDLE",label:"Sealed bundle"},{value:"MANUALLY_COUNTED",label:"Manually counted"}]} required/><div className="span-2"><TextArea label="Evidence / scale-slip reference" value={draft.evidence} onChange={value=>setDraft(row.materialId,{evidence:value})} rows={2} hint="Optional, maximum 500 characters."/></div><div className="variance-preview"><span>Live variance</span><strong className={preview.status==="VERIFIED_ZERO"?"success-text":"warning-text"}>{preview.variance===null?"—":formatQuantity(preview.variance)}</strong><StatusBadge status={preview.status}/></div></div>
        </div>;
      })}</div>
      <div className="info-footnote padded"><ShieldAlert size={15}/><span>Saving records evidence and an audit trail without changing the immutable theoretical stock transaction.</span></div>
      <div className="form-footer padded"><Button type="submit" loading={busy} disabled={!ready}><ClipboardCheck size={15}/> Save all physical counts</Button></div>
    </Card></form>:null}
    {!allUnverified?<Card><div className="panel-heading"><div><h2>Saved consumption result</h2><p>Physical counts are read-only once verified. A recorded variance needs a separate inventory review.</p></div><Badge tone={unverified.length?"amber":consumptions.some(row=>row.varianceStatus==="VARIANCE_RECORDED")?"red":"green"}>{unverified.length?"Review needed":"Verified"}</Badge></div><DataTable rows={consumptions} columns={reviewColumns} rowKey={(row:Row)=>String(row.id??row.materialId)} emptyTitle="No consumption lines" emptyDescription="Verify that this completion references a frozen BOM."/><div className="padded"><Button onClick={()=>navigate("/daily-plans/jobs/"+completion.packingJobId)}>Return to job details →</Button></div></Card>:null}
    {allUnverified&&!canVerify?<Alert kind="error">Your role cannot record physical counts. Ask an administrator, planner or operator to verify this completion.</Alert>:null}
    {saved?<Card><div className="panel-heading"><div><h2>Verification response</h2><p>{saved.verifiedCount??0} material lines saved.</p></div><CheckCircle2 size={18} color="#15966b"/></div><DataTable rows={saved.consumptions??[]} columns={reviewColumns} rowKey={(row:Row)=>String(row.id??row.materialId)}/></Card>:null}
  </div>;
}
