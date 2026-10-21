import { useCallback, useEffect, useState } from "react";
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
import { Pill } from "./OwnerOverview";
import { businessState } from "./ownerFormat";

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

const NAVIGATION = [
  { label: "Overview", icon: "◫" },
  { label: "Businesses", icon: "▦" },
  { label: "Users & Access", icon: "♙" },
  { label: "Industry Configuration", icon: "◇" },
  { label: "Modules & Features", icon: "▤" },
  { label: "AI Agents", icon: "✳" },
  { label: "Plans & Subscriptions", icon: "▱" },
  { label: "Integrations", icon: "↔" },
  { label: "Platform Operations", icon: "⌘" },
  { label: "Support", icon: "♡" },
  { label: "Audit Logs", icon: "☷" },
  { label: "Settings", icon: "⚙" },
];

export default function OwnerDashboard({ onSignOut }) {
  const [activePage, setActivePage] = useState("Overview");
  const [wizard, setWizard] = useState(null);
  const [detailId, setDetailId] = useState(null);
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
    setActivePage(page);
    setWizard(null);
    setDetailId(null);
  }

  return (
    <div className="owner-app">
      <aside className="owner-sidebar">
        <div className="owner-brand">
          <div className="owner-brand-mark">Z</div>
          <div>
            <div className="owner-brand-name">zella<span>ai</span></div>
            <div className="owner-brand-caption">PLATFORM CONTROL</div>
          </div>
        </div>

        <div className="owner-workspace">
          <div className="owner-workspace-icon">Z</div>
          <div className="owner-workspace-copy">
            <strong>Zella Platform</strong>
            <span>Owner workspace</span>
          </div>
          <span className="owner-chevron">⌄</span>
        </div>

        <div className="owner-nav-label">PLATFORM</div>
        <nav className="owner-nav">
          {NAVIGATION.map((item) => (
            <button
              key={item.label}
              type="button"
              className={`owner-nav-item ${
                activePage === item.label ? "active" : ""
              }`}
              onClick={() => goTo(item.label)}
            >
              <span className="owner-nav-icon">{item.icon}</span>
              <span>{item.label}</span>
              {item.label === "Businesses" && (
                <span className="owner-nav-arrow">›</span>
              )}
            </button>
          ))}
        </nav>

        <button type="button" className="owner-sidebar-bottom op-status-link" onClick={() => goTo("Platform Operations")}>
          <div className="owner-status-dot" />
          <div>
            <strong>Platform status</strong>
            <span>View system health</span>
          </div>
        </button>
      </aside>

      <main className="owner-main">
        <header className="owner-topbar">
          <div className="owner-breadcrumb">
            <span>Platform</span>
            <span>/</span>
            <strong>{activePage}</strong>
          </div>

          <div className="owner-top-actions">
            <div className="owner-search">
              <span>⌕</span>
              <input
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
            <button
              className="owner-icon-button"
              type="button"
              aria-label="Needs attention"
              title="Needs attention (Overview)"
              onClick={() => goTo("Overview")}
            >
              ♧
            </button>
            <div className="owner-avatar" title="Platform owner">O</div>
            <button className="owner-signout" type="button" onClick={onSignOut}>
              Sign out
            </button>
          </div>
        </header>

        <div className="owner-content">
          {wizard ? (
            <CreateBusinessWizard
              key={wizard.businessId || "new"}
              businessId={wizard.businessId}
              industries={industries}
              onClose={(changed) => {
                setWizard(null);
                if (changed) loadDashboardData();
              }}
            />
          ) : detailId ? (
            <BusinessDetails
              key={detailId}
              businessId={detailId}
              onBack={() => {
                setDetailId(null);
                setActivePage("Businesses");
              }}
              onOpenSetup={(id) => setWizard({ businessId: id })}
            />
          ) : activePage === "Overview" ? (
            <OwnerOverview
              onCreateBusiness={() => setWizard({ businessId: null })}
              onOpenBusiness={setDetailId}
              onContinueSetup={(id) => setWizard({ businessId: id })}
              onNavigate={setActivePage}
            />
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
          ) : activePage === "Platform Operations" ? (
            <PlatformOperations onNavigate={goTo} />
          ) : activePage === "Settings" ? (
            <SettingsPage onNavigate={goTo} />
          ) : isBusinesses ? (
            <section className="owner-page">
              <div className="owner-page-heading">
                <div>
                  <div className="owner-eyebrow">WORKSPACE MANAGEMENT</div>
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
    icon="▦"
  />

  <StatCard
    label="Active workspaces"
    value={loadingBusinesses ? "..." : stats.activeWorkspaces}
    note="Currently active"
    icon="◉"
  />

  <StatCard
    label="Pending invitations"
    value={loadingBusinesses ? "..." : stats.pendingInvitations}
    note="Awaiting acceptance"
    icon="✉"
  />

  <StatCard
    label="Provisioning issues"
    value={loadingBusinesses ? "..." : stats.provisioningIssues}
    note="Failed invitations"
    icon="⚑"
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
        <th>BUSINESS</th>
        <th>INDUSTRY</th>
        <th>OWNER</th>
        <th>PLAN</th>
        <th>WORKSPACE</th>
        <th>INVITATION</th>
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
                  <span className="owner-status">
                    {invitation?.status ?? "Not sent"}
                  </span>
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
              <div className="owner-empty-icon">▦</div>
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
              <div className="owner-eyebrow">PLATFORM CONTROL CENTER</div>
              <h1>{activePage === "Overview" ? "Welcome to Zella" : activePage}</h1>
              <p className="owner-page-description">
                {activePage === "Overview"
                  ? "Manage your business workspaces, configurations and platform operations from one place."
                  : `The ${activePage.toLowerCase()} workspace will be connected in a later implementation step.`}
              </p>

              <div className="owner-stat-grid">
                <StatCard label="Businesses" value="—" note="Awaiting live data" icon="▦" />
                <StatCard label="Users" value="—" note="Awaiting live data" icon="♙" />
                <StatCard label="Subscriptions" value="—" note="Awaiting live data" icon="▱" />
                <StatCard label="Invitations" value="—" note="Awaiting live data" icon="✉" />
              </div>

              <div className="owner-panel owner-overview-panel">
                <div className="owner-panel-heading">
                  <div>
                    <h2>Platform workspace</h2>
                    <p>Continue setting up your Zella platform.</p>
                  </div>
                </div>
                <button
                  type="button"
                  className="owner-primary-button"
                  onClick={() => {
                    setActivePage("Businesses");
                    setWizard(null);
                  }}
                >
                  Manage businesses <span>→</span>
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
        <span className="owner-stat-icon">{icon}</span>
      </div>
      <div className="owner-stat-value">{value}</div>
      <div className="owner-stat-note">{note}</div>
    </div>
  );
}
