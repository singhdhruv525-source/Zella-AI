// The admin Businesses list (/businesses). The server (businesses_list) searches, filters, sorts and pages, and
// its totals are exact; against an older server the page falls back to dashboard_data (businessList.js). Write
// buttons show only to roles with businesses.manage; the server checks the permission again on every save.
import { useCallback, useEffect, useRef, useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Icon } from "./BusinessUI";
import { Pill } from "./OwnerOverview";
import { formatDate } from "./ownerFormat";
import { DotText, friendlyError, Metric, Select, num, statValueClass } from "./admin/adminOps";
import { isCount } from "./admin/loadStatus";
import { useSettled } from "./crm/paging";
import {
  EMPTY_FILTERS, PAGE_SIZE, PLAN_OPTIONS, SORT_OPTIONS, STAGE_OPTIONS, hasFilters, isUnknownAction, lastCallLabel, legacyFilters, legacyIgnores,
  lastCallTitle, legacyList, listRequest, ownerCell, planCell, problemSummary, readList, rowActions, shortDate, stageCell, unavailableNote,
} from "./businessList";
import "./BusinessesPage.css";

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
    const key = JSON.stringify([q, f]);   // the same key the hook pages by
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
      // what this answer was asked for (not what is typed now), and the search and filters it is a page of
      setList({ ...next, filtered: hasFilters(q, f), key });
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
  // The pager moves through the result on screen only while it belongs to the current search and filters; while a
  // new search is loading (or failed), Previous and Next are off, so a page number never carries over to it.
  const pageable = Boolean(list) && list.key === key;
  return { list, loading, error, loadedAt, filters, setFilters, clearFilters, page: list?.page ?? page, setPage, pageable, reload: load };
}

export default function BusinessesPage({ state, search, onSearch, canManage, onCreate, onOpen, onSetup }) {
  const { list, loading, error, loadedAt, filters, setFilters, clearFilters, setPage, pageable, reload } = state;
  const [filtersOpen, setFiltersOpen] = useState(false);
  const stale = Boolean(error && loadedAt);
  const legacy = list?.mode === "legacy";
  const missing = new Set(list?.unavailable ?? []);
  const stats = list?.stats;
  const filtering = hasFilters(search, filters);   // what is typed or chosen now
  const filtered = list ? list.filtered : filtering;   // what the rows on screen were asked for
  const statValue = (v) => (!loadedAt ? (loading ? "..." : "Not available") : isCount(v) ? num(v) : "Not available");
  const refresh = () => reload({ fresh: true });
  const clearAll = () => { clearFilters(); onSearch(""); };
  // How many filters (not the search) are chosen: the count on the phone's Filters button.
  const chosen = [filters.industryId, filters.stage, filters.plan, filters.problem].filter(Boolean).length;
  const attention = !legacy && isCount(stats?.withProblems) && stats.withProblems > 0;

  return (
    <section className="owner-page bl-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Businesses</div>
          <h1>Businesses</h1>
          <p>Find a business, see how it's doing and open it.</p>
        </div>
        <div className="op-heading-actions bl-heading-actions">
          {loadedAt && <span className="op-muted op-updated" data-load-updated>{stale ? "Last updated" : "Updated"} {clock(loadedAt)}</span>}
          <button className="owner-secondary-button sm bl-btn-sm" type="button" onClick={refresh} disabled={loading}>
            <Icon name="refresh" size="sm" /> {loading ? "Loading..." : "Refresh"}
          </button>
          {canManage && (
            <button className="owner-primary-button" type="button" onClick={onCreate}>
              <Icon name="add" size="sm" /> Create business
            </button>
          )}
        </div>
      </div>

      {stale && (
        <div className="ic-warning op-gap" role="status" data-load="stale">
          <span>The latest refresh failed ({error}). Showing businesses from {clock(loadedAt)}; they may be out of date.</span>
          <div><button type="button" className="owner-secondary-button op-small" onClick={refresh} disabled={loading}>{loading ? "Retrying..." : "Retry"}</button></div>
        </div>
      )}

      <div className="owner-stat-grid bl-stats">
        <Metric label="Total businesses" value={statValue(stats?.totalBusinesses)} note="Registered businesses" />
        <Metric label="Active workspaces" value={statValue(stats?.activeWorkspaces)} note="Currently active" />
        <Metric label="Pending invitations" value={statValue(stats?.pendingInvitations)} note="Owners yet to accept" />
        {legacy ? (
          <Metric label="Provisioning issues" value={statValue(stats?.provisioningIssues)} note="Failed invitations" />
        ) : attention ? (
          <button type="button" className="owner-stat-card bl-stat-link" aria-pressed={Boolean(filters.problem)}
            onClick={() => setFilters(filters.problem ? { problem: false } : { problem: true, sort: "problems" })}>
            <div className="owner-stat-top"><span>Need attention</span><Icon name="chevron_right" size="sm" /></div>
            <div className={statValueClass(statValue(stats.withProblems))}>{statValue(stats.withProblems)}</div>
            <div className="owner-stat-note">{filters.problem ? "Showing only these" : "With an open problem"}</div>
          </button>
        ) : (
          <Metric label="Need attention" value={statValue(stats?.withProblems)} note="With an open problem" />
        )}
      </div>

      <section className="owner-panel">
        <div className="owner-panel-heading">
          <div>
            <h2>All businesses</h2>
            <p>Search, filter and open any business on Zella Voice.</p>
          </div>
        </div>

        <div className="bl-filters" data-open={filtersOpen ? "true" : "false"}>
          <div className="ao-filters bl-filter-row">
            <div className="bl-search-line">
              <label className="ao-filter ao-search bl-search">
                <span>Search</span>
                <input type="search" value={search} onChange={(e) => onSearch(e.target.value)} placeholder="Name, owner, email or phone" />
              </label>
              <button type="button" className="owner-secondary-button bl-filters-toggle" aria-expanded={filtersOpen} onClick={() => setFiltersOpen((o) => !o)}>
                <Icon name="tune" size="sm" /> Filters{chosen ? ` (${chosen})` : ""}
              </button>
            </div>
            <Select label="Industry" value={filters.industryId} onChange={(v) => setFilters({ industryId: v ?? "" })} any="All industries"
              options={(list?.industries ?? []).map((i) => [i.id, i.is_active === false ? `${i.name} (retired)` : i.name])} />
            <Select label="Stage" value={filters.stage} onChange={(v) => setFilters({ stage: v ?? "" })} any="All stages" options={STAGE_OPTIONS} />
            {!legacy && (
              <Select label="Plan" value={filters.plan} onChange={(v) => setFilters({ plan: v ?? "" })} any="All plans" options={PLAN_OPTIONS} />
            )}
            <Select label="Sort" value={filters.sort} onChange={(v) => setFilters({ sort: v ?? "newest" })} any={null}
              options={legacy ? SORT_OPTIONS.filter(([v]) => v !== "problems") : SORT_OPTIONS} />
            {!legacy && (
              <button type="button" className="bl-chip" aria-pressed={Boolean(filters.problem)} data-filter="problem"
                onClick={() => setFilters({ problem: !filters.problem })}>
                {filters.problem && <Icon name="check" size="sm" />} Has a problem
              </button>
            )}
            {filtering && <button type="button" className="bl-text-button bl-clear" onClick={clearAll}>Clear filters</button>}
          </div>
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

        <div className="owner-table-wrap bl-table-wrap" tabIndex={0}>
          <table className="owner-table ao-table bl-table owner-table--cards">
            <thead>
              <tr>
                <th className="col-business">Business</th>
                <th className="col-owner">Owner</th>
                <th className="col-plan">Plan</th>
                <th className="col-stage">Stage</th>
                <th className="col-call">Last call</th>
                <th className="col-problems">Problems</th>
                <th className="col-actions"><span className="bl-sr">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              {error && !loadedAt ? (
                <tr className="bl-message"><td colSpan={7}>
                  <div className="owner-empty-state" role="alert">
                    <strong>Unable to load businesses</strong>
                    <p>{error}</p>
                    <button type="button" className="owner-primary-button" onClick={refresh} disabled={loading}>Try again</button>
                  </div>
                </td></tr>
              ) : !loadedAt ? (
                <tr className="bl-message"><td colSpan={7}>
                  <div className="owner-empty-state" role="status" aria-busy="true">
                    <strong>Loading businesses...</strong>
                    <p>This takes a moment.</p>
                  </div>
                </td></tr>
              ) : list.rows.length ? (
                list.rows.map((b) => <BusinessRow key={b.id} b={b} canManage={canManage} onOpen={onOpen} onSetup={onSetup} />)
              ) : (
                <tr className="bl-message"><td colSpan={7}>
                  <div className="owner-empty-state">
                    <div className="owner-empty-icon"><Icon name="storefront" /></div>
                    <strong>{filtered ? "No matching businesses found" : "No businesses yet"}</strong>
                    <p>{filtered ? "Try a different search or filter." : canManage ? "Create a business to start building your platform." : "Businesses appear here once a Zella Voice admin creates one."}</p>
                    {filtered ? (
                      <button type="button" className="owner-secondary-button" onClick={clearAll}>Clear filters</button>
                    ) : canManage && (
                      <button type="button" className="owner-primary-button" onClick={onCreate}><Icon name="add" size="sm" /> Create your first business</button>
                    )}
                  </div>
                </td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="owner-panel-footer owner-table-foot bl-footer">
          <span className="bl-foot-text">{footerText({ list, loading, loadedAt, filtered, stats, stale })}</span>
          {loadedAt && list.total > PAGE_SIZE && (
            <div className="bl-pager">
              <button type="button" className="owner-secondary-button sm bl-btn-sm" disabled={!pageable || list.page === 0} onClick={() => setPage(list.page - 1)} aria-label="Previous page">
                <Icon name="chevron_left" size="sm" /><span className="bl-pager-word">Previous</span>
              </button>
              <button type="button" className="owner-secondary-button sm bl-btn-sm" disabled={!pageable || (list.page + 1) * PAGE_SIZE >= list.total} onClick={() => setPage(list.page + 1)} aria-label="Next page">
                <span className="bl-pager-word">Next</span><Icon name="chevron_right" size="sm" />
              </button>
            </div>
          )}
        </div>
      </section>
    </section>
  );
}

// "Showing 1 to 25 of 96" and "3 shown"; filtered: "2 businesses match, of 96", "Showing 1 to 25 of 40 matches, of 96".
function footerText({ list, loading, loadedAt, filtered, stats, stale }) {
  if (loading && !loadedAt) return "Loading businesses...";
  if (!loadedAt) return "Businesses not loaded";
  const total = list.total;
  const all = filtered && isCount(stats?.totalBusinesses) ? `, of ${num(stats.totalBusinesses)}` : "";
  const earlier = stale ? " (earlier result)" : "";
  if (total <= PAGE_SIZE) {
    if (!filtered) return `${num(total)} shown${earlier}`;
    const n = total === 0 ? "No businesses" : `${num(total)} ${total === 1 ? "business" : "businesses"}`;
    return `${n} ${total === 1 ? "matches" : "match"}${all}${earlier}`;
  }
  const first = list.page * PAGE_SIZE + 1;
  const last = Math.min(total, first + PAGE_SIZE - 1);
  return `Showing ${num(first)} to ${num(last)} of ${num(total)}${filtered ? " matches" : ""}${all}${earlier}`;
}

const EmptyValue = ({ label = "Not set" }) => <span className="empty-value">{label}</span>;

// Clicks on the row open the business; clicks on its own buttons and menu do their own thing.
const fromControl = (e) => Boolean(e.target.closest("button, a, input, select, [role=menu]"));

function BusinessRow({ b, canManage, onOpen, onSetup }) {
  const owner = ownerCell(b.owner);
  const problems = problemSummary(b.problems);
  const act = rowActions(b, canManage);
  const stage = stageCell(b);
  const plan = planCell(b.plan, b.subscription);
  const industry = b.industry_name ?? "No industry";
  const created = shortDate(b.created_at);
  return (
    <tr className="ao-clickable bl-row" onClick={(e) => { if (!fromControl(e)) onOpen(b.id); }}>
      <td className="col-business">
        <button type="button" className="bl-name owner-cell-truncate" title={b.name} onClick={() => onOpen(b.id)}>{b.name}</button>
        <span className="owner-table-secondary" title={created ? `${industry}, created ${formatDate(b.created_at)}` : industry}>
          {created ? `${industry}, ${created}` : industry}
        </span>
      </td>
      <td className="col-owner" data-label="Owner">
        {b.owner
          ? <span className="bl-strong owner-cell-truncate" title={owner.title}>{owner.title}</span>
          : <EmptyValue label="No owner invited yet" />}
        {owner.sub && <span className="owner-table-secondary owner-cell-truncate" title={owner.sub}>{owner.sub}</span>}
        {owner.status && owner.status !== "accepted" && (
          <DotText className="bl-invite" tone={INVITE_TONE[owner.status] ?? "neutral"}>{`Invitation ${owner.status === "sent" ? "sent" : owner.status}`}</DotText>
        )}
      </td>
      <td className="col-plan" data-label="Plan">
        {plan.label === null ? <EmptyValue label="Not available" />
          : plan.none ? <Pill tone="neutral">No plan</Pill>
          : <span className="bl-strong">{plan.label}</span>}
        {plan.note && <span className="owner-table-secondary">{plan.note}</span>}
        {plan.sub && <span className="bl-badge-line"><Pill tone={b.subscription?.status === "active" ? "success" : b.subscription?.status === "past_due" ? "danger" : "neutral"}>{plan.sub}</Pill></span>}
      </td>
      <td className="col-stage">
        <Pill tone={stage.tone}>{stage.label}</Pill>
        {stage.note && <span className="owner-table-secondary" title={stage.note}>{stage.note}</span>}
      </td>
      <td className="col-call" data-label="Last call">
        {b.lastCallAt ? <span className="bl-nowrap" title={lastCallTitle(b.lastCallAt)}>{lastCallLabel(b.lastCallAt)}</span>
          : <EmptyValue label={lastCallLabel(b.lastCallAt)} />}
      </td>
      <td className="col-problems" data-label="Problems" data-empty={problems.count ? undefined : "true"}>
        {problems.count ? (
          <>
            <Pill tone="danger">{problems.label}</Pill>
            {problems.detail && <span className="owner-table-secondary" title={problems.detail}>{problems.detail}</span>}
          </>
        ) : <EmptyValue label={problems.count === 0 ? "No problems" : problems.label} />}
      </td>
      <td className="col-actions">
        <div className="bl-actions">
          {act.main === "setup"
            ? <button type="button" className="owner-secondary-button sm bl-btn-sm" onClick={() => onSetup(b.id)}>{act.setup}</button>
            : <button type="button" className="owner-secondary-button sm bl-btn-sm" onClick={() => onOpen(b.id)} aria-label={`View ${b.name}`}>View</button>}
          {act.main === "view" && act.setup
            ? <RowMenu name={b.name} items={[[act.setup, () => onSetup(b.id)]]} />
            : <span className="bl-menu-spacer" aria-hidden="true" />}
        </div>
      </td>
    </tr>
  );
}

// The row's overflow menu (more_horiz): closes on Escape, on a click outside, and after a choice.
function RowMenu({ name, items }) {
  const [open, setOpen] = useState(false);
  const box = useRef(null);
  const button = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const away = (e) => { if (!box.current?.contains(e.target)) setOpen(false); };
    const key = (e) => { if (e.key === "Escape") { setOpen(false); button.current?.focus(); } };
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    box.current?.querySelector("[role=menuitem]")?.focus();
    return () => { document.removeEventListener("mousedown", away); document.removeEventListener("keydown", key); };
  }, [open]);
  return (
    <div className="bl-menu" ref={box}>
      <button ref={button} type="button" className="bl-icon-button" aria-label={`More actions for ${name}`} aria-haspopup="menu" aria-expanded={open}
        onClick={() => setOpen((o) => !o)}>
        <Icon name="more_horiz" size="sm" />
      </button>
      {open && (
        <div className="bl-menu-list" role="menu">
          {items.map(([label, run]) => (
            <button key={label} type="button" role="menuitem" onClick={() => { setOpen(false); run(); }}>{label}</button>
          ))}
        </div>
      )}
    </div>
  );
}
