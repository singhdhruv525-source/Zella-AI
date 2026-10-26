import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";

const PHONE_LABELS = { new_number: "New number", call_forwarding: "Forwarding", existing_number: "Forwarding" };
const LEAD_LABELS = { meta: "Meta", website: "Website", google: "Google" };

function Need({ wanted, connected, label }) {
  if (!wanted) return <span className="op-muted">—</span>;
  return (
    <span className={`in-need ${connected ? "ok" : ""}`}>
      {connected ? "✓ " : ""}{label}
      {!connected && <em> · not connected</em>}
    </span>
  );
}

export default function IntegrationsPage({ onOpenBusiness }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("integrations_overview"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const requests = (data?.requests ?? []).filter((r) => r.setupDone);
  const waiting = requests.filter(
    (r) => !r.phone.connected || !r.voice.connected || (r.calendar.wanted && !r.calendar.connected) || (r.email?.wanted && !r.email?.connected) ||
      r.leads.wanted.some((l) => !r.leads.connected.includes(l))
  ).length;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Connections</div>
          <h1>Integrations</h1>
          <p>What each client asked for during setup, and which services are actually connected.</p>
        </div>
        <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
          {loading ? "Loading..." : "↻ Refresh"}
        </button>
      </div>

      {error && <div className="owner-form-error op-gap">Could not load integrations: {error}</div>}

      <div className="owner-stat-grid">
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Connections</span></div><div className="owner-stat-value">{loading && !data ? "…" : data?.connections?.length ?? 0}</div><div className="owner-stat-note">Across all businesses</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Active</span></div><div className="owner-stat-value">{loading && !data ? "…" : data?.connections?.filter((c) => c.status === "active").length ?? 0}</div><div className="owner-stat-note">Working</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Problems</span></div><div className="owner-stat-value">{loading && !data ? "…" : data?.connections?.filter((c) => ["error", "disconnected"].includes(c.status)).length ?? 0}</div><div className="owner-stat-note">Error or disconnected</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Waiting to connect</span></div><div className="owner-stat-value">{loading && !data ? "…" : waiting}</div><div className="owner-stat-note">Businesses with requests pending</div></div>
      </div>

      <section className="owner-panel op-card">
        <div className="owner-panel-heading">
          <div>
            <h2>Client requests vs. connected</h2>
            <p>From each business's Phone & integrations setup step.</p>
          </div>
        </div>
        <div className="owner-table-wrap">
          <table className="owner-table">
            <thead><tr><th>Business</th><th>Phone (Telnyx)</th><th>Voice (Vapi)</th><th>Calendar</th><th>Email</th><th>Lead sources</th></tr></thead>
            <tbody>
              {requests.map((r) => (
                <tr key={r.businessId}>
                  <td><button type="button" className="op-name" onClick={() => onOpenBusiness(r.businessId)}>{r.businessName}</button></td>
                  <td><Need wanted={r.phone.wanted} connected={r.phone.connected} label={PHONE_LABELS[r.phone.wanted] ?? r.phone.wanted} /></td>
                  <td><Need wanted={r.voice.wanted} connected={r.voice.connected} label="Voice agent" /></td>
                  <td><Need wanted={r.calendar.wanted} connected={r.calendar.connected} label={r.calendar.wanted === "google" ? "Google Calendar" : "Outlook / Microsoft Calendar"} /></td>
                  <td><Need wanted={r.email?.wanted} connected={r.email?.connected} label={r.email?.wanted === "gmail" ? "Gmail" : "Outlook email"} /></td>
                  <td>
                    {r.leads.wanted.length ? (
                      <div className="in-needs">
                        {r.leads.wanted.map((l) => (
                          <Need key={l} wanted connected={r.leads.connected.includes(l)} label={LEAD_LABELS[l] ?? l} />
                        ))}
                      </div>
                    ) : <span className="op-muted">—</span>}
                  </td>
                </tr>
              ))}
              {!requests.length && (
                <tr><td colSpan={6}><div className="op-empty">{loading ? "Loading..." : "No business has completed the Phone & integrations step yet."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="owner-panel op-card">
        <div className="owner-panel-heading">
          <div>
            <h2>Live connections</h2>
            <p>Services connected and verified for client businesses.</p>
          </div>
        </div>
        <div className="owner-table-wrap">
          <table className="owner-table">
            <thead><tr><th>Business</th><th>Provider</th><th>Type</th><th>Status</th><th>Last sync</th><th>Error</th></tr></thead>
            <tbody>
              {(data?.connections ?? []).map((c) => (
                <tr key={c.id}>
                  <td><button type="button" className="op-name" onClick={() => onOpenBusiness(c.business_id)}>{c.business_name}</button></td>
                  <td className="op-cap">{c.provider}</td>
                  <td>{c.integration_type}</td>
                  <td><Pill tone={c.status === "active" ? "success" : c.status === "error" ? "danger" : "neutral"}>{c.status}</Pill></td>
                  <td>{formatDateTime(c.last_synced_at)}</td>
                  <td className="op-muted">{c.error_message || "—"}</td>
                </tr>
              ))}
              {!data?.connections?.length && (
                <tr><td colSpan={6}><div className="op-empty">{loading ? "Loading..." : "Nothing connected yet. Connections are made when a business goes live."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}
