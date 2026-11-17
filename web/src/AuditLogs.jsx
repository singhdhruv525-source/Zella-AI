import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { actionLabel, formatDateTime, timeAgo } from "./ownerFormat";
import { friendlyError } from "./admin/adminOps";
import catalog from "../supabase/functions/_shared/catalog.json";
import { auditActionOptions, auditQuery } from "./adminAccess";

const ACTIONS = auditActionOptions(catalog);
const label = (action) => catalog.audit_actions[action] ?? actionLabel(action);
const EMPTY = { businessId: "", auditAction: "", actorId: "", from: "", to: "", entityType: "", entityId: "" };

export default function AuditLogs({ onOpenBusiness }) {
  const [logs, setLogs] = useState([]);
  const [businesses, setBusinesses] = useState([]);
  const [people, setPeople] = useState([]);
  const [filters, setFilters] = useState(EMPTY);
  const [canExport, setCanExport] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [notice, setNotice] = useState("");
  const set = (key) => (e) => setFilters((f) => ({ ...f, [key]: e.target.value }));
  const [cursor, setCursor] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(null);

  const request = useRef(0);
  const load = useCallback(async (before) => {
    const id = ++request.current;
    setLoading(true);
    setError("");
    try {
      const data = await callOwnerFunction("audit_logs", { ...auditQuery(filters), before });
      if (id !== request.current) return;
      setLogs((current) => (before ? [...current, ...data.logs] : data.logs));
      setCursor(data.nextCursor);
      if (data.businesses) setBusinesses(data.businesses);
      if (data.people) setPeople(data.people);
      if (!before) setCanExport(Boolean(data.canExport));
    } catch (err) {
      if (id === request.current) setError(friendlyError(err));
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
    setError("");
    setNotice("");
    try {
      const r = await callOwnerFunction("audit_export", auditQuery(filters));
      const url = URL.createObjectURL(new Blob([r.csv], { type: "text/csv;charset=utf-8" }));
      const a = Object.assign(document.createElement("a"), { href: url, download: r.filename });
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setNotice(r.truncated ? `Exported the newest ${r.rows.toLocaleString()} entries. Narrow the filters to export the rest.` : `Exported ${r.rows.toLocaleString()} entries.`);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setExporting(false);
    }
  }
  const filtered = Object.values(auditQuery(filters)).length > 0;

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

      <div className="op-filters" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(190px, 1fr))" }}>
        <label className="owner-field">
          <span>Business</span>
          <select value={filters.businessId} onChange={set("businessId")}>
            <option value="">All businesses</option>
            {businesses.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </label>
        <label className="owner-field">
          <span>Action</span>
          <select value={filters.auditAction} onChange={set("auditAction")}>
            <option value="">All actions</option>
            {ACTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
          </select>
        </label>
        <label className="owner-field">
          <span>Person</span>
          <select value={filters.actorId} onChange={set("actorId")}>
            <option value="">Everyone</option>
            {people.map((p) => <option key={p.id} value={p.id}>{p.email ?? p.id}</option>)}
          </select>
        </label>
        <label className="owner-field">
          <span>From</span>
          <input type="date" value={filters.from} onChange={set("from")} max={filters.to || undefined} />
        </label>
        <label className="owner-field">
          <span>To</span>
          <input type="date" value={filters.to} onChange={set("to")} min={filters.from || undefined} />
        </label>
        <label className="owner-field">
          <span>Record type</span>
          <input value={filters.entityType} onChange={set("entityType")} placeholder="for example platform_admin" />
        </label>
        <label className="owner-field">
          <span>Record id</span>
          <input value={filters.entityId} onChange={set("entityId")} placeholder="The record's id" />
        </label>
        {filtered && (
          <div className="owner-field">
            <span>&nbsp;</span>
            <button type="button" className="owner-secondary-button op-small" onClick={() => setFilters(EMPTY)}>Clear filters</button>
          </div>
        )}
      </div>

      {notice && <div className="ic-notice op-gap" role="status">{notice}</div>}
      {error && <div className="owner-form-error op-gap" role="alert">Could not load audit logs: {error}</div>}

      <section className="owner-panel">
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead>
              <tr><th>When</th><th>Action</th><th>Business</th><th>By</th><th /></tr>
            </thead>
            <tbody>
              {logs.map((log) => (
                <Fragment key={log.id}>
                  <tr>
                    <td title={formatDateTime(log.created_at)}>
                      <div className="owner-business-cell">
                        <strong>{formatDateTime(log.created_at)}</strong>
                        <span>{timeAgo(log.created_at)}</span>
                      </div>
                    </td>
                    <td><strong className="op-strong">{label(log.action)}</strong></td>
                    <td>
                      {log.business_id ? (
                        <button type="button" className="op-name" onClick={() => onOpenBusiness(log.business_id)}>
                          {log.business_name ?? "Deleted business"}
                        </button>
                      ) : "None"}
                    </td>
                    <td>{log.actor ?? "Unknown user"}</td>
                    <td>
                      {(log.new_data || log.old_data) && (
                        <button type="button" className="op-link" onClick={() => setExpanded(expanded === log.id ? null : log.id)}>
                          {expanded === log.id ? "Hide" : "Details"}
                        </button>
                      )}
                    </td>
                  </tr>
                  {expanded === log.id && (
                    <tr className="op-detail-row">
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
                <tr>
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
          {cursor && (
            <button type="button" className="owner-secondary-button op-small" onClick={() => load(cursor)} disabled={loading}>
              {loading ? "Loading..." : "Load older"}
            </button>
          )}
        </div>
      </section>
    </section>
  );
}
