import { SidebarBrand } from "./navigation/SidebarBrand";
import { useCallback, useEffect, useRef, useState } from "react";
import { AppearanceSaveNotice } from "./AppearanceSaveNotice";
import { ErrorBoundary, Icon, loadBusinessFonts } from "./BusinessUI";
import { DockToggle } from "./navigation/DockToggle";
import "./OwnerDashboard.css";
import CreateBusinessWizard, { callOwnerFunction } from "./CreateBusinessWizard";
import OwnerOverview from "./OwnerOverview";
import BusinessDetails from "./BusinessDetails";
import AuditLogs from "./AuditLogs";
import IndustryConfiguration from "./IndustryConfiguration";
import AIAgents from "./AIAgents";
import UsersAccess from "./UsersAccess";
import IntegrationsPage from "./IntegrationsPage";
import SupportTickets from "./SupportTickets";
import PlansPage from "./PlansPage";
import PlatformOperations from "./PlatformOperations";
import SettingsPage from "./SettingsPage";
import VoiceNumbersPage from "./admin/VoiceNumbersPage";
import MessagingPage from "./admin/MessagingPage";
import AutomationsPage from "./admin/AutomationsPage";
import ModulesPage from "./ModulesPage";
import OffersPage from "./OffersPage";
import VerificationQueue from "./VerificationQueue";
import SecurityAbuse from "./SecurityAbuse";
import AdminAlertsBell from "./AdminAlertsBell";
import { supabase } from "./supabase";
import BusinessesPage, { useBusinessList } from "./BusinessesPage";
import { navigate, segments, usePath } from "./router";
import { maintenanceText, usePlatformInfo } from "./platformInfo";
import { ACCESS, hasPermission, useAdminAccess } from "./adminPermissions";
import { friendlyError } from "./admin/adminOps";

loadBusinessFonts();

// The admin sidebar. `label` is the page's key (addresses and links use it); `title`, when set, is how it is shown
// (sentence case, docs/ZELLA_PRODUCT_VOICE.md). Each page lists the permission it needs (the same one the server checks for its data), so an
// admin with a restricted role only sees pages they can use. Items with `tabs` take a tab in the address (<path>/<tab>).
const NAVIGATION = [
  { label: "Overview", icon: "space_dashboard", path: "/", group: null, perm: "businesses.view" },
  { label: "Businesses", icon: "storefront", path: "/businesses", group: "Businesses", perm: "businesses.view" },
  { label: "Verification", icon: "verified_user", path: "/verification", group: "Businesses", perm: "businesses.manage" },
  { label: "Industry Configuration", title: "Industry configuration", icon: "category", path: "/industries", group: "Configuration", perm: "businesses.view" },
  { label: "Modules & Features", title: "Modules & features", icon: "widgets", path: "/modules", group: "Configuration", perm: "businesses.view" },
  { label: "Plans & Subscriptions", title: "Plans & subscriptions", icon: "credit_card", path: "/plans", group: "Configuration", perm: "billing.view" },
  { label: "Offers & Promotions", title: "Offers & promotions", icon: "sell", path: "/offers", group: "Configuration", perm: "billing.view" },
  { label: "AI Agents", title: "AI receptionists", icon: "smart_toy", path: "/agents", group: "AI & communications", perm: "businesses.view" },
  { label: "Voice & numbers", icon: "call", path: "/voice", tabs: true, group: "AI & communications", perm: "businesses.view" },
  { label: "Messaging", icon: "forum", path: "/messaging", tabs: true, group: "AI & communications", perm: "businesses.view" },
  { label: "Platform Operations", title: "Platform operations", icon: "monitor_heart", path: "/operations", group: "Operations", perm: "businesses.view" },
  { label: "Automations", icon: "bolt", path: "/automations", tabs: true, group: "Operations", perm: "businesses.view" },
  { label: "Integrations", icon: "hub", path: "/integrations", group: "Operations", perm: "businesses.view" },
  { label: "Support", icon: "support_agent", path: "/support", group: "Operations", perm: "support.manage" },
  { label: "Security & Abuse", title: "Security & abuse", icon: "gpp_maybe", path: "/security-abuse", group: "Operations", perm: "security.view" },
  { label: "Users & Access", title: "Users & access", icon: "group", path: "/users", group: "Administration", perm: "security.view" },
  { label: "Audit Logs", title: "Audit logs", icon: "history", path: "/audit-logs", group: "Administration", perm: "audit.view" },
  { label: "Settings", icon: "settings", path: "/settings", group: "Administration", perm: null },
];
const NAV_GROUPS = [null, "Businesses", "Configuration", "AI & communications", "Operations", "Administration"];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Which page, business and setup wizard the address shows.
//   /businesses/new             new business wizard
//   /businesses/<id>            business details
//   /businesses/<id>/setup      setup wizard for that business
//   /settings/<section>         a Settings category
// Anything else unknown shows "Page not found".
function readRoute(path) {
  const [first = "", second, third] = segments(path);
  const item = NAVIGATION.find((n) => n.path && n.path === `/${first}`);
  if (!item) return { activePage: null, wizard: null, detailId: null, section: null, sub: null };
  const route = { activePage: item.label, wizard: null, detailId: null, section: null, sub: null };
  if (item.label === "Businesses" && second) {
    if (second === "new" && !third) route.wizard = { businessId: null };
    else if (UUID_RE.test(second) && !third) route.detailId = second;
    else if (UUID_RE.test(second) && third === "setup") route.wizard = { businessId: second };
    else route.activePage = null;
  } else if (item.label === "Settings" && second) {
    route.section = second;
    route.sub = third ?? null;
  } else if (item.tabs && second && !third) {
    route.sub = second;
  } else if (second) {
    route.activePage = null;
  }
  return route;
}

const loadAdminAccess = () => callOwnerFunction("me_admin");
const pathFor = (label) => NAVIGATION.find((n) => n.label === label)?.path ?? "/";

export default function OwnerDashboard({ onSignOut }) {
  const path = usePath();
  // Permissions first: nothing below loads or shows protected data before they have (see the note further down).
  const { access, retry: retryAccess } = useAdminAccess(loadAdminAccess, supabase.auth);
  const me = access.me;
  const authorized = access.state === ACCESS.AUTHORIZED;
  const notice = maintenanceText(usePlatformInfo());
  const { activePage, wizard, detailId, section, sub } = readRoute(path);
  const setActivePage = (label) => navigate(pathFor(label));
  const setDetailId = (id) => navigate(id ? `/businesses/${id}` : "/businesses");
  const setWizard = (next) => navigate(next
    ? next.businessId ? `/businesses/${next.businessId}/setup` : "/businesses/new"
    : detailId ? `/businesses/${detailId}` : pathFor(activePage ?? "Businesses"));
  const [search, setSearch] = useState("");
  // The Businesses list (BusinessesPage.jsx): its state lives here so it survives going to another page and back.
  const businessList = useBusinessList({
    active: activePage === "Businesses" && !wizard && !detailId && hasPermission(access, "businesses.view"),
    authorized, search,
  });

  // The setup wizard's industry list. dashboard_data keeps its shape for this (and for Offers), on old and new servers.
  const [industries, setIndustries] = useState([]);
  const [industryError, setIndustryError] = useState("");
  const [loadingIndustries, setLoadingIndustries] = useState(false);
  const [industriesLoaded, setIndustriesLoaded] = useState(false);
  const industryEpoch = useRef(0);
  const industryRequest = useRef(0);
  const loadIndustries = useCallback(async () => {
    const epoch = industryEpoch.current;
    const request = ++industryRequest.current;
    setLoadingIndustries(true);
    try {
      const data = await callOwnerFunction("dashboard_data");
      if (epoch !== industryEpoch.current || request !== industryRequest.current) return;
      setIndustries(Array.isArray(data.industries) ? data.industries : []);
      setIndustryError("");
      setIndustriesLoaded(true);
    } catch (error) {
      if (epoch !== industryEpoch.current || request !== industryRequest.current) return;
      console.error("Industry list loading failed:", error);
      setIndustryError(friendlyError(error) || "Could not load industries. Please try again.");
    } finally {
      if (epoch === industryEpoch.current && request === industryRequest.current) setLoadingIndustries(false);
    }
  }, []);

  // Signed out, switching account or re-checking access: drop what was loaded for the earlier session.
  useEffect(() => {
    if (authorized) return;
    industryEpoch.current++;
    setIndustries([]); setIndustryError(""); setIndustriesLoaded(false); setLoadingIndustries(false);
  }, [authorized]);

  // The setup wizard needs the industry list even when opened from Overview. Load once per opening: a successful load
  // with no industries must not trigger another request.
  useEffect(() => {
    if (wizard && hasPermission(access, "businesses.manage") && !industriesLoaded && !loadingIndustries && !industryError) {
      loadIndustries();
    }
  }, [wizard, access, industriesLoaded, loadingIndustries, industryError, loadIndustries]);

  const isBusinesses = activePage === "Businesses";

  function goTo(page) {
    navigate(pathFor(page));
  }

  // Who is signed in: their role and permissions decide which pages the sidebar offers. The server checks the same
  // permission for every action, so hiding a page is a convenience, never the protection. Until the permissions have
  // loaded, or if loading them fails, nothing protected is shown (adminPermissions.js).
  const [email, setEmail] = useState("");
  useEffect(() => {
    let live = true;
    supabase.auth.getUser().then(({ data }) => live && setEmail(data?.user?.email ?? ""));
    return () => { live = false; };
  }, [me]);
  const can = (perm) => hasPermission(access, perm);
  const allowed = (item) => can(item.perm);
  const isCurrent = (item) => activePage === item.label;
  // A direct link to a page this role can't use says so, instead of drawing a page whose every action would fail.
  const currentItem = NAVIGATION.find((n) => n.label === activePage);
  const blocked = authorized && ((wizard && !can("businesses.manage")) || (!wizard && detailId && !can("businesses.view"))
    || (!wizard && currentItem && !allowed(currentItem)));

  // ⌘K / Ctrl+K jumps to the business search, as the hint in the search box says.
  const searchBox = useRef(null);
  useEffect(() => {
    const onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); searchBox.current?.focus(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // Phone-width menu: the sidebar opens as a drawer and closes as soon as the address changes.
  const [navOpenAt, setNavOpenAt] = useState(null);
  const navOpen = navOpenAt === path;
  useEffect(() => {
    if (!navOpen) return undefined;
    const onKey = (e) => { if (e.key === "Escape") setNavOpenAt(null); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [navOpen]);

  return (
    <div className="owner-app">
      {navOpen && <button type="button" className="zella-nav-backdrop" aria-label="Close menu" onClick={() => setNavOpenAt(null)} />}
      {/* The column carries the sidebar's background and border down the whole page; only the nav inside is sticky. */}
      <div className="owner-sidebar-col">
      <aside id="owner-sidebar" className={`owner-sidebar ${navOpen ? "open" : ""}`} aria-label="Main navigation">
        <SidebarBrand caption="Platform control" toggle={<DockToggle />} />

        <div className="owner-workspace">
          <div className="owner-workspace-icon">Z</div>
          <div className="owner-workspace-copy">
            <strong>Zella Voice Platform</strong>
            <span>{me?.roleLabel ?? (access.state === ACCESS.LOADING ? "Loading role…" : "Role not loaded")}</span>
          </div>
        </div>

        <nav className="owner-nav" aria-label="Admin pages">
          {NAV_GROUPS.map((group) => {
            const items = NAVIGATION.filter((item) => item.group === group && allowed(item));
            if (!items.length) return null;
            return (
              <div key={group ?? "top"} className="owner-nav-group">
                {group && <div className="owner-nav-label">{group}</div>}
                {items.map((item) => (
                  <button
                    key={item.label}
                    type="button"
                    className={`owner-nav-item ${isCurrent(item) ? "active" : ""}`}
                    onClick={() => goTo(item.label)}
                    title={item.title ?? item.label}
                    aria-current={isCurrent(item) ? "page" : undefined}
                  >
                    <span className="owner-nav-icon"><Icon name={item.icon} /></span>
                    <span>{item.title ?? item.label}</span>
                  </button>
                ))}
              </div>
            );
          })}
        </nav>

        {can("businesses.view") && <button type="button" className="owner-sidebar-bottom op-status-link" onClick={() => goTo("Platform Operations")}
          aria-label="Platform status: view system health" title="Platform status">
          <div className="owner-status-dot" />
          <div>
            <strong>Platform status</strong>
            <span>View system health</span>
          </div>
        </button>}
      </aside>
      </div>

      <main className="owner-main">
        <header className="owner-topbar">
          <button type="button" className="owner-icon-button zella-menu-btn owner-menu-btn" aria-label="Open menu" aria-controls="owner-sidebar" aria-expanded={navOpen}
            onClick={() => setNavOpenAt(navOpen ? null : path)}>
            <Icon name="menu" />
          </button>
          <div className="owner-breadcrumb">
            <span>Platform</span>
            <span>/</span>
            <strong>{activePage ? (currentItem?.title ?? activePage) : "Page not found"}</strong>
          </div>

          <div className="owner-top-actions">
            {can("businesses.view") && <div className="owner-search">
              <Icon name="search" size="sm" />
              <input
                ref={searchBox}
                value={search}
                onChange={(event) => {
                  setSearch(event.target.value);
                  if (event.target.value.trim() && !wizard && (activePage !== "Businesses" || detailId)) {
                    goTo("Businesses");
                  }
                }}
                placeholder="Search businesses..."
                aria-label="Search businesses"
              />
              <kbd>⌘ K</kbd>
            </div>}
            {can("businesses.view") && <AdminAlertsBell onOpenMonitoring={() => goTo("Platform Operations")} />}
            <button className="owner-icon-button" type="button" aria-label="Appearance and theme" title="Appearance and theme"
              onClick={() => navigate("/settings/profile/appearance")}>
              <Icon name="palette" />
            </button>
            <div className="owner-avatar" title={[email, me?.roleLabel].filter(Boolean).join(" · ") || "Platform admin"}>
              {(email || "A").slice(0, 1).toUpperCase()}
            </div>
            <button className="owner-signout" type="button" onClick={onSignOut}>
              Sign out
            </button>
          </div>
        </header>

        <div className="owner-content">
          <AppearanceSaveNotice />
          <ErrorBoundary resetKey={path}>
          {notice && <div className="owner-form-error op-gap" role="status">{notice}</div>}
          {access.state === ACCESS.LOADING ? (
            <div className="owner-empty-state" role="status" aria-busy="true" data-access="loading">
              <strong>Checking your access…</strong>
              <p>Your admin pages appear once your role has loaded.</p>
            </div>
          ) : access.state === ACCESS.FAILED ? (
            <div className="owner-empty-state" role="alert" data-access="failed">
              <strong>Your admin permissions couldn't be loaded</strong>
              <p>Nothing is shown until they are. Check your connection and try again.</p>
              <button type="button" className="owner-primary-button" onClick={retryAccess}>Retry</button>
            </div>
          ) : access.state === ACCESS.UNAUTHORIZED ? (
            <div className="owner-empty-state" role="alert" data-access="unauthorized">
              <strong>No admin access</strong>
              <p>{access.reason === "MFA_REQUIRED" ? "Enter the code from your authenticator app: sign out and sign in again."
                : "This account isn't allowed to use the Zella Voice admin, or its access has changed. Sign out and sign in with an admin account, or ask a Zella Voice owner."}</p>
              <button type="button" className="owner-primary-button" onClick={onSignOut}>Sign out</button>
            </div>
          ) : blocked ? (
            <div className="owner-empty-state" role="status" data-access="denied">
              <strong>This page isn't available</strong>
              <p>Your admin role ({me?.roleLabel ?? "restricted"}) doesn't include it. Ask a Zella Voice owner if you need access.</p>
            </div>
          ) : wizard ? (
            <CreateBusinessWizard
              key={wizard.businessId || "new"}
              businessId={wizard.businessId}
              industries={industries}
              industryError={industryError}
              onRetryIndustries={loadIndustries}
              loadingIndustries={loadingIndustries}
              onClose={() => navigate(wizard.businessId ? `/businesses/${wizard.businessId}` : "/businesses")}
            />
          ) : detailId ? (
            <BusinessDetails
              key={detailId}
              businessId={detailId}
              onBack={() => navigate("/businesses")}
              onOpenSetup={(id) => setWizard({ businessId: id })}
              can={can}
            />
          ) : activePage === "Overview" ? (
            <OwnerOverview
              onCreateBusiness={can("businesses.manage") ? () => setWizard({ businessId: null }) : null}
              onOpenBusiness={setDetailId}
              onContinueSetup={can("businesses.manage") ? (id) => setWizard({ businessId: id }) : null}
              onNavigate={setActivePage}
            />
          ) : activePage === "Verification" ? (
            <VerificationQueue onOpenBusiness={setDetailId} onOpenSetup={(id) => setWizard({ businessId: id })} />
          ) : activePage === "Security & Abuse" ? (
            <SecurityAbuse permissions={me?.permissions ?? []} onOpenBusiness={setDetailId} />
          ) : activePage === "Audit Logs" ? (
            <AuditLogs onOpenBusiness={setDetailId} />
          ) : activePage === "Industry Configuration" ? (
            <IndustryConfiguration />
          ) : activePage === "AI Agents" ? (
            <AIAgents
              onOpenBusiness={setDetailId}
              onOpenSetup={(id) => setWizard({ businessId: id })}
            />
          ) : activePage === "Modules & Features" ? (
            <ModulesPage onNavigate={goTo} />
          ) : activePage === "Users & Access" ? (
            <UsersAccess />
          ) : activePage === "Integrations" ? (
            <IntegrationsPage onOpenBusiness={setDetailId} />
          ) : activePage === "Support" ? (
            <SupportTickets onOpenBusiness={setDetailId} />
          ) : activePage === "Plans & Subscriptions" ? (
            <PlansPage onOpenBusiness={setDetailId} />
          ) : activePage === "Offers & Promotions" ? (
            <OffersPage onOpenBusiness={setDetailId} />
          ) : activePage === "Platform Operations" ? (
            <PlatformOperations onNavigate={goTo} onOpenBusiness={setDetailId} />
          ) : activePage === "Voice & numbers" ? (
            <VoiceNumbersPage me={me} sub={sub} onOpenBusiness={setDetailId} />
          ) : activePage === "Messaging" ? (
            <MessagingPage me={me} sub={sub} onOpenBusiness={setDetailId} />
          ) : activePage === "Automations" ? (
            <AutomationsPage me={me} sub={sub} onOpenBusiness={setDetailId} />
          ) : activePage === "Settings" ? (
            <SettingsPage onNavigate={goTo} section={section} sub={sub} onSignOut={onSignOut}
              onOpenBusiness={setDetailId} onOpenSetup={(id) => setWizard({ businessId: id })} />
          ) : isBusinesses ? (
            <BusinessesPage
              state={businessList}
              search={search}
              onSearch={setSearch}
              canManage={can("businesses.manage")}
              onCreate={() => setWizard({ businessId: null })}
              onOpen={setDetailId}
              onSetup={(id) => setWizard({ businessId: id })}
            />
          ) : (
            <section className="owner-page">
              <div className="owner-eyebrow">Platform control center</div>
              <h1>Page not found</h1>
              <p className="owner-page-description">
                There's no admin page at this address. It may have moved, or the link may be incomplete.
              </p>
              <div className="owner-panel owner-overview-panel">
                <button type="button" className="owner-primary-button" onClick={() => goTo("Overview")}>
                  Go to Overview <span>→</span>
                </button>
              </div>
            </section>
          )}
          </ErrorBoundary>
        </div>
      </main>

    </div>
  );
}
