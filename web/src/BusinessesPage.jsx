// The admin Businesses list (/businesses). The server (businesses_list) searches, filters, sorts and pages, and
// its totals are exact; against an older server the page falls back to dashboard_data (businessList.js). Write
// buttons show only to roles with businesses.manage; the server checks the permission again on every save.
import { useCallback, useEffect, useRef, useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Icon } from "./BusinessUI";
import { Pill } from "./OwnerOverview";
import { businessState, formatDate } from "./ownerFormat";
import { friendlyError, Filters, Pager, Select, Toggle, num } from "./admin/adminOps";
import { isCount } from "./admin/loadStatus";
import { useSettled } from "./crm/paging";
import {
  EMPTY_FILTERS, PAGE_SIZE, PLAN_OPTIONS, SORT_OPTIONS, STAGE_OPTIONS, hasFilters, isUnknownAction, lastCallLabel, legacyFilters, legacyIgnores,
  lastCallTitle, legacyList, listRequest, ownerCell, planLabel, problemSummary, readList, rowActions, subscriptionLabel, unavailableNote,
} from "./businessList";

const INVITE_TONE = { accepted: "success", sent: "warning", pending: "warning", failed: "danger", expired: "danger", revoked: "neutral" };
const clock = (d) => d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });

// The list's state lives in OwnerDashboard (through this hook), so going to another page and back shows the last list
// straight away while it refreshes. `active`: the Businesses page is open and the admin may view businesses.
// `authorized`: someone is signed in with admin access; when that ends everything loaded is dropped.
export function useBusinessList({ active, authorized, search }) {
  const [filters, setFiltersState] = useState(EMPTY_FILTERS);
  const settled = useSettled(String(search ?? "").trim(), 350);
  // The page belongs to one search and set of filters: changing either starts again at the first page.
  const key = JSON.stringify([settled, filters]);
  const [pageAt, setPageAt] = useState({ key, page: 0 });
  const page = pageAt.key === key ? pageAt.page : 0;
  const [list, setList] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [loadedAt, setLoadedAt] = useState(null);
  const epoch = useRef(0);
  const request = useRef(0);
  const legacy = useRef(null);   // the older server's unpaged answer, once businesses_list turned out not to exist
  const query = useRef({ settled, filters, page });
  useEffect(() => { query.current = { settled, filters, page }; });   // before the load below, which reads it

  const load = useCallback(async ({ fresh = true } = {}) => {
    const mine = epoch.current;
    const req = ++request.current;
    const { settled: q, page: p } = query.current;
    let f = query.current.filters;
    setLoading(true);
    try {
      let next;
      if (!legacy.current) {
        try {
          next = readList(await callOwnerFunction("businesses_list", listRequest(q, f, p)));
        } catch (err) {
          if (!isUnknownAction(err)) throw err;
          legacy.current = { data: null };   // an older server: use dashboard_data from now on
          // The older list can't filter by plan or problem or sort by problems: drop them, so the list isn't labelled
          // as filtered by something it ignores (the load this triggers shares the request below).
          if (legacyIgnores(f)) { f = legacyFilters(f); setFiltersState(legacyFilters); }
        }
      }
      if (legacy.current) {
        if (fresh || !legacy.current.data) {
          const pending = callOwnerFunction("dashboard_data");   // shared by loads that start while it is on its way
          legacy.current = { data: pending };
          pending.catch(() => { if (legacy.current?.data === pending) legacy.current = { data: null }; });
        }
        next = legacyList(await legacy.current.data, q, f, p);
      }
      if (mine !== epoch.current || req !== request.current) return;
      setList({ ...next, filtered: hasFilters(q, f) });   // what this answer was asked for, not what is typed now
      setError("");
      setLoadedAt(new Date());
    } catch (err) {
      if (mine !== epoch.current || req !== request.current) return;
      console.error("Businesses loading failed:", err);
      setError(friendlyError(err) || "Could not load businesses. Please try again.");
    } finally {
      if (mine === epoch.current && req === request.current) setLoading(false);
    }
  }, []);

  // Signed out, switching account or re-checking access: drop every business loaded for the earlier session.
  useEffect(() => {
    if (authorized) return;
    epoch.current++;
    legacy.current = legacy.current ? { data: null } : null;
    setList(null); setError(""); setLoadedAt(null); setLoading(false);
  }, [authorized]);

  // Opening the page loads fresh data; a new search, filter or page asks the server again (the older server's list is
  // filtered again here, without another request).
  const opened = useRef(false);
  useEffect(() => {
    if (!active) { opened.current = false; return; }
    const fresh = !opened.current;
    opened.current = true;
    load({ fresh });
  }, [active, key, page, load]);

  const setFilters = useCallback((patch) => setFiltersState((f) => ({ ...f, ...patch })), []);
  const clearFilters = useCallback(() => setFiltersState(EMPTY_FILTERS), []);
  const setPage = useCallback((n) => setPageAt({ key, page: n }), [key]);
  return { list, loading, error, loadedAt, filters, setFilters, clearFilters, page: list?.page ?? page, setPage, reload: load };
}

export default function BusinessesPage({ state, search, onSearch, canManage, onCreate, onOpen, onSetup }) {
  const { list, loading, error, loadedAt, filters, setFilters, clearFilters, setPage, reload } = state;
  const stale = Boolean(error && loadedAt);
  const legacy = list?.mode === "legacy";
  const missing = new Set(list?.unavailable ?? []);
  const stats = list?.stats;
  const filtering = hasFilters(search, filters);   // what is typed or chosen now
  const filtered = list ? list.filtered : filtering;   // what the rows on screen were asked for
  const statValue = (v) => (!loadedAt ? (loading ? "..." : "Not available") : isCount(v) ? num(v) : "Not available");
  const refresh = () => reload({ fresh: true });

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Workspace management</div>
          <h1>Businesses</h1>
          <p>Find a business, see how it's doing and open it.</p>
        </div>
        {canManage && (
          <button className="owner-primary-button" type="button" onClick={onCreate}>
            <span>＋</span> Create business
          </button>
        )}
      </div>

      {stale && (
        <div className="ic-warning op-gap" role="status" data-load="stale">
          <span>The latest refresh failed ({error}). Showing businesses from {clock(loadedAt)}; they may be out of date.</span>
          <div><button type="button" className="owner-secondary-button op-small" onClick={refresh} disabled={loading}>{loading ? "Retrying..." : "Retry"}</button></div>
        </div>
      )}

      <div className="owner-stat-grid">
        <StatCard label="Total businesses" value={statValue(stats?.totalBusinesses)} note="Registered businesses" icon="storefront" />
        <StatCard label="Active workspaces" value={statValue(stats?.activeWorkspaces)} note="Currently active" icon="check_circle" />
        <StatCard label="Pending invitations" value={statValue(stats?.pendingInvitations)} note="Owners yet to accept" icon="mail" />
        {legacy ? (
          <StatCard label="Provisioning issues" value={statValue(stats?.provisioningIssues)} note="Failed invitations" icon="flag" />
        ) : (
          <StatCard label="Need attention" value={statValue(stats?.withProblems)} icon="flag"
            note={isCount(stats?.withProblems) && stats.withProblems > 0 && !filters.problem
              ? <button type="button" className="op-link" onClick={() => setFilters({ problem: true, sort: "problems" })}>Show them</button>
              : "Businesses with an open problem"} />
        )}
      </div>

      <section className="owner-panel">
        <div className="owner-panel-heading">
          <div>
            <h2>All businesses</h2>
            <p>Search, filter and open any business on Zella Voice.</p>
          </div>
          <div className="op-heading-actions">
            {loadedAt && <span className="op-muted op-updated" data-load-updated>{stale ? "Last updated" : "Updated"} {clock(loadedAt)}</span>}
            <button className="owner-secondary-button" type="button" onClick={refresh} disabled={loading}>
              {loading ? "Loading..." : "↻ Refresh"}
            </button>
          </div>
        </div>

        <div className="bl-filters">
          <Filters>
            <label className="ao-filter ao-search">
              <span>Search</span>
              <input type="search" value={search} onChange={(e) => onSearch(e.target.value)} placeholder="Name, owner, email or phone" />
            </label>
            <Select label="Industry" value={filters.industryId} onChange={(v) => setFilters({ industryId: v ?? "" })} any="All industries"
              options={(list?.industries ?? []).map((i) => [i.id, i.is_active === false ? `${i.name} (retired)` : i.name])} />
            <Select label="Stage" value={filters.stage} onChange={(v) => setFilters({ stage: v ?? "" })} any="All stages" options={STAGE_OPTIONS} />
            {!legacy && (
              <Select label="Plan" value={filters.plan} onChange={(v) => setFilters({ plan: v ?? "" })} any="All plans" options={PLAN_OPTIONS} />
            )}
            <Select label="Sort" value={filters.sort} onChange={(v) => setFilters({ sort: v ?? "newest" })} any={null}
              options={legacy ? SORT_OPTIONS.filter(([v]) => v !== "problems") : SORT_OPTIONS} />
            {!legacy && <Toggle label="Has a problem" checked={filters.problem} onChange={(v) => setFilters({ problem: v })} />}
            {filtering && <button type="button" className="op-link bl-clear" onClick={() => { clearFilters(); onSearch(""); }}>Clear filters</button>}
          </Filters>
          {legacy && (
            <div className="ao-unavailable" role="status" data-list-mode="legacy">
              <Icon name="info" />
              <div>
                <strong>Showing the older list</strong>
                <p>The server hasn't been updated yet, so plans, problems and last calls aren't shown, and the list holds at most 1,000 businesses. Search and filters work on what was loaded.</p>
              </div>
            </div>
          )}
          {!legacy && missing.size > 0 && (
            <div className="ao-unavailable" role="status">
              <Icon name="info" />
              <div>
                <strong>Some details couldn't be loaded</strong>
                <p>{unavailableNote(missing)}</p>
              </div>
            </div>
          )}
        </div>

        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table ao-table bl-table">
            <thead>
              <tr>
                <th>Business</th>
                <th>Owner</th>
                <th>Plan</th>
                <th>Stage</th>
                <th>Last call</th>
                <th>Problems</th>
                <th><span className="bl-sr">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              {error && !loadedAt ? (
                <tr><td colSpan={7}>
                  <div className="owner-empty-state" role="alert">
                    <strong>Unable to load businesses</strong>
                    <p>{error}</p>
                    <button type="button" className="owner-primary-button" onClick={refresh} disabled={loading}>Try again</button>
                  </div>
                </td></tr>
              ) : !loadedAt ? (
                <tr><td colSpan={7}>
                  <div className="owner-empty-state" role="status" aria-busy="true">
                    <strong>Loading businesses...</strong>
                    <p>This takes a moment.</p>
                  </div>
                </td></tr>
              ) : list.rows.length ? (
                list.rows.map((b) => <BusinessRow key={b.id} b={b} canManage={canManage} onOpen={onOpen} onSetup={onSetup} />)
              ) : (
                <tr><td colSpan={7}>
                  <div className="owner-empty-state">
                    <div className="owner-empty-icon"><Icon name="storefront" /></div>
                    <strong>{filtered ? "No matching businesses found" : "No businesses yet"}</strong>
                    <p>{filtered ? "Try a different search or filter." : canManage ? "Create a business to start building your platform." : "Businesses appear here once a Zella Voice admin creates one."}</p>
                    {filtered ? (
                      <button type="button" className="owner-secondary-button" onClick={() => { clearFilters(); onSearch(""); }}>Clear filters</button>
                    ) : canManage && (
                      <button type="button" className="owner-primary-button" onClick={onCreate}>＋ Create your first business</button>
                    )}
                  </div>
                </td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="owner-panel-footer bl-footer">
          <span>
            {loading ? "Refreshing business records..."
              : !loadedAt ? "Businesses not loaded"
              : `${num(list.total)} ${list.total === 1 ? "business" : "businesses"}${filtered && isCount(stats?.totalBusinesses) ? ` match, of ${num(stats.totalBusinesses)}` : ""}${stale ? " (earlier result)" : ""}`}
          </span>
          {loadedAt && list.total > PAGE_SIZE && <Pager total={list.total} offset={list.page * PAGE_SIZE} onChange={(offset) => setPage(Math.floor(offset / PAGE_SIZE))} />}
        </div>
      </section>
    </section>
  );
}

function BusinessRow({ b, canManage, onOpen, onSetup }) {
  const state = businessState(b);
  const owner = ownerCell(b.owner);
  const problems = problemSummary(b.problems);
  const act = rowActions(b, canManage);
  const sub = subscriptionLabel(b.subscription);
  const view = (
    <button type="button" className={act.main === "view" ? "owner-secondary-button op-small" : "op-link"} onClick={() => onOpen(b.id)}
      aria-label={`View ${b.name}`}>View</button>
  );
  const setup = act.setup && (
    <button type="button" className={act.main === "setup" ? "owner-secondary-button op-small" : "op-link"} onClick={() => onSetup(b.id)}>
      {act.setup}
    </button>
  );
  return (
    <tr>
      <td>
        <div className="owner-business-cell">
          <button type="button" className="op-name" onClick={() => onOpen(b.id)}>{b.name}</button>
          <span>{b.industry_name ?? "No industry"} · Created {formatDate(b.created_at)}</span>
        </div>
      </td>
      <td>
        <div className="owner-business-cell">
          {b.owner ? <strong>{owner.title}</strong> : <span>{owner.title}</span>}
          {owner.sub && <span className="bl-email">{owner.sub}</span>}
          {owner.status && owner.status !== "accepted" && (
            <span><Pill tone={INVITE_TONE[owner.status] ?? "neutral"}>{`Invitation ${owner.status === "sent" ? "sent" : owner.status}`}</Pill></span>
          )}
        </div>
      </td>
      <td>
        <div className="owner-business-cell">
          <strong>{planLabel(b.plan)}</strong>
          {sub && <span>{sub}</span>}
        </div>
      </td>
      <td><Pill tone={state.tone}>{state.label}</Pill></td>
      <td><span className="bl-nowrap" title={lastCallTitle(b.lastCallAt)}>{lastCallLabel(b.lastCallAt)}</span></td>
      <td>
        {problems.count ? (
          <div className="owner-business-cell">
            <span><Pill tone={problems.tone}>{problems.label}</Pill></span>
            <span>{problems.detail}</span>
          </div>
        ) : <span className="op-muted">{problems.label}</span>}
      </td>
      <td>
        <div className="bl-actions">
          {act.main === "setup" ? <>{setup}{view}</> : <>{view}{setup}</>}
        </div>
      </td>
    </tr>
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
