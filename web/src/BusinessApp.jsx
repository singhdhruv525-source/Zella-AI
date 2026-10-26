import { useCallback, useEffect, useState } from "react";
import {
  AutomationsPage, CalendarPage, CallsPage, CustomersPage, LeadsPage,
  MessagesPage, ReceptionistPage,
} from "./BusinessPages";
import { BusinessSettingsPage } from "./BusinessSettings";
import { ReconnectBanner } from "./BusinessReports";
import { TeamPage } from "./BusinessTeam";
import { DraftsPage, LiveNoticeBanner, LiveNoticeModal } from "./BusinessDrafts";
import { AccessPage, ApprovalsPage, FailedWorkPage, SecurityLogPage } from "./BusinessAccess";
import PersonProfile from "./BusinessProfile";
import { KnowledgePage } from "./BusinessKnowledge";
import { RecordSettingsPage, RecordsPage, useRecordTypes } from "./BusinessRecords";
import { NotificationsBell, TasksPage, WaitlistPage } from "./BusinessWork";
import { CallbacksPage } from "./BusinessCallbacks";
import { InboxPage } from "./BusinessInbox";
import { CheckInsPage } from "./BusinessCheckIns";
import {
  AttentionPage, IntegrationsPage, LeadSourcesPage, ReportsPage,
} from "./BusinessMore";
import "./BusinessApp.css";
import { supabase } from "./supabase";
import { BusinessSignIn, MfaCodeCard, Welcome, acceptInvitations } from "./BusinessAuth";
import { useMfaGate } from "./mfa";
import { maintenanceText, usePlatformInfo } from "./platformInfo";
import "./CrmMotion.css";
import { warm } from "./zellaVoice";
import BusinessToday from "./BusinessToday";
import { AddLeadModal, BookAppointmentModal } from "./BusinessForms";
import { Icon, loadBusinessFonts } from "./BusinessUI";
import { formatLongDate } from "./businessTime";
import { makeTerm, receptionistState } from "./businessWorkspace";
import { navigate, segments, usePath } from "./router";
import { buildNavigation, flatten } from "./navigation/navConfig";
import { useWorkspaceNavigation } from "./navigation/useWorkspaceNavigation";
import { BusinessSwitcher, ProfileMenu, ReceptionistCard, SidebarNav, SidebarState, TestVoiceModal } from "./navigation/Sidebar";

// The CRM each client business uses (Stitch design). Routes:
//   /welcome  set password from an invitation or reset email
//   /app      sign in, then the business's own workspace

loadBusinessFonts();

// Every page key the app knows, so an address for a page this person can't see
// says "not available" instead of "not found".
const KNOWN_PAGES = new Set([
  "today", "leads", "customers", "calendar", "checkins", "waitlist", "tasks", "drafts", "attention", "callbacks",
  "inbox", "messages", "calls", "lead-sources", "receptionist", "transcripts", "automations", "knowledge", "team",
  "access", "approvals", "failed", "security", "reports", "record-settings", "integrations", "settings",
]);

// Address <-> page:  /app = Today, /app/<key>, /app/records/<type>, /app/settings/<section>.
function readPage(path, base) {
  const rest = path === base || path.startsWith(`${base}/`) ? segments(path.slice(base.length)) : [];
  if (!rest.length) return { key: "today", section: null, sub: null, extra: false };
  if (rest[0] === "records") return { key: `rec:${rest[1] ?? ""}`, section: null, sub: null, extra: rest.length > 2 };
  if (rest[0] === "settings") return { key: "settings", section: rest[1] ?? null, sub: rest[2] ?? null, extra: rest.length > 3 };
  return { key: rest[0], section: null, sub: null, extra: rest.length > 1 };
}
const pageUrl = (base, key) =>
  key === "today" ? base : key.startsWith("rec:") ? `${base}/records/${encodeURIComponent(key.slice(4))}` : `${base}/${key}`;

// Pages whose list the header search filters.
const SEARCHABLE = (key) => key === "customers" || key === "leads" || key.startsWith("rec:");

function Blocked({ workspace, onSignOut }) {
  const cancelled = Boolean(workspace.cancelled_at);
  return (
    <main className="ba-auth">
      <section className="ba-auth-card">
        <div className="ba-brand">
          <div className="ba-logo">Z</div>
          <div className="ba-brand-name">Zella AI</div>
        </div>
        <div className="ba-eyebrow">{workspace.name}</div>
        <h1>{cancelled ? "This plan has ended" : "This workspace is paused"}</h1>
        <p className="ba-auth-description">
          {cancelled
            ? "Your Zella membership has ended, so your workspace and AI receptionist are off. Your information is kept. Contact the Zella team to start again."
            : "Your workspace and AI receptionist are paused for now. Please contact the Zella team to get it running again."}
        </p>
        <button type="button" className="ba-btn block" onClick={onSignOut}>Sign out</button>
      </section>
    </main>
  );
}

function Workspace({ workspace, workspaces, onSwitch, email, userId, fallbackName, onSignOut, onReload, base = "/app", navPreview }) {
  const path = usePath();
  const route = readPage(path, base);
  const page = route.key;
  const setPage = (key) => navigate(pageUrl(base, key));
  // Phone-width menu: the sidebar opens as a drawer and closes as soon as the address changes.
  const [navOpenAt, setNavOpenAt] = useState(null);
  const navOpen = navOpenAt === path;
  useEffect(() => {
    if (!navOpen) return undefined;
    const onKey = (e) => { if (e.key === "Escape") setNavOpenAt(null); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [navOpen]);
  const [modal, setModal] = useState(null);
  // A walk-in is a booking that starts now; the form opens on today's date and the current time.
  const [bookInitial, setBookInitial] = useState(null);
  const openBooking = (opts) => {
    if (opts?.walkIn) {
      const [date, time] = new Intl.DateTimeFormat("en-CA", { timeZone: workspace.timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
        .format(new Date()).split(", ");
      setBookInitial({ date, time });
    } else setBookInitial(null);
    setModal("book");
  };
  const [refreshKey, setRefreshKey] = useState(0);
  const [busy, setBusy] = useState(false);
  const [notice, setNoticeRaw] = useState("");
  const setNotice = (message) => setNoticeRaw(warm(message, workspace));
  const [search, setSearch] = useState("");
  const [profileId, setProfileId] = useState(null);
  const [attention, setAttention] = useState(0);
  const [error, setError] = useState("");
  const term = makeTerm(workspace);
  const records = useRecordTypes(workspace, 0);
  // The sidebar for this business and this person: industry, enabled modules, record types and role (navConfig.js).
  const nav = useWorkspaceNavigation(workspace, navPreview);
  const groups = nav.status === "ready" ? buildNavigation({
    role: workspace.role,
    modules: new Set((nav.data.modules ?? []).filter((m) => m.enabled).map((m) => m.slug)),
    recordTypes: records.types,
    operationsLabel: nav.data.operations_label,
    configured: nav.data.configured,
  }, term) : [];
  const [myName, setMyName] = useState("");
  useEffect(() => {
    if (navPreview) return undefined;
    let live = true;
    supabase.rpc("zella_my_profile").then(({ data }) => {
      if (live && data) setMyName([data.first_name, data.last_name].filter(Boolean).join(" "));
    });
    return () => { live = false; };
  }, [navPreview]);
  const agent = receptionistState(workspace);
  const isOwner = workspace.role === "owner";
  const maintenance = maintenanceText(usePlatformInfo());

  async function keepPlan() {
    setBusy(true);
    setError("");
    try {
      const { error: rpcError } = await supabase.rpc("zella_owner_continue_plan", { p_business_id: workspace.id });
      if (rpcError) throw rpcError;
      setNotice("Your plan will continue. Thanks for staying with Zella.");
      await onReload();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  // Callers waiting for a person. Quietly stays at 0 until the latest Zella update is applied.
  const countAttention = useCallback(async () => {
    const { count, error: countError } = await supabase
      .from("calls_view").select("id", { count: "exact", head: true })
      .eq("business_id", workspace.id).eq("needs_human", true).is("escalation_resolved_at", null);
    setAttention(countError ? 0 : count ?? 0);
  }, [workspace.id]);
  useEffect(() => {
    countAttention();
    const timer = setInterval(countAttention, 60000);
    return () => clearInterval(timer);
  }, [countAttention, refreshKey]);

  const openPerson = (id) => id && setProfileId(id);

  function saved(message) {
    setModal(null);
    setNotice(message);
    setRefreshKey((k) => k + 1);
  }

  const allItems = flatten(groups);
  const found = route.extra ? null : allItems.find((i) => i.page === page);
  // Shown in place of a page: the menu or record types still loading, the configuration failed to load, not allowed
  // for this role, plan or industry, or unknown.
  const missing = found ? null
    : nav.status === "loading" || (page.startsWith("rec:") && !records.loaded) ? "loading"
      : nav.status === "error" ? "config-error"
        : !route.extra && (KNOWN_PAGES.has(page) || page.startsWith("rec:")) ? "unavailable" : "not-found";
  const current = found ? { key: found.page, label: found.label } : { key: "", label: missing === "not-found" ? "Page not found" : "Not available" };
  const canGo = (key) => allItems.some((i) => i.page === key);
  // Selected state. A Settings shortcut (Call handling rules, Notifications) is selected on its own Settings page,
  // and then the Settings item isn't.
  const settingsAt = page === "settings" ? `${route.section}/${route.sub}` : null;
  const shortcutHere = settingsAt && allItems.some((i) => i.settings === settingsAt);
  const isActive = (item) => (item.settings ? item.settings === settingsAt : item.page === page && !(page === "settings" && shortcutHere));
  const openItem = (item) => (item.settings ? navigate(`${base}/settings/${item.settings}`) : setPage(item.page));
  const searchable = SEARCHABLE(current.key);
  const searchLabel = current.key === "leads" ? "leads"
    : current.key.startsWith("rec:") ? current.label.toLowerCase() : term("customers").toLowerCase();

  return (
    <div className="ba-root">
      {navOpen && <button type="button" className="zella-nav-backdrop" aria-label="Close menu" onClick={() => setNavOpenAt(null)} />}
      <aside id="ba-sidebar" className={`ba-sidebar ${navOpen ? "open" : ""}`} aria-label="Main navigation">
        <div className="ba-brand">
          <div className="ba-logo">Z</div>
          <div>
            <div className="ba-brand-name">Zella AI</div>
            <div className="ba-brand-sub">{nav.data?.industry?.name ?? workspace.industry ?? "Business"} CRM</div>
          </div>
        </div>

        {nav.status === "ready"
          ? <SidebarNav groups={groups} isActive={isActive} onOpen={openItem} badges={{ attention }} />
          : <SidebarState status={nav.status} error={nav.error} onRetry={nav.retry} />}

        <div className="ba-sidebar-foot">
          <ReceptionistCard workspace={workspace} agent={agent} term={term} onTest={() => setModal("test-voice")} />
        </div>
      </aside>

      <div className="ba-main">
        <header className="ba-header">
          <button type="button" className="ba-btn ghost zella-menu-btn ba-menu-btn" aria-label="Open menu" aria-controls="ba-sidebar" aria-expanded={navOpen}
            onClick={() => setNavOpenAt(navOpen ? null : path)}>
            <Icon name="menu" />
          </button>
          <BusinessSwitcher workspace={workspace} workspaces={workspaces} config={nav.data} onSwitch={onSwitch}
            onGo={(path) => navigate(`${base}/${path}`)} canManage={["owner", "admin"].includes(workspace.role)} />

          <label className="ba-search">
            <Icon name="search" size="sm" />
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              // On a page without a list, Enter opens the search results in the customer list.
              onKeyDown={(e) => { if (e.key === "Enter" && !searchable && search.trim()) setPage("customers"); }}
              placeholder={searchable ? `Search ${searchLabel}` : `Search ${term("customers").toLowerCase()} (press Enter)`}
              aria-label={`Search ${searchLabel}`}
            />
          </label>

          <div className="ba-header-actions">
            {["owner", "admin", "manager"].includes(workspace.role) && (
              <button type="button" className="ba-btn" onClick={() => setModal("live-notice")} title="Tell callers about today">
                <Icon name="campaign" /><span>Tell callers</span>
              </button>
            )}
            <NotificationsBell workspace={workspace} onGo={(key) => {
              if (canGo(key)) setPage(key);
              else if (key) setNotice("That page isn't available with your access. Ask an owner or admin if you need it.");
            }} />
            <button type="button" className="ba-btn primary" onClick={() => setModal("lead")}>
              <Icon name="person_add" /><span>Add lead</span>
            </button>
            <button type="button" className="ba-btn" onClick={() => openBooking()}>
              <Icon name="event" /><span>Book {term("appointment").toLowerCase()}</span>
            </button>
            <ProfileMenu email={email} name={myName} role={workspace.role} onGo={(path) => navigate(`${base}/${path}`)} onSignOut={onSignOut} />
          </div>
        </header>

        <main className="ba-content">
          {maintenance && <div className="ba-banner" role="status"><span>{maintenance}</span></div>}
          {workspace.cancel_at && !workspace.cancelled_at && (
            <div className="ba-banner">
              <span>
                Your Zella plan ends on <strong>{formatLongDate(workspace.cancel_at, workspace.timezone)}</strong>.
                After that your AI receptionist stops answering calls.
              </span>
              {isOwner && (
                <button type="button" className="ba-btn primary sm" onClick={keepPlan} disabled={busy}>
                  {busy ? "Saving..." : "Keep my plan"}
                </button>
              )}
            </div>
          )}
          <LiveNoticeBanner workspace={workspace} tick={refreshKey} canManage={["owner", "admin", "manager"].includes(workspace.role)} onNotice={setNotice} />
          {current.key !== "integrations" && <ReconnectBanner workspace={workspace} tick={refreshKey} onGo={setPage} />}
          {attention > 0 && current.key !== "attention" && (
            <div className="ba-banner alert" role="alert">
              <span><strong>{attention === 1 ? "1 caller needs" : `${attention} callers need`} a person.</strong> Your AI receptionist handed them over.</span>
              <button type="button" className="ba-btn primary sm" onClick={() => setPage("attention")}>Open</button>
            </div>
          )}
          {notice && (
            <div className="ba-banner success" role="status">
              <span>{notice}</span>
              <button type="button" className="ba-btn ghost sm" onClick={() => setNotice("")} aria-label="Dismiss">
                <Icon name="close" size="sm" />
              </button>
            </div>
          )}
          {error && <div className="ba-banner error">{error}</div>}

          {missing === "loading" && <p className="ba-muted">Loading…</p>}
          {missing === "config-error" && (
            <section className="ba-panel">
              <div className="ba-panel-body">
                <h2>This business's settings didn't load</h2>
                <p className="ba-muted">Pages stay hidden until they do, so nothing from another business or a wrong industry is shown.</p>
                <button type="button" className="ba-btn primary" onClick={nav.retry}>Try again</button>
              </div>
            </section>
          )}
          {missing && missing !== "loading" && missing !== "config-error" && (
            <section className="ba-panel">
              <div className="ba-panel-body">
                <h2>{missing === "not-found" ? "Page not found" : "This page isn't available"}</h2>
                <p className="ba-muted">
                  {missing === "not-found"
                    ? "There's no page at this address. It may have moved, or the link may be incomplete."
                    : "Your role or this workspace's plan doesn't include this page. Ask an owner or admin if you need it."}
                </p>
                <button type="button" className="ba-btn primary" onClick={() => setPage("today")}>Go to Today</button>
              </div>
            </section>
          )}
          {current.key === "today" && (
            <BusinessToday
              key={refreshKey}
              workspace={workspace}
              userId={userId}
              fallbackName={myName || fallbackName}
              industry={nav.data?.industry?.slug}
              operations={records.types}
              onAddLead={() => setModal("lead")}
              onBook={(opts) => openBooking(opts)}
              onGo={(key) => (key.startsWith("settings/") ? navigate(`${base}/${key}`) : setPage(key))}
              onNotice={setNotice}
              onOpenPerson={openPerson}
            />
          )}
          {current.key === "leads" && <LeadsPage workspace={workspace} query={search} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "customers" && <CustomersPage workspace={workspace} query={search} refreshKey={refreshKey} onOpenPerson={openPerson} />}
          {current.key === "calendar" && <CalendarPage workspace={workspace} industry={nav.data?.industry?.slug} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "calls" && <CallsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "transcripts" && <CallsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} transcriptsOnly />}
          {current.key === "messages" && <MessagesPage workspace={workspace} refreshKey={refreshKey} onOpenPerson={openPerson} />}
          {current.key === "receptionist" && <ReceptionistPage workspace={workspace} onNotice={setNotice} onReload={onReload} />}
          {current.key === "automations" && <AutomationsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "callbacks" && <CallbacksPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} onChanged={countAttention} />}
          {current.key === "tasks" && <TasksPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "waitlist" && <WaitlistPage workspace={workspace} term={term} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "knowledge" && <KnowledgePage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key.startsWith("rec:") && records.types.find((t) => `rec:${t.key}` === current.key) && (
            <RecordsPage workspace={workspace} type={records.types.find((t) => `rec:${t.key}` === current.key)} query={search} refreshKey={refreshKey}
              canManage={["owner", "admin", "manager"].includes(workspace.role)} onNotice={setNotice} onOpenPerson={openPerson} />
          )}
          {current.key === "record-settings" && (
            <RecordSettingsPage workspace={workspace} types={records.types} canManage={["owner", "admin", "manager"].includes(workspace.role)} onNotice={setNotice} onChanged={records.reload} />
          )}
          {current.key === "team" && <TeamPage workspace={workspace} email={email} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "drafts" && <DraftsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "access" && <AccessPage workspace={workspace} userId={userId} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "approvals" && <ApprovalsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "failed" && <FailedWorkPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "security" && <SecurityLogPage workspace={workspace} refreshKey={refreshKey} />}
          {current.key === "checkins" && <CheckInsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} onChanged={countAttention} />}
          {current.key === "attention" && <AttentionPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} onChanged={countAttention} />}
          {current.key === "inbox" && <InboxPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "lead-sources" && <LeadSourcesPage workspace={workspace} refreshKey={refreshKey} />}
          {current.key === "reports" && <ReportsPage workspace={workspace} refreshKey={refreshKey} />}
          {current.key === "integrations" && <IntegrationsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
          {current.key === "settings" && <BusinessSettingsPage workspace={workspace} email={email} userId={userId} records={records} onSignOut={onSignOut} section={route.section} sub={route.sub} onGo={setPage} onReload={onReload} onOpenPerson={openPerson} onNotice={setNotice} />}
        </main>
      </div>

      {profileId && (
        <PersonProfile
          personId={profileId}
          workspace={workspace}
          onClose={() => setProfileId(null)}
          onChanged={() => { setRefreshKey((k) => k + 1); countAttention(); }}
          onNotice={setNotice}
        />
      )}
      {modal === "lead" && <AddLeadModal workspace={workspace} term={term} onClose={() => setModal(null)} onSaved={saved} />}
      {modal === "live-notice" && <LiveNoticeModal workspace={workspace} onClose={() => setModal(null)} onSaved={(m) => { setModal(null); setNotice(m); setRefreshKey((k) => k + 1); }} />}
      {modal === "book" && <BookAppointmentModal workspace={workspace} term={term} initial={bookInitial} onClose={() => setModal(null)} onSaved={saved} />}
      {modal === "test-voice" && <TestVoiceModal workspace={workspace} phone={nav.data?.phone} agent={agent} onClose={() => setModal(null)} onGo={(path) => navigate(`${base}/${path}`)} />}
    </div>
  );
}

function Loading({ text }) {
  return (
    <main className="ba-auth">
      <p className="ba-muted">{text}</p>
    </main>
  );
}

function BusinessHome() {
  const [session, setSession] = useState(undefined);
  const [workspaces, setWorkspaces] = useState(null);
  // The business last opened on this device, so a refresh stays in it. Only a convenience: the list of businesses
  // comes from the server, and an id that isn't in it is ignored.
  const [selectedId, setSelectedIdRaw] = useState(() => { try { return localStorage.getItem(LAST_BUSINESS); } catch { return null; } });
  const setSelectedId = (next) => setSelectedIdRaw((current) => {
    const id = typeof next === "function" ? next(current) : next;
    try { if (id) localStorage.setItem(LAST_BUSINESS, id); } catch { /* private mode */ }
    return id;
  });
  const [error, setError] = useState("");
  const [isAdmin, setIsAdmin] = useState(false);

  const loadWorkspaces = useCallback(async () => {
    setError("");
    // Activates any invitation this person hasn't accepted yet (safe to repeat).
    await acceptInvitations();

    const { data, error: loadError } = await supabase.rpc("zella_my_workspaces");
    if (loadError) {
      setError(loadError.message);
      setWorkspaces([]);
      return;
    }
    if (!(data ?? []).length) {
      // A Zella admin without a business of their own belongs in the admin dashboard.
      const { data: admin } = await supabase.rpc("is_platform_admin");
      setIsAdmin(admin === true);
    }
    setWorkspaces(data ?? []);
    setSelectedId((current) => ((data ?? []).some((w) => w.id === current) ? current : data?.[0]?.id ?? null));
  }, []);

  useEffect(() => {
    let active = true;
    supabase.auth.getSession().then(({ data }) => active && setSession(data.session));
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => {
      active = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  const mfa = useMfaGate(session);

  useEffect(() => {
    if (session && mfa.state === "ok") loadWorkspaces();
    else if (!session) setWorkspaces(null);
  }, [session, mfa.state, loadWorkspaces]);

  async function signOut() {
    await supabase.auth.signOut();
    setWorkspaces(null);
  }

  if (session === undefined) return <Loading text="Loading..." />;
  if (!session) return <BusinessSignIn />;
  if (mfa.state === "checking") return <Loading text="Loading..." />;
  if (mfa.state === "needs_code") return <MfaCodeCard email={session.user.email} onDone={mfa.recheck} />;
  if (workspaces === null) return <Loading text="Loading your workspace..." />;

  if (!workspaces.length) {
    return (
      <main className="ba-auth">
        <section className="ba-auth-card">
          <div className="ba-brand">
            <div className="ba-logo">Z</div>
            <div className="ba-brand-name">Zella AI</div>
          </div>
          <h1>{isAdmin ? "You're a Zella admin" : "No workspace yet"}</h1>
          <p className="ba-auth-description">
            {error
              ? `Your workspace couldn't be loaded: ${error}`
              : isAdmin
                ? `${session.user.email} manages Zella from the admin dashboard and isn't linked to a business here.`
                : `${session.user.email} isn't linked to a Zella business yet. If you were invited, open the link in your invitation email first, or ask the Zella team to resend it.`}
          </p>
          {isAdmin && <a className="ba-btn primary block" href="/">Open the admin dashboard</a>}
          <button type="button" className="ba-btn block" onClick={signOut}>Sign out</button>
        </section>
      </main>
    );
  }

  const workspace = workspaces.find((w) => w.id === selectedId) ?? workspaces[0];
  if (workspace.cancelled_at || workspace.suspended_at) return <Blocked workspace={workspace} onSignOut={signOut} />;

  return (
    <Workspace
      key={workspace.id}
      workspace={workspace}
      workspaces={workspaces}
      onSwitch={setSelectedId}
      email={session.user.email}
      userId={session.user.id}
      fallbackName={session.user.user_metadata?.full_name ?? session.user.user_metadata?.name ?? ""}
      onSignOut={signOut}
      onReload={loadWorkspaces}
    />
  );
}

// Look-only preview of the workspace without signing in. It exists only
// while running locally (npm run dev) and is removed from production builds.
// It has no data and cannot save anything, because there is no signed-in user.
const LAST_BUSINESS = "zella.lastBusiness";

const PREVIEW_WORKSPACE = {
  // A real-shaped UUID that matches no business. Queries return nothing instead
  // of failing with: invalid input syntax for type uuid: "preview".
  id: "00000000-0000-0000-0000-000000000000",
  name: "Bright Smile Dental",
  timezone: "America/New_York",
  industry: "Dental clinic",
  role: "owner",
  is_active: true,
  onboarding_status: "active",
  suspended_at: null,
  cancel_at: null,
  cancelled_at: null,
  terminology: {
    customer: "Patient", customers: "Patients", appointment: "Appointment",
    appointments: "Appointments", staff: "Dentist", staff_plural: "Dentists",
  },
  modules: ["ai-receptionist", "automations", "calendar", "calls", "sms", "email"],
  receptionist: { name: "Ava", status: "active" },
  phone_connected: true,
  voice_connected: true,
};

// Development preview only (never in a production build): the menu comes from this sample instead of the database.
const PREVIEW_NAV = {
  role: "owner", configured: true, industry: { slug: "dental", name: "Dental clinic" }, operations_label: "Clinic operations",
  modules: PREVIEW_WORKSPACE.modules.map((slug) => ({ slug, enabled: true, available: true })), location: "New York, US", logo_url: null, phone: null,
};

function Preview() {
  return (
    <Workspace
      workspace={PREVIEW_WORKSPACE}
      workspaces={[PREVIEW_WORKSPACE]}
      onSwitch={() => {}}
      email="preview@zella.ai"
      base="/app/preview"
      onSignOut={() => { window.location.href = "/app"; }}
      onReload={() => {}}
      navPreview={PREVIEW_NAV}
    />
  );
}

export default function BusinessApp() {
  const path = window.location.pathname;
  if (path.startsWith("/welcome")) return <Welcome />;
  if (import.meta.env.DEV && path.startsWith("/app/preview")) return <Preview />;
  return <BusinessHome />;
}
