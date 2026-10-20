import { useEffect, useMemo, useState, type FormEvent } from "react";
import { NavLink, Navigate, Route, Routes, useLocation, useNavigate } from "react-router-dom";
import {
  Activity, AlertTriangle, BarChart3, Bell, Boxes, CalendarDays, ChevronDown, ClipboardCheck,
  Factory, FileText, Gauge, LayoutDashboard, Layers3, LogOut, Menu, Package, PanelLeftClose, PanelLeftOpen,
  Search, Settings, ShieldCheck, ShoppingCart, UserRound, Users, Wifi, X
} from "lucide-react";
import type { Session } from "@supabase/supabase-js";
import { supabase, supabaseConfigured } from "./lib/supabase";
import { AdminPage, BomStudioPage, CatalogPage, ClosingPage, ConsumptionVerificationPage, CustodyPage, DashboardPage, JobDetailPage, PlanningPage, ProductionPage, PurchasingPage, QuarantinePage, ReportsPage, StockPage } from "./pages";
import { Alert, Button, Loading } from "./components/ui";

type UserProfile = { id: string; full_name?: string | null; role?: string | null; is_active?: boolean | null };
type NavItem = { label: string; path: string; icon: typeof LayoutDashboard; roles?: string[] };
type NavGroup = { title: string; items: NavItem[] };

const groups: NavGroup[] = [
  { title: "WORKSPACE", items: [
    { label: "Dashboard", path: "/", icon: LayoutDashboard },
    { label: "Daily plans", path: "/daily-plans", icon: CalendarDays, roles: ["ADMIN","PLANNER","STOREKEEPER","OPERATOR","VIEWER"] },
    { label: "Job detail & production", path: "/daily-plans/jobs", icon: Factory, roles: ["ADMIN","PLANNER","STOREKEEPER","OPERATOR"] },
    { label: "Shift closing", path: "/closings", icon: ClipboardCheck, roles: ["ADMIN","PLANNER","STOREKEEPER"] }
  ]},
  { title: "INVENTORY", items: [
    { label: "Stock & ledger", path: "/inventory/stock", icon: Boxes },
    { label: "Worker custody", path: "/worker-custody", icon: Users, roles: ["ADMIN","STOREKEEPER","PLANNER","OPERATOR"] },
    { label: "Quarantine & scrap", path: "/inventory/quarantine", icon: AlertTriangle, roles: ["ADMIN","STOREKEEPER"] },
    { label: "Purchasing & inward", path: "/purchasing", icon: ShoppingCart, roles: ["ADMIN","STOREKEEPER"] }
  ]},
  { title: "CONFIGURATION", items: [
    { label: "Material categories", path: "/masters/categories", icon: Boxes },
    { label: "Materials catalog", path: "/masters/materials", icon: Package },
    { label: "Parties & products", path: "/masters/parties-products", icon: Users },
    { label: "Vendors", path: "/masters/vendors", icon: ShoppingCart, roles: ["ADMIN","STOREKEEPER"] },
    { label: "Locations & workers", path: "/masters/locations-workers", icon: Factory },
    { label: "Units & conversions", path: "/masters/units", icon: Gauge },
    { label: "BOM studio", path: "/boms", icon: Layers3, roles: ["ADMIN","PLANNER"] }
  ]},
  { title: "INSIGHTS & CONTROL", items: [
    { label: "Reports & analytics", path: "/reports", icon: BarChart3 },
    { label: "Administration", path: "/admin", icon: ShieldCheck, roles: ["ADMIN"] }
  ]}
];


function SetupScreen() {
  return <div className="setup-screen"><div className="setup-card"><div className="brand-mark large"><Package size={30}/></div><div className="eyebrow">PACKWISE ERP · SETUP</div><h1>Connect your operations workspace</h1><p>Add the browser-safe Supabase URL and publishable/anon key to the frontend environment. The Flask API URL can be configured separately.</p><div className="setup-code"><code>VITE_SUPABASE_URL=https://your-project.supabase.co</code><code>VITE_SUPABASE_ANON_KEY=your-publishable-key</code><code>VITE_API_BASE_URL=http://localhost:5000/api/v1</code></div><Alert kind="warning">Keep privileged server credentials out of all Vite variables. Anything prefixed with VITE_ is visible to the browser.</Alert><a href="https://supabase.com/dashboard" target="_blank" rel="noreferrer">Open Supabase dashboard ↗</a></div></div>;
}

function LoginScreen() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setBusy(true); setMessage("");
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) setMessage(error.message);
    setBusy(false);
  };
  return <div className="login-screen"><div className="login-aside"><div className="brand-lockup"><div className="brand-mark"><Package size={23}/></div><div><strong>packwise</strong><span>PACKAGING OPERATIONS</span></div></div><div className="login-hero"><div className="eyebrow eyebrow-light">CONNECTED SHOP-FLOOR OPERATIONS</div><h1>Every material.<br/>Every shift.<br/><em>In control.</em></h1><p>One operational view for inventory, procurement, planning and production traceability.</p><div className="login-proof"><span><Activity size={17}/> Live stock ledger</span><span><ShieldCheck size={17}/> Role-based access</span><span><ClipboardCheck size={17}/> Auditable workflows</span></div></div><div className="login-footer">PACKWISE ERP · INVENTORY & BOM MANAGEMENT</div></div><div className="login-main"><div className="login-form-wrap"><div className="mobile-brand"><div className="brand-mark"><Package size={22}/></div><strong>packwise</strong></div><div className="eyebrow">WELCOME BACK</div><h2>Sign in to your workspace</h2><p className="login-subtitle">Use your assigned operations account to continue.</p>{message ? <Alert kind="error">{message}</Alert> : null}<form onSubmit={submit} className="stack-form"><label className="field"><span>Work email <i>*</i></span><input type="email" required autoComplete="username" value={email} onChange={(e)=>setEmail(e.target.value)} placeholder="you@company.com"/></label><label className="field"><span>Password <i>*</i></span><input type="password" required autoComplete="current-password" value={password} onChange={(e)=>setPassword(e.target.value)} placeholder="Enter your password"/></label><Button type="submit" loading={busy} className="full-width">Sign in <span>→</span></Button></form><div className="login-security"><ShieldCheck size={16}/><span>Secure sign-in powered by Supabase Auth</span></div><p className="login-help">Need access? Contact your Packwise administrator.</p></div><div className="login-copyright">© {new Date().getFullYear()} Packwise ERP</div></div></div>;
}

function useProfile(session: Session) {
  const [profile, setProfile] = useState<UserProfile>({ id: session.user.id, role: session.user.app_metadata?.role ?? "VIEWER" });
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let alive = true;
    const load = async () => {
      const { data, error } = await supabase.from("profiles").select("id,full_name,role,is_active").eq("id", session.user.id).maybeSingle();
      if (!alive) return;
      if (data && !error) setProfile(data as UserProfile);
      setLoading(false);
    };
    void load();
    return () => { alive = false; };
  }, [session.user.id]);
  return { profile, loading };
}

function AppShell({ session, onSignOut }: { session: Session; onSignOut: () => Promise<void> }) {
  const { profile, loading: profileLoading } = useProfile(session);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [shift, setShift] = useState("SHIFT_1");
  const [quickSearch, setQuickSearch] = useState("");
  const location = useLocation();
  const navigate = useNavigate();
  const role = (profile.role || "VIEWER").toUpperCase();
  const visibleGroups = useMemo(() => groups.map((group) => ({
    ...group, items: group.items.filter((item) => !item.roles || item.roles.includes(role))
  })).filter((group) => group.items.length), [role]);
  const allItems = visibleGroups.flatMap((group) => group.items);
  const activeTitle = allItems.find((item) => item.path === location.pathname)?.label
    ?? (location.pathname.startsWith("/daily-plans/jobs/") ? "Job detail & production" : "Operations");
  const runQuickSearch = () => {
    const query = quickSearch.trim().toLowerCase();
    const hit = allItems.find((item) => item.label.toLowerCase().includes(query));
    if (hit) { navigate(hit.path); setQuickSearch(""); setMobileOpen(false); }
  };
  const isProfileInactive = profile.is_active === false;
  return <div className={`app-shell ${sidebarOpen ? "" : "sidebar-collapsed"}`}>
    {mobileOpen ? <button className="mobile-scrim" onClick={() => setMobileOpen(false)} aria-label="Close menu"/> : null}
    <aside className={`sidebar ${mobileOpen ? "mobile-open" : ""}`}>
      <div className="sidebar-brand"><div className="brand-mark"><Package size={22}/></div>{sidebarOpen ? <div className="brand-word"><strong>packwise</strong><span>OPERATIONS ERP</span></div> : null}<button className="sidebar-collapse" onClick={() => setSidebarOpen(!sidebarOpen)} aria-label={sidebarOpen ? "Collapse sidebar" : "Expand sidebar"}>{sidebarOpen ? <PanelLeftClose size={17}/> : <PanelLeftOpen size={17}/>}</button></div>
      <div className="workspace-chip"><div className="workspace-avatar">P</div>{sidebarOpen ? <div><strong>Plant workspace</strong><small>Inventory + Production</small></div> : null}<span className="online-dot"/></div>
      <nav className="sidebar-nav">{visibleGroups.map((group) => <div className="nav-group" key={group.title}><div className="nav-group-label">{sidebarOpen ? group.title : "···"}</div>{group.items.map((item) => { const Icon=item.icon; return <NavLink key={item.path} to={item.path} title={!sidebarOpen ? item.label : undefined} end={item.path==="/"} onClick={()=>setMobileOpen(false)} className={({isActive})=>`nav-item ${isActive ? "active" : ""}`}><Icon size={18}/>{sidebarOpen ? <span>{item.label}</span> : null}{sidebarOpen && item.label==="Shift closing" ? <span className="nav-count">!</span> : null}</NavLink>; })}</div>)}</nav>
      <div className="sidebar-bottom">{sidebarOpen ? <div className="help-card"><div className="help-spark">✦</div><strong>Need a hand?</strong><p>Keep stock and production in sync.</p><button onClick={()=>navigate("/reports")}>Open operations reports <span>↗</span></button></div> : null}<button className="nav-item signout-link" onClick={()=>void onSignOut()} title="Sign out"><LogOut size={18}/>{sidebarOpen ? <span>Sign out</span> : null}</button></div>
    </aside>
    <div className="app-main">
      <header className="topbar"><div className="topbar-left"><button className="mobile-menu icon-button" onClick={()=>setMobileOpen(true)} aria-label="Open menu"><Menu size={20}/></button><div className="breadcrumb"><span>Workspace</span><b>/</b><strong>{activeTitle}</strong></div></div><div className="topbar-tools"><div className="system-status"><span className="online-dot"/><span>Connected</span></div><label className="shift-select" title="Default operational shift"><CalendarDays size={15}/><select aria-label="Active shift" value={shift} onChange={(e)=>setShift(e.target.value)}><option value="ALL">All shifts</option><option value="GENERAL">General</option><option value="SHIFT_1">Shift 1</option><option value="SHIFT_2">Shift 2</option></select><ChevronDown size={13}/></label><div className="header-search"><Search size={16}/><input value={quickSearch} onChange={(e)=>setQuickSearch(e.target.value)} onKeyDown={(e)=>e.key==="Enter" && runQuickSearch()} placeholder="Jump to a screen…"/><kbd>↵</kbd></div><div className="notification-wrap"><button className={`icon-button notification-button ${notificationsOpen ? "is-open" : ""}`} onClick={()=>setNotificationsOpen(!notificationsOpen)} aria-label="Notifications"><Bell size={18}/><span className="notification-dot"/></button>{notificationsOpen ? <div className="notification-popover"><div className="popover-head"><strong>Operations inbox</strong><button className="icon-button" onClick={()=>setNotificationsOpen(false)} aria-label="Close notifications"><X size={15}/></button></div><div className="notification-item"><span className="notification-icon amber"><AlertTriangle size={16}/></span><div><strong>Review stock alerts</strong><p>Check available stock and quarantine balances.</p><button onClick={()=>{navigate("/inventory/stock");setNotificationsOpen(false);}}>View inventory →</button></div></div><div className="notification-item"><span className="notification-icon blue"><ClipboardCheck size={16}/></span><div><strong>Shift reconciliation</strong><p>Verify physical usage before closing a shift.</p><button onClick={()=>{navigate("/closings");setNotificationsOpen(false);}}>Open closing console →</button></div></div></div> : null}</div><div className="user-profile"><div className="user-avatar">{(profile.full_name || session.user.email || "P").slice(0,1).toUpperCase()}</div><div className="user-profile-text"><strong>{profile.full_name || session.user.email?.split("@")[0] || "User"}</strong><span>{role.replaceAll("_"," ")}</span></div></div></div></header>
      <main className="content-area">{profileLoading ? <Loading label="Loading your access profile…"/> : isProfileInactive ? <div className="content-narrow"><Alert kind="error">This profile is inactive. Contact an administrator to restore access.</Alert></div> : <Routes>
        <Route path="/" element={<DashboardPage role={role} shift={shift}/>}/>
        <Route path="/masters/:resource" element={<CatalogPage role={role}/>}/>
        <Route path="/purchasing" element={<PurchasingPage role={role}/>}/>
        <Route path="/inventory/stock" element={<StockPage/>}/>
        <Route path="/inventory/quarantine" element={<QuarantinePage role={role}/>}/>
        <Route path="/worker-custody" element={<CustodyPage role={role}/>}/>
        <Route path="/boms" element={<BomStudioPage role={role}/>}/>
        <Route path="/daily-plans" element={<PlanningPage role={role} shift={shift}/>}/>
        <Route path="/daily-plans/jobs" element={<JobDetailPage role={role}/>}/>
        <Route path="/daily-plans/jobs/:id" element={<JobDetailPage role={role}/>}/>
        <Route path="/daily-plans/jobs/:id/complete" element={<ProductionPage role={role}/>}/>
        <Route path="/production/completions/:id/verify" element={<ConsumptionVerificationPage role={role}/>}/>
        <Route path="/closings" element={<ClosingPage role={role}/>}/>
        <Route path="/reports" element={<ReportsPage/>}/>
        <Route path="/admin" element={<AdminPage role={role} profile={profile}/>}/>
        <Route path="*" element={<Navigate to="/" replace/>}/>
      </Routes>}</main>
      <footer className="app-footer"><span>Packwise ERP</span><span><Wifi size={13}/> Secure operations workspace</span><span>Build · Phase 8</span></footer>
    </div>
  </div>;
}

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let alive = true;
    supabase.auth.getSession().then(({ data }) => { if (alive) { setSession(data.session); setLoading(false); } });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => { setSession(nextSession); setLoading(false); });
    return () => { alive = false; listener.subscription.unsubscribe(); };
  }, []);
  const signOut = async () => { await supabase.auth.signOut(); setSession(null); };
  if (!supabaseConfigured) return <SetupScreen/>;
  if (loading) return <div className="boot-screen"><div className="brand-mark"><Package size={22}/></div><Loading label="Preparing Packwise ERP…"/></div>;
  return session ? <AppShell session={session} onSignOut={signOut}/> : <LoginScreen/>;
}