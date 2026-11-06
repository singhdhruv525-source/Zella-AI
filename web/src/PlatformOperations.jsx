import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";
import PlatformMonitoring from "./PlatformMonitoring";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { isCount, metric } from "./admin/loadStatus";

const loadStatus = () => callOwnerFunction("platform_status");
// whether automations are switched off on purpose (n8n_dispatch_enabled), from the existing Automations overview
const loadAutomation = () => callOwnerFunction("automation_overview");

// What this page actually checks. It is not a test of whether phone, voice, text or email providers are reachable.
const SCOPE = "Covers failed setups, failed owner invitations, integrations in error, urgent support tickets and the required server settings. It doesn't test whether the phone, voice, text or email providers are reachable.";

// One service's line: configured, missing (required or for go-live), switched off on purpose, or unknown.
function serviceState(c, automation) {
  const n8n = c.key === "N8N_WEBHOOK_URL";
  if (n8n && automation.status === "failed") return { tone: "neutral", label: "Status unknown", kind: "unknown" };
  if (n8n && automation.data?.n8n?.dispatchEnabled === false) return { tone: "neutral", label: "Turned off on purpose", kind: "disabled" };
  if (c.set) return { tone: "success", label: "Configured", kind: "configured" };
  if (c.required) return { tone: "danger", label: "Missing (required)", kind: "missing_required" };
  return { tone: "neutral", label: "Not set", kind: "missing_optional" };
}

// The banner: issues, incomplete, failed or nothing found, always scoped to the checks that ran.
function healthSummary(r, automation) {
  if (r.status === "loading") return null;
  if (r.status === "failed") return { tone: "warn", state: "failed", text: "Health check failed: no results, so nothing here is confirmed healthy." };
  const h = r.data?.health ?? {};
  const counts = [h.failedSetups, h.failedInvites, h.brokenIntegrations, h.urgentTickets];
  const complete = counts.every(isCount) && Array.isArray(r.data?.configuration);
  const problems = counts.filter(isCount).reduce((a, b) => a + b, 0);
  const missing = (r.data?.configuration ?? []).filter((c) => c.required && !c.set).length;
  const issues = problems + missing;
  if (issues) return { tone: "warn", state: "issues", text: `${issues} ${issues === 1 ? "issue" : "issues"} found${missing ? ` (${missing} required ${missing === 1 ? "setting" : "settings"} missing)` : ""}` };
  if (!complete || automation.status === "failed") return { tone: "warn", state: "incomplete", text: "Checks incomplete: no issues in the checks that ran, but some results are missing." };
  return { tone: "ok", state: "clear", text: "No issues found in the checks below" };
}

export default function PlatformOperations({ onNavigate, onOpenBusiness }) {
  const r = useRefreshable(loadStatus);
  const automation = useRefreshable(loadAutomation);
  const { data, loading } = r;
  const load = () => { r.reload(); automation.reload(); };

  const h = data?.health;
  const summary = healthSummary(r, automation);
  const counts = h ? [h.failedSetups, h.failedInvites, h.brokenIntegrations, h.urgentTickets] : [];
  const problems = counts.length && counts.every(isCount) ? counts.reduce((a, b) => a + b, 0) : null;

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
          <div className="owner-eyebrow">Operations</div>
          <h1>Platform operations</h1>
          <p>Health of the Zella platform and anything that needs fixing.</p>
        </div>
        <div className="op-heading-actions">
          <UpdatedAt r={r} />
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Checking..." : "↻ Run check"}
          </button>
        </div>
      </div>

      <LoadNotice r={r} what="the health check" />

      {summary && (
        <div className={`po-banner ${summary.tone}`} data-health={summary.state} role={summary.state === "clear" ? "status" : "alert"}>
          <strong>{summary.text}</strong>
          <span>{SCOPE}{data?.checkedAt ? ` Checked ${formatDateTime(data.checkedAt)}${r.status === "stale" ? " (earlier result)" : ""}.` : ""}</span>
        </div>
      )}

      <div className="owner-stat-grid">
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Businesses</span></div><div className="owner-stat-value">{metric(h?.businesses, r)}</div><div className="owner-stat-note">{metric(h?.activeIndustries, r)} industries active</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Calls (24 h)</span></div><div className="owner-stat-value">{metric(h?.callsLast24h, r)}</div><div className="owner-stat-note">Across all businesses</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Admin actions (24 h)</span></div><div className="owner-stat-value">{metric(h?.auditLast24h, r)}</div><div className="owner-stat-note">From the audit log</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Open problems</span></div><div className="owner-stat-value">{metric(problems, r)}</div><div className="owner-stat-note">See below</div></div>
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
                  {/* a count the answer didn't include is unknown, not "None" */}
                  <Pill tone={!isCount(count) ? "neutral" : count ? "danger" : "success"}>{!isCount(count) ? "Unknown" : count ? count : "None found"}</Pill>
                  {isCount(count) && count > 0 && <button type="button" className="op-link" onClick={() => onNavigate(page)}>Review</button>}
                </div>
              </li>
            ))}
            {!rows.length && <li><span className="op-muted">{r.status === "loading" ? "Checking..." : "Not checked: the health check didn't return results."}</span></li>}
          </ul>
        </section>

        <section className="owner-panel op-card">
          <div className="owner-panel-heading"><div><h2>Services</h2><p>Whether each service is configured on the server. Keys are never shown.</p></div></div>
          <ul className="op-list">
            {(data?.configuration ?? []).map((c) => {
              const st = serviceState(c, automation);
              return (
                <li key={c.key} data-service={c.key} data-service-state={st.kind}>
                  <div>
                    <strong>{c.label}</strong>
                    <span>{c.key}{c.required ? " · required" : " · needed for go-live"}{st.kind === "disabled" ? " · automations are switched off (not an outage)" : ""}</span>
                  </div>
                  <Pill tone={st.tone}>{st.label}</Pill>
                </li>
              );
            })}
            {!Array.isArray(data?.configuration) && <li><span className="op-muted">{r.status === "loading" ? "Checking..." : "Not checked: no configuration results."}</span></li>}
          </ul>
        </section>
      </div>

      <PlatformMonitoring onOpenBusiness={onOpenBusiness} />
    </section>
  );
}
