import { useCallback, useEffect, useRef, useState } from "react";
import { Icon, loadBusinessFonts } from "./BusinessUI";
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
import ModulesPage from "./ModulesPage";
import OffersPage from "./OffersPage";
import VerificationQueue from "./VerificationQueue";
import SecurityAbuse from "./SecurityAbuse";
import AdminAlertsBell from "./AdminAlertsBell";
import { supabase } from "./supabase";
import { Pill } from "./OwnerOverview";
import { businessState } from "./ownerFormat";
import { navigate, segments, usePath } from "./router";
import { maintenanceText, usePlatformInfo } from "./platformInfo";

const STATE_FILTERS = [
  ["all", "All businesses"],
  ["draft", "Draft"],
  ["complete", "Setup complete"],
  ["live", "Live"],
  ["cancelling", "Cancelling"],
  ["suspended", "Suspended"],
  ["cancelled", "Cancelled"],
];

function matchesState(business, filter) {
  if (filter === "all") return true;
  const state = businessState(business);
  if (filter === "cancelling") return Boolean(state.cancelling);
  return state.key === filter;
}

loadBusinessFonts();

// Invitation states as badges: the label says it, the colour backs it up.
const INVITE_TONE = { accepted: "success", sent: "warning", pending: "warning", failed: "danger", expired: "danger", revoked: "neutral" };
const words = (s) => String(s ?? "").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());

// The admin sidebar. Each page lists the permission it needs (the same one the server checks for its data), so an
// admin with a restricted role only sees pages they can use. Items with `settings` open a Settings page directly.
const NAVIGATION = [
  { label: "Overview", icon: "space_dashboard", path: "/", group: null, perm: "businesses.view" },
  { label: "Businesses", icon: "storefront", path: "/businesses", group: "Businesses", perm: "businesses.view" },
  { label: "Verification", icon: "verified_user", path: "/verification", group: "Businesses", perm: "businesses.manage" },
  { label: "Industry Configuration", icon: "category", path: "/industries", group: "Configuration", perm: "businesses.view" },
  { label: "Modules & Features", icon: "widgets", path: "/modules", group: "Configuration", perm: "businesses.view" },
  { label: "Plans & Subscriptions", icon: "credit_card", path: "/plans", group: "Configuration", perm: "billing.view" },
  { label: "Offers & Promotions", icon: "sell", path: "/offers", group: "Configuration", perm: "billing.view" },
  { label: "AI Agents", icon: "smart_toy", path: "/agents", group: "AI & communications", perm: "businesses.view" },
  { label: "Voice & numbers", icon: "call", settings: "voice/numbers", group: "AI & communications", perm: "businesses.view" },
  { label: "Messaging", icon: "forum", settings: "comms/sms", group: "AI & communications", perm: "businesses.view" },
  { label: "Platform Operations", icon: "monitor_heart", path: "/operations", group: "Operations", perm: "businesses.view" },
  { label: "Automations", icon: "bolt", settings: "integrations/n8n", group: "Operations", perm: "businesses.view" },
  { label: "Integrations", icon: "hub", path: "/integrations", group: "Operations", perm: "businesses.view" },
  { label: "Support", icon: "support_agent", path: "/support", group: "Operations", perm: "support.manage" },
  { label: "Security & Abuse", icon: "gpp_maybe", path: "/security-abuse", group: "Operations", perm: "security.view" },
  { label: "Users & Access", icon: "group", path: "/users", group: "Administration", perm: "security.view" },
  { label: "Audit Logs", icon: "history", path: "/audit-logs", group: "Administration", perm: "audit.view" },
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
  } else if (second) {
    route.activePage = null;
  }
  return route;
}

const pathFor = (label) => NAVIGATION.find((n) => n.label === label)?.path ?? "/";

export default function OwnerDashboard({ onSignOut }) {
  const path = usePath();
  const notice = maintenanceText(usePlatformInfo());
  const { activePage, wizard, detailId, section, sub } = readRoute(path);
  const setActivePage = (label) => navigate(pathFor(label));
  const setDetailId = (id) => navigate(id ? `/businesses/${id}` : "/businesses");
  const setWizard = (next) => navigate(next
    ? next.businessId ? `/businesses/${next.businessId}/setup` : "/businesses/new"
    : detailId ? `/businesses/${detailId}` : pathFor(activePage ?? "Businesses"));
  const [search, setSearch] = useState("");
  const [stateFilter, setStateFilter] = useState("all");
  const [businesses, setBusinesses] = useState([]);
  const [industries, setIndustries] = useState([]);
  const [stats, setStats] = useState({
    totalBusinesses: 0,
    activeWorkspaces: 0,
    pendingInvitations: 0,
    provisioningIssues: 0,
});
  const [loadingBusinesses, setLoadingBusinesses] = useState(false);
  const [businessError, setBusinessError] = useState("");
const loadDashboardData = useCallback(async () => {
  setLoadingBusinesses(true);
  setBusinessError("");

  try {
    const data = await callOwnerFunction("dashboard_data");

    setBusinesses(data.businesses ?? []);
    setIndustries(data.industries ?? []);
    setStats(data.stats ?? {
      totalBusinesses: 0,
      activeWorkspaces: 0,
      pendingInvitations: 0,
      provisioningIssues: 0,
    });
  } catch (error) {
    console.error("Dashboard data loading failed:", error);
    setBusinessError(
      error.message || "Could not load businesses. Please try again."
    );
  } finally {
    setLoadingBusinesses(false);
  }
}, []);

useEffect(() => {
  if (activePage === "Businesses") {
    loadDashboardData();
  }
}, [activePage, loadDashboardData]);

// The setup wizard needs the industry list even when opened from Overview.
useEffect(() => {
  if (wizard && industries.length === 0 && !loadingBusinesses && !businessError) {
    loadDashboardData();
  }
}, [wizard, industries.length, loadingBusinesses, businessError, loadDashboardData]);


  const isBusinesses = activePage === "Businesses";

  const visibleBusinesses = businesses.filter((business) => {
    if (!matchesState(business, stateFilter)) return false;
    const query = search.trim().toLowerCase();
    if (!query) return true;
    const industry = industries.find((item) => item.id === business.industry_id);
    const invitation = business.invitations?.[0];
    return [business.name, industry?.name, invitation?.owner_name, invitation?.email, business.phone]
      .some((value) => String(value ?? "").toLowerCase().includes(query));
  });

  function goTo(page) {
    const item = NAVIGATION.find((n) => n.label === page);
    navigate(item?.settings ? `/settings/${item.settings}` : pathFor(page));
  }

  // Who is signed in: their role and permissions decide which pages the sidebar offers. The server checks the same
  // permission for every action, so hiding a page is a convenience, never the protection.
  const [me, setMe] = useState(null);
  const [meFailed, setMeFailed] = useState(false);
  const [email, setEmail] = useState("");
  useEffect(() => {
    let live = true;
    callOwnerFunction("me_admin").then((m) => live && setMe(m)).catch(() => live && setMeFailed(true));
    supabase.auth.getUser().then(({ data }) => live && setEmail(data?.user?.email ?? ""));
    return () => { live = false; };
  }, []);
  const allowed = (item) => !item.perm || meFailed || Boolean(me?.permissions?.includes(item.perm));
  const isCurrent = (item) => item.settings
    ? activePage === "Settings" && `${section}/${sub}` === item.settings
    : activePage === item.label && !(item.label === "Settings" && NAVIGATION.some((n) => n.settings === `${section}/${sub}`));

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
      <aside id="owner-sidebar" className={`owner-sidebar ${navOpen ? "open" : ""}`} aria-label="Main navigation">
        <div className="owner-brand">
          <div className="owner-brand-mark">Z</div>
          <div>
            <div className="owner-brand-name">Zella <span>AI</span></div>
            <div className="owner-brand-caption">Platform control</div>
          </div>
        </div>

        <div className="owner-workspace">
          <div className="owner-workspace-icon">Z</div>
          <div className="owner-workspace-copy">
            <strong>Zella Platform</strong>
            <span>{me?.roleLabel ?? (meFailed ? "Platform admin" : "Loading role…")}</span>
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
                    title={item.label}
                    aria-current={isCurrent(item) ? "page" : undefined}
                  >
                    <span className="owner-nav-icon"><Icon name={item.icon} /></span>
                    <span>{item.label}</span>
                  </button>
                ))}
              </div>
            );
          })}
        </nav>

        <button type="button" className="owner-sidebar-bottom op-status-link" onClick={() => goTo("Platform Operations")}>
          <div className="owner-status-dot" />
          <div>
            <strong>Platform status</strong>
            <span>View system health</span>
          </div>
        </button>
        <DockToggle />
      </aside>

      <main className="owner-main">
        <header className="owner-topbar">
          <button type="button" className="owner-icon-button zella-menu-btn owner-menu-btn" aria-label="Open menu" aria-controls="owner-sidebar" aria-expanded={navOpen}
            onClick={() => setNavOpenAt(navOpen ? null : path)}>
            <Icon name="menu" />
          </button>
          <div className="owner-breadcrumb">
            <span>Platform</span>
            <span>/</span>
            <strong>{NAVIGATION.find((n) => n.settings && isCurrent(n))?.label ?? activePage ?? "Page not found"}</strong>
          </div>

          <div className="owner-top-actions">
            <div className="owner-search">
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
            </div>
            <AdminAlertsBell onOpenMonitoring={() => goTo("Platform Operations")} />
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
          {notice && <div className="owner-form-error op-gap" role="status">{notice}</div>}
          {wizard ? (
            <CreateBusinessWizard
              key={wizard.businessId || "new"}
              businessId={wizard.businessId}
              industries={industries}
              onClose={(changed) => {
                navigate(wizard.businessId ? `/businesses/${wizard.businessId}` : "/businesses");
                if (changed) loadDashboardData();
              }}
            />
          ) : detailId ? (
            <BusinessDetails
              key={detailId}
              businessId={detailId}
              onBack={() => navigate("/businesses")}
              onOpenSetup={(id) => setWizard({ businessId: id })}
            />
          ) : activePage === "Overview" ? (
            <OwnerOverview
              onCreateBusiness={() => setWizard({ businessId: null })}
              onOpenBusiness={setDetailId}
              onContinueSetup={(id) => setWizard({ businessId: id })}
              onNavigate={setActivePage}
            />
          ) : activePage === "Verification" ? (
            <VerificationQueue onOpenBusiness={setDetailId} onOpenSetup={(id) => setWizard({ businessId: id })} />
          ) : activePage === "Security & Abuse" ? (
            <SecurityAbuse permissions={meFailed ? null : me?.permissions} onOpenBusiness={setDetailId} />
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
          ) : activePage === "Settings" ? (
            <SettingsPage onNavigate={goTo} section={section} sub={sub} onSignOut={onSignOut}
              onOpenBusiness={setDetailId} onOpenSetup={(id) => setWizard({ businessId: id })} />
          ) : isBusinesses ? (
            <section className="owner-page">
              <div className="owner-page-heading">
                <div>
                  <div className="owner-eyebrow">Workspace management</div>
                  <h1>Businesses</h1>
                  <p>
                    Create and manage isolated CRM workspaces for every
                    business on Zella.
                  </p>
                </div>
                <button
                  className="owner-primary-button"
                  type="button"
                  onClick={() => setWizard({ businessId: null })}
                >
                  <span>＋</span> Create business
                </button>
              </div>

              <div className="owner-info-banner">
                <div className="owner-info-symbol">i</div>
                <div>
                  <strong>One platform. Separate business workspaces.</strong>
                  <p>
                    Each business will receive its own industry configuration,
                    user access, enabled modules and CRM data.
                  </p>
                </div>
              </div>


              <div className="owner-stat-grid">
  <StatCard
    label="Total businesses"
    value={loadingBusinesses ? "..." : stats.totalBusinesses}
    note="Registered businesses"
    icon="storefront"
  />

  <StatCard
    label="Active workspaces"
    value={loadingBusinesses ? "..." : stats.activeWorkspaces}
    note="Currently active"
    icon="check_circle"
  />

  <StatCard
    label="Pending invitations"
    value={loadingBusinesses ? "..." : stats.pendingInvitations}
    note="Awaiting acceptance"
    icon="mail"
  />

  <StatCard
    label="Provisioning issues"
    value={loadingBusinesses ? "..." : stats.provisioningIssues}
    note="Failed invitations"
    icon="flag"
  />
</div>

              <section className="owner-panel">
                <div className="owner-panel-heading">
                  <div>
                    <h2>All businesses</h2>
                    <p>Business workspaces managed by your platform.</p>
                  </div>
                  <div className="op-heading-actions">
                    <select
                      className="us-role"
                      value={stateFilter}
                      onChange={(event) => setStateFilter(event.target.value)}
                      aria-label="Filter businesses"
                    >
                      {STATE_FILTERS.map(([key, label]) => (
                        <option key={key} value={key}>{label}</option>
                      ))}
                    </select>
                    <button
                      className="owner-secondary-button"
                      type="button"
                      onClick={loadDashboardData}
                      disabled={loadingBusinesses}
                    >
                      {loadingBusinesses ? "Loading..." : "↻ Refresh"}
                    </button>
                  </div>
                </div>

               <div className="owner-table-wrap">
  <table className="owner-table">
    <thead>
      <tr>
        <th>Business</th>
        <th>Industry</th>
        <th>Owner</th>
        <th>Plan</th>
        <th>Workspace</th>
        <th>Invitation</th>
        <th />
      </tr>
    </thead>

    <tbody>
      {businessError ? (
        <tr>
          <td colSpan={7}>
            <div className="owner-empty-state">
              <strong>Unable to load businesses</strong>
              <p>{businessError}</p>
              <button
                type="button"
                className="owner-primary-button"
                onClick={loadDashboardData}
              >
                Try again
              </button>
            </div>
          </td>
        </tr>
      ) : loadingBusinesses && businesses.length === 0 ? (
        <tr>
          <td colSpan={7}>
            <div className="owner-empty-state">
              <strong>Loading businesses...</strong>
              <p>Fetching records from your Supabase database.</p>
            </div>
          </td>
        </tr>
      ) : visibleBusinesses.length > 0 ? (
        visibleBusinesses
          .map((business) => {
            const industry = industries.find(
              (item) => item.id === business.industry_id
            );

            const invitation = business.invitations?.[0];
            const subscription = business.subscriptions?.[0];
            const stage = businessState(business);

            return (
              <tr key={business.id}>
                <td>
                  <div className="owner-business-cell">
                    <button type="button" className="op-name" onClick={() => setDetailId(business.id)}>
                      {business.name}
                    </button>
                    <span>
                      Created{" "}
                      {business.created_at
                        ? new Date(business.created_at).toLocaleDateString()
                        : "—"}
                    </span>
                  </div>
                </td>

                <td>{industry?.name ?? "Not assigned"}</td>

                <td>
                  <div className="owner-business-cell">
                    <strong>
                      {invitation?.owner_name ?? "Not invited"}
                    </strong>
                    <span>{invitation?.email ?? "—"}</span>
                  </div>
                </td>

                <td>
                  {subscription?.status ?? "Not assigned"}
                </td>

                <td>
                  <Pill tone={stage.tone}>{stage.label}</Pill>
                </td>

                <td>
                  <Pill tone={INVITE_TONE[invitation?.status] ?? "neutral"}>
                    {words(invitation?.status ?? "not_sent")}
                  </Pill>
                </td>

                <td>
                  {stage.key !== "cancelled" && (
                    <button
                      type="button"
                      className="owner-secondary-button"
                      onClick={() => setWizard({ businessId: business.id })}
                    >
                      {stage.done ? "Edit setup" : "Continue setup"}
                    </button>
                  )}
                  <button
                    type="button"
                    className="op-link op-row-link"
                    onClick={() => setDetailId(business.id)}
                  >
                    View
                  </button>
                </td>
              </tr>
            );
          })
      ) : (
        <tr>
          <td colSpan={7}>
            <div className="owner-empty-state">
              <div className="owner-empty-icon"><Icon name="storefront" /></div>
              <strong>
                {search.trim() || stateFilter !== "all"
                  ? "No matching businesses found"
                  : "No businesses found yet"}
              </strong>
              <p>
                {search.trim() || stateFilter !== "all"
                  ? "Try a different search or filter."
                  : "Create a business to start building your platform."}
              </p>

              {!search.trim() && stateFilter === "all" && (
                <button
                  type="button"
                  className="owner-primary-button"
                  onClick={() => setWizard({ businessId: null })}
                >
                  ＋ Create your first business
                </button>
              )}
            </div>
          </td>
        </tr>
      )}
    </tbody>
  </table>
</div>

<div className="owner-panel-footer">
  <span>
    {loadingBusinesses
      ? "Refreshing business records..."
      : `${visibleBusinesses.length} of ${businesses.length} businesses shown`}
  </span>
  <span>Business data is loaded through the secured server function.</span>
</div>
</section>
            </section>
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
        </div>
      </main>

    </div>
  );
}

function StatCard({ label, value, note, icon }) {
  return (
    <div className="owner-stat-card">
      <div className="owner-stat-top">
        <span>{label}</span>
        <span className="owner-stat-icon"><Icon name={icon} size="sm" /></span>
      </div>
      <div className="owner-stat-value">{value}</div>
      <div className="owner-stat-note">{note}</div>
    </div>
  );
}
