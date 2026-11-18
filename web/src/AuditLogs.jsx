import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import "./OwnerPages.css";
import "./AuditLogs.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Icon } from "./BusinessUI";
import { actionLabel, formatDateTime } from "./ownerFormat";
import { friendlyError } from "./admin/adminOps";
import catalog from "../supabase/functions/_shared/catalog.json";
import { auditActionOptions, auditQuery } from "./adminAccess";

const ACTIONS = auditActionOptions(catalog);
const label = (action) => catalog.audit_actions[action] ?? actionLabel(action);
// The full moment for a tooltip: "Nov 16, 2026 at 2:49 PM".
function fullDateTime(value) {
  if (!value) return "";
  const d = new Date(value);
  const date = d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return `${date} at ${time}`;
}

// Plain relative time: "5 days ago", "Yesterday", never "5 d ago".
function relative(value) {
  if (!value) return "";
  const minutes = Math.round((Date.now() - new Date(value).getTime()) / 60000);
  if (minutes < 1) return "Just now";
  if (minutes < 60) return minutes === 1 ? "1 minute ago" : `${minutes} minutes ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours === 1 ? "1 hour ago" : `${hours} hours ago`;
  const days = Math.round(hours / 24);
  if (days === 1) return "Yesterday";
  if (days < 30) return `${days} days ago`;
  return "";
}

const EMPTY = { businessId: "", auditAction: "", actorId: "", from: "", to: "", entityType: "", entityId: "" };
// The From and To days are days in this browser's time zone, the zone the times on the page are shown in; the server
// filters and exports with the same day bounds.
// The zone is read at each use, so a change of the computer's zone while the page is open is followed everywhere.
const zone = () => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"; } catch { return "UTC"; } };
const withZone = (q) => (q.from || q.to ? { ...q, timeZone: zone() } : q);

export default function AuditLogs({ onOpenBusiness }) {
  const [logs, setLogs] = useState([]);
  const [businesses, setBusinesses] = useState([]);
  const [people, setPeople] = useState([]);
  const [filters, setFilters] = useState(EMPTY);
  const [canExport, setCanExport] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [notice, setNotice] = useState("");
  const [exportError, setExportError] = useState("");
  const set = (key) => (e) => setFilters((f) => ({ ...f, [key]: e.target.value }));
  // the cursor and the rows on screen belong to the filters that produced them (listKey)
  const [cursor, setCursor] = useState(null);
  const [listKey, setListKey] = useState(null);
  const [listOk, setListOk] = useState(false);   // the last first page read for these filters succeeded
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(null);
  const [filtersOpen, setFiltersOpen] = useState(false);

  const key = JSON.stringify([auditQuery(filters), zone()]);
  const request = useRef(0);
  const load = useCallback(async (before) => {
    const id = ++request.current;
    const forKey = JSON.stringify([auditQuery(filters), zone()]);
    setLoading(true);
    setError("");
    try {
      const data = await callOwnerFunction("audit_logs", { ...withZone(auditQuery(filters)), before });
      if (id !== request.current) return;
      if (!data || !Array.isArray(data.logs)) throw new Error("The audit log couldn't be read. Try again.");
      setLogs((current) => (before ? [...current, ...data.logs] : data.logs));
      setCursor(data.nextCursor ?? null);
      setListKey(forKey);
      if (!before) setListOk(true);
      if (data.businesses) setBusinesses(data.businesses);
      if (data.people) setPeople(data.people);
      if (!before) setCanExport(Boolean(data.canExport));
    } catch (err) {
      if (id !== request.current) return;
      setError(friendlyError(err));
      if (!before) setListOk(false);   // the rows on screen stay, marked as from before this failed refresh
      if (err?.status === 403) setCanExport(false);   // no access now: no Export either, until a first page says so
    } finally {
      if (id === request.current) setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    load(null);
    return () => { request.current += 1; };
  }, [load]);

  // ACC-12: the filtered log as a CSV file, at most 10,000 entries; the export itself is audited.
  async function exportCsv() {
    setExporting(true);
    setExportError("");
    setNotice("");
    try {
      const r = await callOwnerFunction("audit_export", withZone(auditQuery(filters)));
      const url = URL.createObjectURL(new Blob([r.csv], { type: "text/csv;charset=utf-8" }));
      const a = Object.assign(document.createElement("a"), { href: url, download: r.filename });
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setNotice(r.truncated ? `Exported the newest ${r.rows.toLocaleString()} entries. Narrow the filters to export the rest.` : `Exported ${r.rows.toLocaleString()} entries.`);
    } catch (err) {
      setExportError(friendlyError(err));
    } finally {
      setExporting(false);
    }
  }
  // the rows on screen were read with other filters (a new list is loading or failed): no paging from them
  const stale = listKey !== null && (listKey !== key || !listOk);
  const filtered = Object.values(auditQuery(filters)).length > 0;
  const chosen = Object.values(filters).filter(Boolean).length;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Security</div>
          <h1>Audit logs</h1>
          <p>Every admin action on client businesses: who did it, what changed and when.</p>
        </div>
        <div className="ic-actions">
          {canExport && (
            <button type="button" className="owner-secondary-button" onClick={exportCsv} disabled={exporting || loading}>
              {exporting ? "Exporting..." : "Export CSV"}
            </button>
          )}
          <button type="button" className="owner-secondary-button" onClick={() => load(null)} disabled={loading}>
            {loading ? "Loading..." : "↻ Refresh"}
          </button>
        </div>
      </div>

      <div className="al-filters" data-open={filtersOpen ? "true" : "false"}>
        <button type="button" className="owner-secondary-button al-filters-toggle" aria-expanded={filtersOpen}
          aria-controls="audit-filters" onClick={() => setFiltersOpen((o) => !o)}>
          <Icon name="tune" size="sm" /> Filters{chosen ? ` (${chosen})` : ""}
        </button>
        <div className="al-filter-row" id="audit-filters">
          <label className="owner-field al-f-select">
            <span>Business</span>
            <select value={filters.businessId} onChange={set("businessId")}>
              <option value="">All businesses</option>
              {businesses.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          </label>
          <label className="owner-field al-f-select">
            <span>Action</span>
            <select value={filters.auditAction} onChange={set("auditAction")}>
              <option value="">All actions</option>
              {ACTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
            </select>
          </label>
          <label className="owner-field al-f-select">
            <span>Person</span>
            <select value={filters.actorId} onChange={set("actorId")}>
              <option value="">Everyone</option>
              {people.map((p) => <option key={p.id} value={p.id}>{p.email ?? p.id}</option>)}
            </select>
          </label>
          <label className="owner-field al-f-date">
            <span>From <em className="al-tz">({zone()})</em></span>
            <input type="date" value={filters.from} onChange={set("from")} max={filters.to || undefined} />
          </label>
          <label className="owner-field al-f-date">
            <span>To <em className="al-tz">({zone()})</em></span>
            <input type="date" value={filters.to} onChange={set("to")} min={filters.from || undefined} />
          </label>
          <label className="owner-field al-f-text">
            <span>Record type</span>
            <input value={filters.entityType} onChange={set("entityType")} placeholder="for example platform_admin" />
          </label>
          <label className="owner-field al-f-text">
            <span>Record id</span>
            <input value={filters.entityId} onChange={set("entityId")} placeholder="The record's id" />
          </label>
          {filtered && (
            <button type="button" className="al-text-button" onClick={() => setFilters(EMPTY)}>Clear filters</button>
          )}
        </div>
      </div>

      {notice && <div className="ic-notice op-gap" role="status">{notice}</div>}
      {exportError && <div className="owner-form-error op-gap" role="alert">The export didn't work: {exportError}</div>}
      {error && <div className="owner-form-error op-gap" role="alert">Could not load audit logs: {error}</div>}
      {stale && logs.length > 0 && <div className="op-muted op-gap" data-load="stale">{listKey !== key ? "These entries are for the earlier filters" : "These entries are from before the last refresh failed"}{loading ? "; the new list is loading" : ""}.</div>}

      <section className="owner-panel">
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table al-table">
            <thead>
              <tr>
                <th className="al-col-when">When</th>
                <th className="al-col-action">Action</th>
                <th className="al-col-business">Business</th>
                <th className="al-col-by">By</th>
                <th className="al-col-actions"><span className="al-sr">Details</span></th>
              </tr>
            </thead>
            <tbody>
              {logs.map((log) => (
                <Fragment key={log.id}>
                  <tr className={expanded === log.id ? "al-row is-open" : "al-row"}>
                    <td className="al-col-when" title={fullDateTime(log.created_at)}>
                      <span className="al-when">{formatDateTime(log.created_at)}</span>
                      {relative(log.created_at) && <span className="al-ago">{relative(log.created_at)}</span>}
                    </td>
                    <td className="al-col-action"><span className="al-action">{label(log.action)}</span></td>
                    <td className="al-col-business">
                      {log.business_id ? (
                        <button type="button" className="op-name al-truncate" title={log.business_name ?? "Deleted business"}
                          onClick={() => onOpenBusiness(log.business_id)}>
                          {log.business_name ?? "Deleted business"}
                        </button>
                      ) : <span className="al-empty">No business</span>}
                    </td>
                    <td className="al-col-by">
                      <span className="al-truncate" title={log.actor ?? "Unknown user"}>{log.actor ?? "Unknown user"}</span>
                    </td>
                    <td className="al-col-actions">
                      {(log.new_data || log.old_data) && (
                        <button type="button" className="owner-secondary-button sm op-small" aria-expanded={expanded === log.id}
                          onClick={() => setExpanded(expanded === log.id ? null : log.id)}>
                          {expanded === log.id ? "Hide" : "Details"}
                        </button>
                      )}
                    </td>
                  </tr>
                  {expanded === log.id && (
                    <tr className="op-detail-row al-detail-row">
                      <td colSpan={5}>
                        <div className="op-json-grid">
                          {log.old_data && (
                            <div><h4>Before</h4><pre>{JSON.stringify(log.old_data, null, 2)}</pre></div>
                          )}
                          {log.new_data && (
                            <div><h4>{log.old_data ? "After" : "Recorded"}</h4><pre>{JSON.stringify(log.new_data, null, 2)}</pre></div>
                          )}
                        </div>
                        <p className="op-muted">
                          {log.entity_type ? `Record: ${log.entity_type}` : ""}
                          {log.entity_id ? ` ${log.entity_id}` : ""}
                          {log.ip_address ? ` · IP ${log.ip_address}` : ""}
                          {log.user_agent ? ` · Browser: ${log.user_agent}` : ""}
                        </p>
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
              {!logs.length && (
                <tr className="al-empty-row">
                  <td colSpan={5}>
                    <div className="op-empty">
                      {loading ? "Loading audit logs..." : error ? "Audit logs unavailable." : filtered ? "No matching entries." : "No admin actions recorded yet."}
                    </div>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <div className="owner-panel-footer">
          <span>{logs.length} entries shown</span>
          {cursor && !stale && (
            <button type="button" className="owner-secondary-button op-small" onClick={() => load(cursor)} disabled={loading}>
              {loading ? "Loading..." : "Load older"}
            </button>
          )}
        </div>
      </section>
    </section>
  );
}
