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
import { Icon, Pill, initials, loadBusinessFonts } from "./BusinessUI";
import { formatLongDate } from "./businessTime";
import { makeTerm, receptionistState } from "./businessWorkspace";
import { navigate, segments, usePath } from "./router";

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
  if (!rest.length) return { key: "today", section: null, extra: false };
  if (rest[0] === "records") return { key: `rec:${rest[1] ?? ""}`, section: null, extra: rest.length > 2 };
  if (rest[0] === "settings") return { key: "settings", section: rest[1] ?? null, extra: rest.length > 2 };
  return { key: rest[0], section: null, extra: rest.length > 1 };
}
const pageUrl = (base, key) =>
  key === "today" ? base : key.startsWith("rec:") ? `${base}/records/${encodeURIComponent(key.slice(4))}` : `${base}/${key}`;

// Pages whose list the header search filters.
const SEARCHABLE = (key) => key === "customers" || key === "leads" || key.startsWith("rec:");

// Sidebar groups from the design. Core CRM pages always show; the rest follow
// the business's enabled modules. Pages not built yet are marked "Soon".
function navigation(workspace, recordTypes = []) {
  const term = makeTerm(workspace);
  const has = (slug) => workspace.modules.includes(slug);
  const groups = [
    {
      label: "Core",
      items: [
        { key: "today", label: "Today", icon: "dashboard", ready: true },
        { key: "leads", label: "Leads", icon: "filter_alt", ready: true },
        { key: "customers", label: term("customers"), icon: "group", ready: true },
        { key: "calendar", label: "Calendar", icon: "calendar_today", ready: true },
        { key: "checkins", label: "Check-ins", icon: "how_to_reg", ready: true },
        has("calendar") && { key: "waitlist", label: "Waitlist", icon: "hourglass_top", ready: true },
        { key: "tasks", label: "Tasks", icon: "task_alt", ready: true },
        ["owner", "admin", "manager", "staff"].includes(workspace.role) && { key: "drafts", label: "Suggested messages", icon: "mark_email_unread", ready: true },
      ],
    },
    {
      label: "Communications",
      items: [
        { key: "attention", label: "Needs attention", icon: "support_agent", ready: true },
        { key: "callbacks", label: "Callbacks", icon: "phone_callback", ready: true },
        { key: "inbox", label: "Unified Inbox", icon: "forum", ready: true },
        { key: "messages", label: "Messages", icon: "chat", ready: true },
        has("calls") && { key: "calls", label: "Calls", icon: "call", ready: true },
        { key: "lead-sources", label: "Lead sources", icon: "hub", ready: true },
      ],
    },
    recordTypes.some((t) => t.enabled) && {
      label: "Records",
      items: recordTypes.filter((t) => t.enabled).map((t) => ({ key: `rec:${t.key}`, label: t.plural, icon: t.icon || "folder", ready: true })),
    },
    {
      label: "AI & Intelligence",
      items: [
        has("ai-receptionist") && { key: "receptionist", label: "AI Receptionist", icon: "record_voice_over", ready: true },
        has("calls") && { key: "transcripts", label: "Transcripts", icon: "insights", ready: true },
        has("automations") && { key: "automations", label: "Automations", icon: "bolt", ready: true },
        has("ai-receptionist") && { key: "knowledge", label: "Knowledge", icon: "menu_book", ready: true },
      ],
    },
    {
      label: "Management",
      items: [
        { key: "team", label: "Team", icon: "badge", ready: true },
        ["owner", "admin"].includes(workspace.role) && { key: "access", label: "Team access", icon: "admin_panel_settings", ready: true },
        ["owner", "admin"].includes(workspace.role) && { key: "approvals", label: "Approvals", icon: "verified_user", ready: true },
        ["owner", "admin", "manager"].includes(workspace.role) && { key: "failed", label: "Didn't send", icon: "error", ready: true },
        ["owner", "admin"].includes(workspace.role) && { key: "security", label: "Security log", icon: "history", ready: true },
        { key: "reports", label: "Reports", icon: "monitoring", ready: true },
        ["owner", "admin", "manager"].includes(workspace.role) && { key: "record-settings", label: "Customise records", icon: "tune", ready: true },
        { key: "integrations", label: "Integrations", icon: "extension", ready: true },
        { key: "settings", label: "Settings", icon: "settings", ready: true },
      ],
    },
  ];
  return groups
    .filter(Boolean)
    .map((g) => ({ ...g, items: g.items.filter(Boolean) }))
    .filter((g) => g.items.length);
}

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

function Workspace({ workspace, workspaces, onSwitch, email, userId, fallbackName, onSignOut, onReload, base = "/app" }) {
  const path = usePath();
  const route = readPage(path, base);
  const page = route.key;
  const setPage = (key) => navigate(pageUrl(base, key));
  const [modal, setModal] = useState(null);
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
  const groups = navigation(workspace, records.types);
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

  const allItems = groups.flatMap((g) => g.items);
  const found = route.extra ? null : allItems.find((i) => i.key === page);
  // Shown in place of a page: still loading record types, not allowed for this role or plan, or unknown.
  const missing = found ? null
    : page.startsWith("rec:") && !records.loaded ? "loading"
      : !route.extra && (KNOWN_PAGES.has(page) || page.startsWith("rec:")) ? "unavailable" : "not-found";
  const current = found ?? { key: "", label: missing === "not-found" ? "Page not found" : "Not available" };
  const canGo = (key) => allItems.some((i) => i.key === key);
  const searchable = SEARCHABLE(current.key);
  const searchLabel = current.key === "leads" ? "leads"
    : current.key.startsWith("rec:") ? current.label.toLowerCase() : term("customers").toLowerCase();

  return (
    <div className="ba-root">
      <aside className="ba-sidebar">
        <div className="ba-brand">
          <div className="ba-logo">Z</div>
          <div>
            <div className="ba-brand-name">Zella AI</div>
            <div className="ba-brand-sub">{workspace.industry ?? "Business"} CRM</div>
          </div>
        </div>

        {groups.map((group) => (
          <div key={group.label}>
            <div className="ba-nav-group">{group.label}</div>
            <nav className="ba-nav">
              {group.items.map((item) => (
                <button
                  key={item.key}
                  type="button"
                  className={`ba-nav-item ${page === item.key ? "active" : ""} ${item.ready ? "" : "soon"}`}
                  onClick={() => item.ready && setPage(item.key)}
                  aria-disabled={!item.ready}
                  title={item.label}
                >
                  <Icon name={item.icon} />
                  <span>{item.label}</span>
                  {!item.ready && <span className="ba-soon">Soon</span>}
                  {item.key === "attention" && attention > 0 && <span className="ba-count" aria-label={`${attention} waiting`}>{attention}</span>}
                </button>
              ))}
            </nav>
          </div>
        ))}

        <div className="ba-sidebar-foot">
          <div className="ba-agent-card">
            <div className="ba-agent-row">
              <strong>{workspace.receptionist?.name ?? "AI receptionist"}</strong>
              <Pill tone={agent.tone} dot={agent.live} pulse={agent.live}>{agent.label}</Pill>
            </div>
            <span>{agent.live ? "Answering your calls" : "Zella connects your phone line before it goes live"}</span>
          </div>
          <div className="ba-user-card">
            <div className="ba-avatar">{initials(email)}</div>
            <div>
              <strong title={email}>{email}</strong>
              <span>{workspace.role}</span>
            </div>
            <button type="button" className="ba-btn ghost sm" onClick={onSignOut} title="Sign out" aria-label="Sign out">
              <Icon name="logout" size="sm" />
            </button>
          </div>
        </div>
      </aside>

      <div className="ba-main">
        <header className="ba-header">
          <div className="ba-business">
            <Icon name="domain" />
            {workspaces.length > 1 ? (
              <select value={workspace.id} onChange={(e) => onSwitch(e.target.value)} aria-label="Switch business">
                {workspaces.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
              </select>
            ) : (
              <div>
                <strong>{workspace.name}</strong>
                <span>{workspace.industry ?? ""}</span>
              </div>
            )}
          </div>

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
            <button type="button" className="ba-btn" onClick={() => setModal("book")}>
              <Icon name="event" /><span>Book {term("appointment").toLowerCase()}</span>
            </button>
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
          {missing && missing !== "loading" && (
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
              fallbackName={fallbackName}
              onAddLead={() => setModal("lead")}
              onBook={() => setModal("book")}
              onNotice={setNotice}
              onOpenPerson={openPerson}
            />
          )}
          {current.key === "leads" && <LeadsPage workspace={workspace} query={search} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
          {current.key === "customers" && <CustomersPage workspace={workspace} query={search} refreshKey={refreshKey} onOpenPerson={openPerson} />}
          {current.key === "calendar" && <CalendarPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
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
          {current.key === "settings" && <BusinessSettingsPage workspace={workspace} email={email} onSignOut={onSignOut} section={route.section} onGo={setPage} onReload={onReload} onOpenPerson={openPerson} onNotice={setNotice} />}
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
      {modal === "book" && <BookAppointmentModal workspace={workspace} term={term} onClose={() => setModal(null)} onSaved={saved} />}
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
  const [selectedId, setSelectedId] = useState(null);
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
    />
  );
}

export default function BusinessApp() {
  const path = window.location.pathname;
  if (path.startsWith("/welcome")) return <Welcome />;
  if (import.meta.env.DEV && path.startsWith("/app/preview")) return <Preview />;
  return <BusinessHome />;
}
