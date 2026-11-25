import { SidebarBrand } from "./navigation/SidebarBrand";
import { pageFor } from "../supabase/functions/_shared/pageKeys.js";
import { Suspense, lazy, useCallback, useEffect, useRef, useState } from "react";
import { ATTENTION_START, attentionCount, attentionReduce, attentionWarning } from "./crm/attention";
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
import { TablesPage } from "./BusinessTables";
import { DispatchPage, RecurringPage, ResourcesPage } from "./BusinessScheduling";
import { FollowThroughPage } from "./RecordWorkflow";
import {
  AttentionPage, IntegrationsPage, LeadSourcesPage, ReportsPage,
} from "./BusinessMore";
import { DockToggle } from "./navigation/DockToggle";
import "./BusinessApp.css";
import SpamPage from "./SpamPage";
import ReviewsPage from "./ReviewsPage";
import ScorecardsPage from "./ScorecardsPage";
import { supabase } from "./supabase";
import { BusinessSignIn, MfaCodeCard, Welcome, acceptInvitations, emailMeSignInLink } from "./BusinessAuth";
import { useMfaGate } from "./mfa";
import { maintenanceText, usePlatformInfo } from "./platformInfo";
import "./CrmMotion.css";
import { warm } from "./zellaVoice";
import BusinessToday from "./BusinessToday";
import { MoneyPage } from "./BusinessMoney";
import { AddLeadModal, BookAppointmentModal } from "./BusinessForms";
import { AppearanceSaveNotice } from "./AppearanceSaveNotice";
import { ErrorBoundary, Icon, loadBusinessFonts } from "./BusinessUI";
import { formatLongDate } from "./businessTime";
import { friendly } from "./BusinessShared";
import { makeTerm, receptionistState } from "./businessWorkspace";
import { navigate, segments, usePath } from "./router";
import { buildNavigation, capabilityOn, flatten } from "./navigation/navConfig";
import { useWorkspaceNavigation } from "./navigation/useWorkspaceNavigation";
import { BusinessSwitcher, ProfileMenu, ReceptionistCard, SidebarNav, SidebarState, TestVoiceModal } from "./navigation/Sidebar";
// Phone navigation (under 768 wide, approved 25 Nov 2026): bottom bar, side panel, sheets (navigation/PhoneNav.jsx).
import { crmTabs, selectedTab } from "./navigation/phoneTabs";
import { createTabMemory, crmStrip } from "./navigation/phoneHelpers";
import { useKeyboardOpen, usePhoneLayout, usePhoneRoot, usePullToRefresh, useRootFlag } from "./navigation/usePhoneLayout";
import { BottomBar, LiveStrip, PanelAccount, PhoneBottom, PhoneTopBar, PullIndicator, SidePanel, Skeleton, TabStack, Toast, scrollToTop, useTabScroll, useToast } from "./navigation/PhoneNav";
import { useSheetEnhancer } from "./navigation/BottomSheet";
import { PhoneUi, TodayTop } from "./navigation/phoneContext";
import { BusinessButton, NeedsYouNow, QuickActionsSheet, SwitcherSheet, useCrmSignals } from "./navigation/CrmPhone";
import { NewTaskModal } from "./BusinessWork";
import { todayConfig } from "./todayConfig";

// The CRM each client business uses (Stitch design). Routes:
//   /welcome  set password from an invitation or reset email
//   /welcome/setup  the owner onboarding journey (Welcome to You're all set)
//   /app      sign in, then the business's own workspace

loadBusinessFonts();

// Every page key the app knows, so an address for a page this person can't see
// says "not available" instead of "not found".
const KNOWN_PAGES = new Set([
  "today", "leads", "customers", "calendar", "tables", "dispatch", "resources", "recurring", "follow", "checkins", "waitlist", "tasks", "drafts", "attention", "callbacks",
  "inbox", "messages", "calls", "lead-sources", "receptionist", "transcripts", "automations", "knowledge", "team",
  "access", "approvals", "failed", "security", "reports", "record-settings", "integrations", "settings", "spam", "reviews", "scorecards", "money",
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

function Blocked({ workspace, onSignOut, signOutError }) {
  const canceled = Boolean(workspace.cancelled_at);
  return (
    <main className="ba-auth">
      <section className="ba-auth-card">
        <div className="ba-brand">
          <div className="ba-logo">Z</div>
          <div className="ba-brand-name">Zella Voice</div>
        </div>
        <div className="ba-eyebrow">{workspace.name}</div>
        <h1>{canceled ? "This plan has ended" : "This workspace is paused"}</h1>
        <p className="ba-auth-description">
          {canceled
            ? "Your Zella Voice membership has ended, so your workspace and AI receptionist are off. Your information is kept. Contact the Zella Voice team to start again."
            : "Your workspace and AI receptionist are paused for now. Please contact the Zella Voice team to get it running again."}
        </p>
        <button type="button" className="ba-btn block" onClick={onSignOut}>Sign out</button>
        {signOutError && <p className="ba-error" role="alert">{signOutError}</p>}
      </section>
    </main>
  );
}

/**
 * Render the business workspace, configured navigation, page content, and shared dialogs.
 * Refresh the waiting-caller count on entry, refresh requests, and every minute;
 * failed checks show an unavailable or stale-count notice with a retry action.
 */
function Workspace({ workspace, workspaces, onSwitch, email, userId, fallbackName, onSignOut, signOutError, onReload, base = "/app", navPreview, invites }) {
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
    } else setBookInitial(opts?.record ? { record: opts.record, customer: opts.customer } : null);
    setModal("book");
  };
  const [refreshKey, setRefreshKey] = useState(0);
  const [busy, setBusy] = useState(false);
  const [notice, setNoticeRaw] = useState("");
  // P21: on a phone, messages after an action appear above the bar (a toast) instead of the banner at the top.
  // `phone` and `toaster` are set further down; this only runs later, from an event.
  const setNotice = (message) => (phone && message ? toaster.show(warm(message, workspace)) : setNoticeRaw(warm(message, workspace)));
  const [search, setSearch] = useState("");
  const [profileId, setProfileId] = useState(null);
  const [attentionState, setAttentionState] = useState(() => ({ ...ATTENTION_START, businessId: workspace.id }));
  const attention = attentionCount(attentionState);
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
    capabilities: nav.data.capabilities,
  }, term) : [];
  // Kinds of work this business does (zella_capabilities). Booking actions only where it takes bookings.
  const caps = nav.status === "ready" ? nav.data.capabilities : undefined;
  const canBook = nav.status === "ready" && capabilityOn(caps, "scheduling") && workspace.role !== "viewer";
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
      setNotice("Your plan will continue. Thanks for staying with Zella Voice.");
      await onReload();
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy(false);
    }
  }

  // Callers waiting for a person (B3-01). A failed check never reads as "nobody is waiting": the last known count is
  // kept and marked as possibly out of date, or, if no check has worked yet, no count is claimed. Only the newest
  // check for this business may change the state (crm/attention.js).
  const attentionSeq = useRef(0);
  const countAttention = useCallback(async () => {
    const seq = ++attentionSeq.current;
    const businessId = workspace.id;
    let event;
    try {
      const { count, error: countError } = await supabase
        .from("calls_view").select("id", { count: "exact", head: true })
        .eq("business_id", businessId).eq("needs_human", true).is("escalation_resolved_at", null);
      event = countError ? { type: "fail", businessId } : { type: "ok", count, businessId };
    } catch {
      event = { type: "fail", businessId };
    }
    if (seq === attentionSeq.current) setAttentionState((s) => attentionReduce(s, event));
  }, [workspace.id]);
  useEffect(() => {
    setAttentionState(attentionReduce(ATTENTION_START, { type: "reset", businessId: workspace.id }));
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

  // ---------- Phone navigation (under 768 wide; P1 to P29, approved 25 Nov 2026) ----------
  // Tablets and desktops never reach any of this: `phone` is false there and the sidebar and header draw as before.
  const phone = usePhoneLayout();
  usePhoneRoot(phone, "crm");
  useKeyboardOpen(phone);
  useSheetEnhancer(phone);
  const toaster = useToast();
  const [tabMemory] = useState(createTabMemory);
  const [phoneSheet, setPhoneSheet] = useState(null);   // "switcher" | "quick"
  const [searchOpen, setSearchOpen] = useState(false);
  const tabs = phone && nav.status === "ready"
    ? crmTabs({ groups, capabilities: caps, industry: nav.data?.industry?.slug, recordTypes: records.types }) : [];
  const onTab = tabs.some((t) => t.key === current.key);
  const panelOpen = phone && navOpen;
  useTabScroll(phone, current.key, tabMemory, onTab);
  // read on every screen size: the bell shows "Needs you now" too (owner, 25 Nov 2026)
  const signals = useCrmSignals(workspace, { enabled: !navPreview, attention, refreshKey });
  const strip = phone && current.key !== "attention" ? crmStrip(attention, signals.oldest) : null;
  const canLead = workspace.role !== "viewer";
  const walkIn = canBook && todayConfig(nav.data?.industry?.slug).walkIn
    ? { key: "walkin", label: nav.data?.industry?.slug === "restaurant" ? "Seat a walk in" : "Add a walk in", icon: "directions_walk", onClick: () => openBooking({ walkIn: true }) } : null;
  // P10: one main action per page, in the thumb zone
  const action = !phone ? null
    : ["today", "calendar"].includes(current.key) && canBook ? { label: `New ${term("appointment").toLowerCase()}`, icon: "add", onClick: () => openBooking() }
      : current.key === "today" && canLead ? { label: "Add lead", icon: "person_add", onClick: () => setModal("lead") }
        : current.key === "tables" && walkIn ? walkIn
          : current.key === "tasks" && canLead ? { label: "New task", icon: "add_task", onClick: () => setModal("task") }
            : current.key === "leads" && canLead ? { label: "Add lead", icon: "person_add", onClick: () => setModal("lead") } : null;
  const quick = [
    walkIn,
    canLead && { key: "lead", label: "Add lead", icon: "person_add", onClick: () => setModal("lead") },
    canLead && { key: "task", label: "New task", icon: "add_task", onClick: () => setModal("task") },
    ["owner", "admin", "manager"].includes(workspace.role) && { key: "tell", label: "Tell callers", icon: "campaign", onClick: () => setModal("live-notice") },
  ].filter(Boolean);
  useRootFlag("pn-has-action", Boolean(action));
  useRootFlag("pn-has-strip", Boolean(strip));
  // P17: pull to refresh on the lists. Today reloads in place (its own Refresh); the others read again.
  const pullable = phone && ["today", "calendar", "inbox", "tasks", "leads"].includes(current.key);
  const pull = usePullToRefresh({ enabled: pullable, onRefresh: () => {
    const own = current.key === "today" && document.querySelector('.td-head [aria-label="Refresh"]');
    if (own) own.click(); else setRefreshKey((k) => k + 1);
    return countAttention();
  } });
  // P15, P16: tap the open tab to go back to the top; each tab keeps its scroll and its search
  const selectTab = (key) => {
    if (key === current.key) { scrollToTop(); return; }
    if (onTab) tabMemory.save(current.key, { search });
    setSearch(tabMemory.read(key).search ?? "");
    setPage(key);
  };
  const goFromBell = (raw) => {
    const key = raw?.startsWith("settings/") ? raw : pageFor(raw);
    if (canGo(key) || key?.startsWith("settings/")) setPage(key);
    else if (key) setNotice("That page isn't available with your access. Ask an owner or admin if you need it.");
  };
  const inboxKey = tabs.find((t) => ["inbox", "attention", "messages"].includes(t.key))?.key;
  const phoneUi = { phone, toast: toaster.show };

  // Every page, by key: drawn once on a desktop; on a phone the tab pages stay drawn (hidden) so they keep their state.
  const pageView = (key) => (
    <>
      {key === "today" && (
        <BusinessToday
          key={refreshKey}
          workspace={workspace}
          userId={userId}
          fallbackName={myName || fallbackName}
          industry={nav.data?.industry?.slug}
          operations={records.types}
          capabilities={caps}
          canEdit={workspace.role !== "viewer"}
          onAddLead={() => setModal("lead")}
          onBook={(opts) => openBooking(opts)}
          onGo={(key) => (key.startsWith("settings/") ? navigate(`${base}/${key}`) : setPage(key))}
          onNotice={setNotice}
          onOpenPerson={openPerson}
        />
      )}
      {key === "leads" && <LeadsPage workspace={workspace} query={search} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "money" && <MoneyPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "customers" && <CustomersPage workspace={workspace} query={search} refreshKey={refreshKey} onOpenPerson={openPerson} />}
      {key === "calendar" && <CalendarPage workspace={workspace} industry={nav.data?.industry?.slug} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "calls" && <CallsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "transcripts" && <CallsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} transcriptsOnly />}
      {key === "messages" && <MessagesPage workspace={workspace} refreshKey={refreshKey} onOpenPerson={openPerson} />}
      {key === "receptionist" && <ReceptionistPage workspace={workspace} onNotice={setNotice} onReload={onReload} />}
      {key === "automations" && <AutomationsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "callbacks" && <CallbacksPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} onChanged={countAttention} />}
      {key === "tasks" && <TasksPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "dispatch" && <DispatchPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "resources" && <ResourcesPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "recurring" && <RecurringPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "follow" && <FollowThroughPage workspace={workspace} types={records.types} refreshKey={refreshKey} />}
      {key === "tables" && <TablesPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onBook={canBook ? () => openBooking() : undefined} />}
      {key === "waitlist" && <WaitlistPage workspace={workspace} term={term} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "spam" && <SpamPage workspace={workspace} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "reviews" && <ReviewsPage workspace={workspace} onNotice={setNotice} />}
      {key === "scorecards" && <ScorecardsPage workspace={workspace} />}
      {key === "knowledge" && <KnowledgePage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key.startsWith("rec:") && records.types.find((t) => `rec:${t.key}` === key) && (
        <RecordsPage workspace={workspace} type={records.types.find((t) => `rec:${t.key}` === key)} query={search} refreshKey={refreshKey}
          canManage={["owner", "admin", "manager"].includes(workspace.role)} onNotice={setNotice} onOpenPerson={openPerson}
          onBook={canBook ? (record, customer) => openBooking({ record, customer }) : undefined} />
      )}
      {key === "record-settings" && (
        <RecordSettingsPage workspace={workspace} types={records.types} loaded={records.loaded} canManage={["owner", "admin", "manager"].includes(workspace.role)} onNotice={setNotice} onChanged={records.reload} loadError={records.error} />
      )}
      {key === "team" && <TeamPage workspace={workspace} email={email} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "drafts" && <DraftsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "access" && <AccessPage workspace={workspace} userId={userId} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "approvals" && <ApprovalsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "failed" && <FailedWorkPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "security" && <SecurityLogPage workspace={workspace} refreshKey={refreshKey} />}
      {key === "checkins" && <CheckInsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} onChanged={countAttention} />}
      {key === "attention" && <AttentionPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} onChanged={countAttention} />}
      {key === "inbox" && <InboxPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} onOpenPerson={openPerson} />}
      {key === "lead-sources" && <LeadSourcesPage workspace={workspace} refreshKey={refreshKey} />}
      {key === "reports" && <ReportsPage workspace={workspace} refreshKey={refreshKey} />}
      {key === "integrations" && <IntegrationsPage workspace={workspace} refreshKey={refreshKey} onNotice={setNotice} />}
      {key === "settings" && <BusinessSettingsPage workspace={workspace} email={email} userId={userId} records={records} onSignOut={onSignOut} signOutError={signOutError} section={route.section} sub={route.sub} onGo={setPage} onReload={onReload} onOpenPerson={openPerson} onNotice={setNotice} />}
    </>
  );

  return (
    <PhoneUi.Provider value={phoneUi}>
    <TodayTop.Provider value={phone ? <NeedsYouNow attention={attention} signals={signals} onGo={setPage} /> : null}>
    <div className="ba-root" data-pn-action={action ? "" : undefined} data-pn-pull={pullable ? "" : undefined}>
      {!phone && navOpen && <button type="button" className="zella-nav-backdrop" aria-label="Close menu" onClick={() => setNavOpenAt(null)} />}
      {!phone && <aside id="ba-sidebar" className={`ba-sidebar ${navOpen ? "open" : ""}`} aria-label="Main navigation">
        <SidebarBrand caption={`${nav.data?.industry?.name ?? workspace.industry ?? "Business"} CRM`} toggle={<DockToggle />} />

        {/* Only the menu scrolls: the logo stays at the top and the footer at the bottom */}
        <div className="ba-sidebar-scroll">
          {nav.status === "ready"
            ? <SidebarNav groups={groups} isActive={isActive} onOpen={openItem} badges={{ attention }} />
            : <SidebarState status={nav.status} error={nav.error} onRetry={nav.retry} />}
        </div>

        <div className="ba-sidebar-foot">
          <ReceptionistCard workspace={workspace} agent={agent} term={term} onTest={() => setModal("test-voice")} />
        </div>
      </aside>}

      {phone && (
        <SidePanel open={panelOpen} onClose={() => setNavOpenAt(null)}
          head={<SidebarBrand caption={`${nav.data?.industry?.name ?? workspace.industry ?? "Business"} CRM`} />}>
          <BusinessButton variant="card" workspace={workspace} config={nav.data} onClick={() => setPhoneSheet("switcher")} />
          {nav.status === "ready"
            ? <SidebarNav groups={groups} isActive={isActive} onOpen={(item) => { setNavOpenAt(null); openItem(item); }} badges={{ attention }} />
            : <SidebarState status={nav.status} error={nav.error} onRetry={nav.retry} />}
          <ReceptionistCard workspace={workspace} agent={agent} term={term} onTest={() => { setNavOpenAt(null); setModal("test-voice"); }} />
          <PanelAccount name={myName || email} detail={workspace.role} initials={(myName || email || "?").split(/[\s@]+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join("")}
            rows={[
              { label: "My profile", icon: "person", onClick: () => { setNavOpenAt(null); navigate(`${base}/settings/me/profile`); } },
              { label: "Password and security", icon: "lock", onClick: () => { setNavOpenAt(null); navigate(`${base}/settings/me/security`); } },
              { label: "Appearance and theme", icon: "palette", onClick: () => { setNavOpenAt(null); navigate(`${base}/settings/me/appearance`); } },
              { label: "Sign out", icon: "logout", onClick: () => { setNavOpenAt(null); onSignOut(); } },
            ]} />
        </SidePanel>
      )}

      <div className="ba-main" inert={panelOpen ? true : undefined}>
        {phone && (
          <PhoneTopBar searchOpen={searchOpen}
            actions={<>
              <button type="button" className="pn-iconbtn" aria-label={`Search ${searchLabel}`} aria-expanded={searchOpen} onClick={() => setSearchOpen((o) => !o)}>
                <Icon name={searchOpen ? "close" : "search"} />
              </button>
              <NotificationsBell workspace={workspace} onGo={goFromBell} needsNow={signals} />
            </>}
            search={(
              <label className="ba-search">
                <Icon name="search" size="sm" />
                <input autoFocus type="search" value={search} onChange={(e) => setSearch(e.target.value)} enterKeyHint="search"
                  onKeyDown={(e) => {
                    if (e.key === "Escape") setSearchOpen(false);
                    if (e.key === "Enter" && !searchable && search.trim()) setPage("customers");
                  }}
                  placeholder={`Search ${searchable ? searchLabel : term("customers").toLowerCase()}`} aria-label={`Search ${searchLabel}`} />
              </label>
            )}>
            <BusinessButton workspace={workspace} config={nav.data} expanded={phoneSheet === "switcher"} onClick={() => setPhoneSheet("switcher")} />
          </PhoneTopBar>
        )}
        {!phone && <header className="ba-header">
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
            <NotificationsBell workspace={workspace} needsNow={signals} onGo={(raw) => {
              const key = raw?.startsWith("settings/") ? raw : pageFor(raw);   // older keys such as on_call open their page
              if (canGo(key) || key?.startsWith("settings/")) setPage(key);
              else if (key) setNotice("That page isn't available with your access. Ask an owner or admin if you need it.");
            }} />
            {workspace.role !== "viewer" && (
              <button type="button" className="ba-btn primary" onClick={() => setModal("lead")} title="Add lead">
                <Icon name="person_add" /><span>Add lead</span>
              </button>
            )}
            {canBook && <button type="button" className="ba-btn" onClick={() => openBooking()} title={`New ${term("appointment").toLowerCase()}`}>
              <Icon name="event" /><span>New {term("appointment").toLowerCase()}</span>
            </button>}
            <ProfileMenu email={email} name={myName} role={workspace.role} onGo={(path) => navigate(`${base}/${path}`)} onSignOut={onSignOut} />
          </div>
        </header>}

        <main className="ba-content">
          {pullable && <PullIndicator distance={pull.distance} refreshing={pull.refreshing} />}
          <AppearanceSaveNotice />
          {signOutError && <p className="ba-error" role="alert">{signOutError}</p>}
          <ErrorBoundary resetKey={`${workspace.id}:${path}`}>
          {maintenance && <div className="ba-banner" role="status"><span>{maintenance}</span></div>}
          {workspace.cancel_at && !workspace.cancelled_at && (
            <div className="ba-banner">
              <span>
                Your Zella Voice plan ends on <strong>{formatLongDate(workspace.cancel_at, workspace.timezone)}</strong>.
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
          {attentionWarning(attentionState) && current.key !== "attention" && (
            <div className="ba-banner" role="status" data-attention={attentionState.status}>
              <span>
                {attentionState.status === "stale"
                  ? <>Couldn&apos;t refresh the callers waiting for a person. Showing the last count{attentionState.checkedAt ? ` from ${attentionState.checkedAt.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}` : ""}.</>
                  : <>Couldn&apos;t check whether any callers are waiting for a person.</>}
              </span>
              <button type="button" className="ba-btn sm" onClick={countAttention}>Try again</button>
            </div>
          )}
          {attention > 0 && current.key !== "attention" && !phone && (
            <div className="ba-banner alert" role="alert">
              <span><strong>{attention === 1 ? "1 caller needs" : `${attention} callers need`} a person.</strong> Your AI receptionist handed them over.</span>
              <button type="button" className="ba-btn primary sm" onClick={() => setPage("attention")}>Open</button>
            </div>
          )}
          {notice && !phone && (
            <div className="ba-banner success" role="status">
              <span>{notice}</span>
              <button type="button" className="ba-btn ghost sm" onClick={() => setNotice("")} aria-label="Dismiss">
                <Icon name="close" size="sm" />
              </button>
            </div>
          )}
          {error && <div className="ba-banner error">{error}</div>}
          <InviteBanner status={invites} email={email} onRetry={onReload} />
          {workspace.role === "owner" && (
            // if the banner's code can't load, say so without blocking the CRM (a new page load fetches it again)
            <ErrorBoundary resetKey={workspace.id} fallback={() => (
              <div className="ba-banner" role="status">
                <span>We couldn't check whether your setup is finished.</span>
                <button type="button" className="ba-btn sm" onClick={() => window.location.reload()}>Try again</button>
              </div>
            )}>
              <Suspense fallback={null}><OnboardingResumeBanner businessId={workspace.id} /></Suspense>
            </ErrorBoundary>
          )}

          {missing === "loading" && (phone ? <Skeleton label="Loading the page" /> : <p className="ba-muted">Loading…</p>)}
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
          {phone
            ? <>
              <TabStack tabs={tabs} active={onTab ? current.key : null} render={pageView} />
              {!onTab && pageView(current.key)}
            </>
            : pageView(current.key)}
          </ErrorBoundary>
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
      {modal === "task" && <NewTaskModal workspace={workspace} onClose={() => setModal(null)} onSaved={saved} />}

      {phone && (
        <PhoneBottom hidden={panelOpen}
          action={action && (
            <>
              <button type="button" className="ba-btn primary" onClick={action.onClick}><Icon name={action.icon} />{action.label}</button>
              {current.key === "today" && quick.length > 0 && (
                <button type="button" className="ba-btn pn-round" aria-label="Quick actions" aria-haspopup="dialog" onClick={() => setPhoneSheet("quick")}>
                  <Icon name="bolt" />
                </button>
              )}
            </>
          )}
          strip={strip && <LiveStrip {...strip} onAction={() => setPage("attention")} />}
          bar={(
            <BottomBar label="Main" tabs={tabs.map((t) => ({ ...t, count: t.key === inboxKey ? attention : 0, countNoun: "waiting" }))}
              selected={panelOpen ? "more" : selectedTab(tabs, current.key)} onSelect={selectTab}
              onMore={() => setNavOpenAt(panelOpen ? null : path)} moreOpen={panelOpen} moreCount={signals.spam} moreNoun="to review" />
          )} />
      )}
      {phone && <Toast toast={toaster.toast} onDismiss={toaster.dismiss} />}
      {phone && phoneSheet === "switcher" && (
        <SwitcherSheet workspace={workspace} workspaces={workspaces} canManage={["owner", "admin"].includes(workspace.role)}
          onSwitch={onSwitch} onGo={(p) => { setNavOpenAt(null); navigate(`${base}/${p}`); }} onClose={() => setPhoneSheet(null)} />
      )}
      {phone && phoneSheet === "quick" && <QuickActionsSheet actions={quick} onClose={() => setPhoneSheet(null)} />}
    </div>
    </TodayTop.Provider>
    </PhoneUi.Provider>
  );
}

function Loading({ text }) {
  return (
    <main className="ba-auth">
      <p className="ba-muted">{text}</p>
    </main>
  );
}

// What happened to this person's invitations at sign-in. Never blocks the workspaces they already have.
function InviteBanner({ status, email, onRetry }) {
  const [sent, setSent] = useState("");
  const [busy, setBusy] = useState(false);
  if (!status || (!status.failed && !status.needsEmailLink && !status.problems.length)) return null;
  async function sendLink() {
    setBusy(true); setSent("");
    try { await emailMeSignInLink(email); setSent(`We sent a sign in link to ${email}. Open it on this device to join.`); }
    catch (err) { setSent(err.message); }
    finally { setBusy(false); }
  }
  return (
    <div className="ba-banner" role="status">
      <span>
        {status.failed && "We couldn't finish adding you to a team you were invited to. "}
        {status.needsEmailLink > 0 && `${status.needsEmailLink === 1 ? "A team invitation is" : `${status.needsEmailLink} team invitations are`} waiting for you. To accept, sign in from the link in your invitation email, or get a new sign in link. `}
        {status.problems.map((p, i) => <span key={i}>An invitation couldn't be accepted: {p}. </span>)}
        {sent && <strong>{sent}</strong>}
      </span>
      <span style={{ display: "inline-flex", gap: 8 }}>
        {status.needsEmailLink > 0 && <button type="button" className="ba-btn primary sm" disabled={busy} onClick={sendLink}>{busy ? "Sending…" : "Email me a sign in link"}</button>}
        {status.failed && <button type="button" className="ba-btn sm" onClick={onRetry}>Try again</button>}
      </span>
    </div>
  );
}

function BusinessHome() {
  const [session, setSession] = useState(undefined);
  const [workspaces, setWorkspaces] = useState(null);
  // The business last opened on this device, so a refresh stays in it. Only a convenience: the list of businesses
  // comes from the server, and an id that isn't in it is ignored.
  // A link from an email names its business (?business=<id>): that one opens, if this person belongs to it (the list
  // below decides; any other id is ignored). The parameter is then taken out of the address. The id is also kept on
  // this device for 30 minutes, so it survives signing in first (Google and SSO come back to /app without it, and a
  // sign in link may open in a new tab); it is cleared once the person's businesses have loaded.
  // This tab's own link always wins over the device hint, which another tab may have written since.
  const [linkedHere] = useState(() => {
    const fromLink = new URLSearchParams(window.location.search).get("business");
    if (!fromLink || !/^[0-9a-f-]{36}$/i.test(fromLink)) return null;
    const url = new URL(window.location.href); url.searchParams.delete("business");
    window.history.replaceState(window.history.state, "", url.pathname + url.search + url.hash);
    rememberLinkBusiness(fromLink.toLowerCase());
    return fromLink.toLowerCase();
  });
  const [selectedId, setSelectedIdRaw] = useState(() => {
    if (linkedHere) return linkedHere;
    const pending = linkBusiness();
    if (pending) return pending;
    try { return localStorage.getItem(LAST_BUSINESS); } catch { return null; }
  });
  // Read once at the start: the business this tab was opened for (its own link, or the hint from before signing in).
  // Used by the first load of the businesses only; after that the person's own choice stands.
  const [initialOpenedFor] = useState(() => linkedHere ?? linkBusiness());
  const openedFor = useRef(initialOpenedFor);
  const setSelectedId = (next) => setSelectedIdRaw((current) => {
    const id = typeof next === "function" ? next(current) : next;
    try { if (id) localStorage.setItem(LAST_BUSINESS, id); } catch { /* private mode */ }
    return id;
  });
  const [error, setError] = useState("");
  const [signOutError, setSignOutError] = useState("");
  const [isAdmin, setIsAdmin] = useState(false);
  const [invites, setInvites] = useState(null);

  const loadWorkspaces = useCallback(async () => {
    setError("");
    // Activates any invitation this person hasn't accepted yet (safe to repeat); problems are shown, not hidden.
    try { setInvites(await acceptInvitations()); }
    catch (err) { console.error("Accepting invitations failed:", err); setInvites({ accepted: 0, needsEmailLink: 0, problems: [], failed: true }); }

    const { data, error: loadError } = await supabase.rpc("zella_my_workspaces");
    if (loadError) {
      setError(loadError.message);
      setWorkspaces([]);
      return;
    }
    if (!(data ?? []).length) {
      // A Zella Voice admin without a business of their own belongs in the admin dashboard.
      const { data: admin } = await supabase.rpc("is_platform_admin");
      setIsAdmin(admin === true);
    }
    setWorkspaces(data ?? []);
    const linked = openedFor.current;
    openedFor.current = null;
    if (linked && linkBusiness() === linked) forgetLinkBusiness();   // leave another tab's newer hint alone
    setSelectedId((current) => {
      const want = linked ?? current;
      if ((data ?? []).some((w) => w.id === want)) return want;
      return (data ?? []).some((w) => w.id === current) ? current : data?.[0]?.id ?? null;
    });
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

  // Signs out. If the server can't be reached, the session is still cleared on this device; if even that fails, the
  // person is told, and the screen does not claim they are signed out.
  async function signOut() {
    setSignOutError("");
    let failed = false;
    try { const { error: e } = await supabase.auth.signOut(); if (e) failed = true; } catch { failed = true; }
    if (failed) {
      try { const { error: e } = await supabase.auth.signOut({ scope: "local" }); if (e) throw e; }
      catch {
        setSignOutError("We couldn't sign you out. Your session may still be active on this device. Check your connection and try again.");
        return false;
      }
    }
    setWorkspaces(null);
  }

  if (session === undefined) return <Loading text="Loading..." />;
  if (!session) return <BusinessSignIn />;
  if (mfa.state === "checking") return <Loading text="Loading..." />;
  if (mfa.state === "needs_code") return <MfaCodeCard email={session.user.email} onDone={mfa.recheck} />;
  if (mfa.state === "error") return (
    <main className="ba-auth">
      <section className="ba-auth-card" role="alert">
        <h1>Couldn't verify sign in</h1>
        <p className="ba-auth-description">Your sign in security check failed. Try again to open your workspace.</p>
        <button type="button" className="ba-btn primary block" onClick={mfa.recheck}>Try again</button>
        <button type="button" className="ba-btn block" onClick={signOut}>Sign out</button>
        {signOutError && <p className="ba-error" role="alert">{signOutError}</p>}
      </section>
    </main>
  );
  if (workspaces === null) return <Loading text="Loading your workspace..." />;

  if (!workspaces.length) {
    return (
      <main className="ba-auth">
        <section className="ba-auth-card">
          <div className="ba-brand">
            <div className="ba-logo">Z</div>
            <div className="ba-brand-name">Zella Voice</div>
          </div>
          <h1>{isAdmin ? "You're a Zella Voice admin" : "No workspace yet"}</h1>
          <p className="ba-auth-description">
            {error
              ? `Your workspace couldn't be loaded: ${error}`
              : isAdmin
                ? `${session.user.email} manages Zella Voice from the admin dashboard and isn't linked to a business here.`
                : `${session.user.email} isn't linked to a Zella Voice business yet. If you were invited, open the link in your invitation email first, or ask the Zella Voice team to resend it.`}
          </p>
          <InviteBanner status={invites} email={session.user.email} onRetry={loadWorkspaces} />
          {isAdmin && <a className="ba-btn primary block" href="/">Open the admin dashboard</a>}
          <button type="button" className="ba-btn block" onClick={signOut}>Sign out</button>
          {signOutError && <p className="ba-error" role="alert">{signOutError}</p>}
        </section>
      </main>
    );
  }

  const workspace = workspaces.find((w) => w.id === selectedId) ?? workspaces[0];
  if (workspace.cancelled_at || workspace.suspended_at) return <Blocked workspace={workspace} onSignOut={signOut} signOutError={signOutError} />;

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
      signOutError={signOutError}
      onReload={loadWorkspaces}
      invites={invites}
    />
  );
}

// Look-only preview of the workspace without signing in. It exists only
// while running locally (npm run dev) and is removed from production builds.
// It has no data and cannot save anything, because there is no signed-in user.
const LAST_BUSINESS = "zella.lastBusiness";
// The business named by an email link, kept across signing in (BusinessHome). Only a hint: the server's list decides.
const LINK_BUSINESS = "zella.linkBusiness";
const LINK_BUSINESS_MS = 30 * 60 * 1000;
function rememberLinkBusiness(id) {
  try { localStorage.setItem(LINK_BUSINESS, JSON.stringify({ id, at: Date.now() })); } catch { /* private mode: the link still opens it now */ }
}
function linkBusiness() {
  try {
    const v = JSON.parse(localStorage.getItem(LINK_BUSINESS) ?? "null");
    return v && typeof v.id === "string" && /^[0-9a-f-]{36}$/.test(v.id) && Date.now() - Number(v.at) < LINK_BUSINESS_MS ? v.id : null;
  } catch { return null; }
}
function forgetLinkBusiness() {
  try { localStorage.removeItem(LINK_BUSINESS); } catch { /* nothing to clear */ }
}

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
      email="preview@zellavoice.com"
      base="/app/preview"
      onSignOut={() => { window.location.href = "/app"; }}
      onReload={() => {}}
      navPreview={PREVIEW_NAV}
    />
  );
}

// The owner onboarding journey, loaded only when it is opened (web/src/onboarding/).
const OwnerOnboarding = lazy(() => import("./onboarding/OwnerOnboarding"));
// For an owner who left the journey part way: a way back to the same step. Shows nothing until the server says so.
const OnboardingResumeBanner = lazy(() => import("./onboarding/ResumeBanner"));

export default function BusinessApp() {
  const path = window.location.pathname;
  if (/^\/welcome\/setup\/?$/.test(path)) return <Suspense fallback={<Loading text="Loading..." />}><OwnerOnboarding /></Suspense>;
  if (path.startsWith("/welcome")) return <Welcome />;
  if (import.meta.env.DEV && path.startsWith("/app/preview")) return <Preview />;
  return <BusinessHome />;
}
