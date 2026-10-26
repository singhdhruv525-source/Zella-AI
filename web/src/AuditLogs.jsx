import { Fragment, useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { ACTION_LABELS, actionLabel, formatDateTime, timeAgo } from "./ownerFormat";

export default function AuditLogs({ onOpenBusiness }) {
  const [logs, setLogs] = useState([]);
  const [businesses, setBusinesses] = useState([]);
  const [businessId, setBusinessId] = useState("");
  const [search, setSearch] = useState("");
  const [cursor, setCursor] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(null);

  const load = useCallback(async (before) => {
    setLoading(true);
    setError("");
    try {
      const data = await callOwnerFunction("audit_logs", { businessId, search, before });
      setLogs((current) => (before ? [...current, ...data.logs] : data.logs));
      setCursor(data.nextCursor);
      if (data.businesses) setBusinesses(data.businesses);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [businessId, search]);

  useEffect(() => {
    load(null);
  }, [load]);

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Security</div>
          <h1>Audit logs</h1>
          <p>Every admin action on client businesses: who did it, what changed and when.</p>
        </div>
        <button type="button" className="owner-secondary-button" onClick={() => load(null)} disabled={loading}>
          {loading ? "Loading..." : "↻ Refresh"}
        </button>
      </div>

      <div className="op-filters">
        <label className="owner-field">
          <span>Business</span>
          <select value={businessId} onChange={(e) => setBusinessId(e.target.value)}>
            <option value="">All businesses</option>
            {businesses.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </label>
        <label className="owner-field">
          <span>Action</span>
          <select value={search} onChange={(e) => setSearch(e.target.value)}>
            <option value="">All actions</option>
            {Object.entries(ACTION_LABELS).map(([key, text]) => <option key={key} value={key}>{text}</option>)}
          </select>
        </label>
      </div>

      {error && <div className="owner-form-error op-gap">Could not load audit logs: {error}</div>}

      <section className="owner-panel">
        <div className="owner-table-wrap">
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
                    <td><strong className="op-strong">{actionLabel(log.action)}</strong></td>
                    <td>
                      {log.business_id ? (
                        <button type="button" className="op-name" onClick={() => onOpenBusiness(log.business_id)}>
                          {log.business_name ?? "Deleted business"}
                        </button>
                      ) : "—"}
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
                          {log.ip_address ? ` · IP ${log.ip_address}` : ""}
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
                      {loading ? "Loading audit logs..." : businessId || search ? "No matching entries." : "No admin actions recorded yet."}
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
