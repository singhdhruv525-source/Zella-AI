import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";
import PlatformMonitoring from "./PlatformMonitoring";

export default function PlatformOperations({ onNavigate, onOpenBusiness }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("platform_status"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const h = data?.health;
  const problems = h ? h.failedSetups + h.failedInvites + h.brokenIntegrations + h.urgentTickets : 0;
  const missingRequired = data?.configuration?.filter((c) => c.required && !c.set) ?? [];

  const rows = h ? [
    ["Failed setups", h.failedSetups, "Businesses", "Businesses whose setup is marked as failed"],
    ["Failed owner invitations", h.failedInvites, "Overview", "Invitation emails that couldn't be sent"],
    ["Integration problems", h.brokenIntegrations, "Integrations", "Connections in error or disconnected"],
    ["Urgent support tickets", h.urgentTickets, "Support", "Open tickets marked urgent"],
  ] : [];

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">OPERATIONS</div>
          <h1>Platform operations</h1>
          <p>Health of the Zella platform and anything that needs fixing.</p>
        </div>
        <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
          {loading ? "Checking..." : "↻ Run check"}
        </button>
      </div>

      {error && <div className="owner-form-error op-gap">Health check failed: {error}</div>}

      {data && (
        <div className={`po-banner ${problems || missingRequired.length ? "warn" : "ok"}`}>
          <strong>
            {problems || missingRequired.length
              ? `${problems + missingRequired.length} ${problems + missingRequired.length === 1 ? "issue needs" : "issues need"} attention`
              : "All systems normal"}
          </strong>
          <span>Checked {formatDateTime(data.checkedAt)}</span>
        </div>
      )}

      <div className="owner-stat-grid">
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Businesses</span></div><div className="owner-stat-value">{loading && !data ? "…" : h?.businesses ?? 0}</div><div className="owner-stat-note">{h?.activeIndustries ?? 0} industries active</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Calls (24 h)</span></div><div className="owner-stat-value">{loading && !data ? "…" : h?.callsLast24h ?? 0}</div><div className="owner-stat-note">Across all businesses</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Admin actions (24 h)</span></div><div className="owner-stat-value">{loading && !data ? "…" : h?.auditLast24h ?? 0}</div><div className="owner-stat-note">From the audit log</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Open problems</span></div><div className="owner-stat-value">{loading && !data ? "…" : problems}</div><div className="owner-stat-note">See below</div></div>
      </div>

      <div className="op-grid">
        <section className="owner-panel op-card">
          <div className="owner-panel-heading"><div><h2>Problems</h2><p>Things that block clients or need a person.</p></div></div>
          <ul className="op-list">
            {rows.map(([title, count, page, detail]) => (
              <li key={title}>
                <div>
                  <strong>{title}</strong>
                  <span>{detail}</span>
                </div>
                <div className="po-count">
                  <Pill tone={count ? "danger" : "success"}>{count ? count : "None"}</Pill>
                  {count > 0 && <button type="button" className="op-link" onClick={() => onNavigate(page)}>Review</button>}
                </div>
              </li>
            ))}
            {!rows.length && <li><span className="op-muted">{loading ? "Checking..." : "No data"}</span></li>}
          </ul>
        </section>

        <section className="owner-panel op-card">
          <div className="owner-panel-heading"><div><h2>Services</h2><p>Whether each service is configured on the server. Keys are never shown.</p></div></div>
          <ul className="op-list">
            {(data?.configuration ?? []).map((c) => (
              <li key={c.key}>
                <div>
                  <strong>{c.label}</strong>
                  <span>{c.key}{c.required ? " · required" : " · needed for go-live"}</span>
                </div>
                <Pill tone={c.set ? "success" : c.required ? "danger" : "neutral"}>{c.set ? "Configured" : "Not set"}</Pill>
              </li>
            ))}
          </ul>
        </section>
      </div>

      <PlatformMonitoring onOpenBusiness={onOpenBusiness} />
    </section>
  );
}
