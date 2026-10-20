import { useMemo, useState, type FormEvent } from "react";
import { FileClock, ShieldCheck, Users, RefreshCw, Search, UserCog } from "lucide-react";
import { apiPost } from "../lib/api";
import { supabase } from "../lib/supabase";
import { Alert, Badge, Button, Card, DataTable, Field, PageHeader, SearchBox, SectionTitle, SelectField, StatusBadge, TextArea, Toolbar } from "../components/ui";
import { Row, displayDate, selectRows, useAsyncData } from "./shared";
import { ReportsAnalyticsPage } from "./reports/ReportsAnalytics";

export function ReportsPage() {
  return <ReportsAnalyticsPage />;
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