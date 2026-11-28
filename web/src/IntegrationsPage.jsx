import "./OwnerPages.css";
import { Icon } from "./BusinessUI";
import "./IntegrationsPage.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { countOf, emptyText, metric } from "./admin/loadStatus";
import { humanize } from "./copy/labels";
import { NOT_TRACKED } from "./connectionState.js";
import { DotText, Metric } from "./admin/adminOps";

const PHONE_LABELS = { new_number: "New number", forward: "Forwarding", call_forwarding: "Forwarding", existing_number: "Forwarding" };
const LEAD_LABELS = { meta: "Meta", website: "Website", google: "Google" };

// Plain text with a small dot (owner approved 25 Nov 2026): green when connected, grey when not yet. The words say it.
function Need({ wanted, connected, label, available = true }) {
  if (!wanted) return <span className="op-muted">None</span>;
  if (!available) return <DotText className="in-need">{label}<span className="in-need-state">, not available</span></DotText>;
  return (
    <DotText className="in-need" tone={connected ? "success" : "neutral"}>
      {label}
      {!connected && <span className="in-need-state">, not connected</span>}
    </DotText>
  );
}

// Read-only: this page only reads what the server reports; it never starts a provider sign-in or connection.
const loadIntegrations = () => callOwnerFunction("integrations_overview");

export default function IntegrationsPage({ onOpenBusiness }) {
  const state = useRefreshable(loadIntegrations);
  const { data, loading } = state;
  const load = state.reload;

  const connections = Array.isArray(data?.connections) ? data.connections : null;
  const requests = Array.isArray(data?.requests) ? data.requests.filter((r) => r.setupDone) : null;
  // Connected comes from the server's one definition (docs/PRODUCT.md §9.1). Email isn't tracked, so it never counts.
  const available = data?.connectionsAvailable !== false;
  const counts = data?.counts ?? null;
  const waiting = available ? countOf(requests,
    (r) => !r.phone.connected || !r.voice.connected || (r.calendar.wanted && !r.calendar.connected) ||
      r.leads.wanted.some((l) => !r.leads.connected.includes(l))
  ) : null;

  return (
    <section className="owner-page in-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Operations</div>
          <h1>Integrations</h1>
          <p>What each business asked for during setup, and which services are actually connected.</p>
        </div>
        <div className="op-heading-actions">
          <UpdatedAt r={state} />
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading…" : <><Icon name="refresh" size="sm" />Refresh</>}
          </button>
        </div>
      </div>

      <LoadNotice r={state} what="integrations" />

      <div className="owner-stat-grid">
        <Metric label="Numbers linked" value={metric(counts?.vapi_linked, state)} note={typeof counts?.phone === "number" ? `${counts.phone} with an active number` : "Not available"} />
        <Metric label="Live" value={metric(counts?.live, state)} note={typeof counts?.answering === "number" ? `${counts.answering} answered a call in 7 days` : "Answering not available"} />
        <Metric label="Needs attention" value={metric(counts?.problems, state)} note="Connections in error or disconnected" />
        <Metric label="Waiting to connect" value={metric(waiting, state)} note="Businesses with requests pending" />
      </div>

      <section className="owner-panel op-card">
        <div className="owner-panel-heading">
          <div>
            <h2>Asked for and connected</h2>
            <p>From each business's Phone & integrations setup step.</p>
          </div>
        </div>
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead><tr><th>Business</th><th>Phone number</th><th>Voice (Vapi)</th><th>Calendar</th><th>Email</th><th>Lead sources</th></tr></thead>
            <tbody>
              {(requests ?? []).map((r) => (
                <tr key={r.businessId}>
                  <td><button type="button" className="op-name" title={r.businessName} onClick={() => onOpenBusiness(r.businessId)}>{r.businessName}</button></td>
                  <td><Need available={available} wanted={r.phone.wanted} connected={r.phone.connected} label={PHONE_LABELS[r.phone.wanted] ?? r.phone.wanted} /></td>
                  <td>
                    <Need available={available} wanted={r.voice.wanted} connected={r.voice.connected} label="Linked to Vapi" />
                    {available && r.voice.connected && <div className="op-muted">{r.voice.answering ? "Answering" : "No call answered in 7 days"}</div>}
                  </td>
                  <td><Need available={available} wanted={r.calendar.wanted} connected={r.calendar.connected} label={r.calendar.wanted === "google" ? "Google Calendar" : "Outlook / Microsoft Calendar"} /></td>
                  <td>{r.email?.wanted ? <DotText className="in-need">{r.email.wanted === "gmail" ? "Gmail" : "Outlook email"}<span className="in-need-state">, {NOT_TRACKED.toLowerCase()}</span></DotText> : <span className="op-muted">None</span>}</td>
                  <td>
                    {r.leads.wanted.length ? (
                      <div className="in-needs">
                        {r.leads.wanted.map((l) => (
                          <Need key={l} available={available} wanted connected={r.leads.connected.includes(l)} label={LEAD_LABELS[l] ?? l} />
                        ))}
                      </div>
                    ) : <span className="op-muted">None</span>}
                  </td>
                </tr>
              ))}
              {!requests?.length && (
                <tr><td colSpan={6}><div className="op-empty">{emptyText(state, requests ? "No business has completed the Phone & integrations step yet." : "Not reported.", "integrations")}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <section className="owner-panel op-card">
        <div className="owner-panel-heading">
          <div>
            <h2>Integration records</h2>
            <p>Store and other provider connections. Numbers, calendars and lead sources are counted above.</p>
          </div>
        </div>
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead><tr><th>Business</th><th>Provider</th><th>Type</th><th>Status</th><th>Last sync</th><th>Error</th></tr></thead>
            <tbody>
              {(connections ?? []).map((c) => (
                <tr key={c.id}>
                  <td><button type="button" className="op-name" onClick={() => onOpenBusiness(c.business_id)}>{c.business_name}</button></td>
                  <td className="op-cap">{c.provider}</td>
                  <td>{c.integration_type}</td>
                  <td><Pill tone={c.status === "active" ? "success" : c.status === "error" ? "danger" : "neutral"}>{humanize(c.status)}</Pill></td>
                  <td>{formatDateTime(c.last_synced_at)}</td>
                  <td className="op-muted">{c.error_message || "None"}</td>
                </tr>
              ))}
              {!connections?.length && (
                <tr><td colSpan={6}><div className="op-empty">{emptyText(state, connections ? "Nothing connected yet. Connections are made when a business goes live." : "Not reported.", "integrations")}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}
