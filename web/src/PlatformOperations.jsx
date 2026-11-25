import "./OwnerPages.css";
import "./admin/goLive.css";
import { useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";
import PlatformMonitoring from "./PlatformMonitoring";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { isCount, metric } from "./admin/loadStatus";
import { rpc, useLoad } from "./admin/adminOps";
import ScheduledJobs from "./admin/ScheduledJobs";
import GoLiveChecklist from "./admin/GoLiveChecklist";

const loadStatus = () => callOwnerFunction("platform_status");
// whether automations are switched off on purpose (n8n_dispatch_enabled), from the existing Automations overview
const loadAutomation = () => callOwnerFunction("automation_overview");

// What this page actually checks. It is not a test of whether phone, voice, text or email providers are reachable.
const SCOPE = "Checks failed setups, owner invitations, integrations, urgent tickets and server settings. It doesn't test whether phone, text or email providers answer.";

// The banner: issues, incomplete, failed or nothing found, always scoped to the checks that ran.
// jobs: the scheduler health reader (useLoad); a failed or missing answer keeps the banner from saying "clear".
function healthSummary(r, automation, jobs) {
  if (r.status === "loading" || (jobs?.loading && !jobs.data)) return null;
  if (r.status === "failed") return { tone: "warn", state: "failed", text: "Health check failed: no results, so nothing here is confirmed healthy." };
  const h = r.data?.health ?? {};
  const counts = [h.failedSetups, h.failedInvites, h.brokenIntegrations, h.urgentTickets];
  const complete = counts.every(isCount) && Array.isArray(r.data?.configuration);
  const problems = counts.filter(isCount).reduce((a, b) => a + b, 0);
  const missing = (r.data?.configuration ?? []).filter((c) => c.required && !c.set).length;
  // the scheduler's own findings count too: failed workflows and events in 24 hours and its open alerts
  const sj = jobs && !jobs.error && jobs.data && !jobs.data.missing ? jobs.data : null;
  const scheduler = sj ? [sj.failed_24h?.workflows, sj.failed_24h?.events, Array.isArray(sj.alerts) ? sj.alerts.length : 0].filter(isCount).reduce((a, b) => a + b, 0) : 0;
  const issues = problems + missing + scheduler;
  const notes = [missing ? `${missing} required ${missing === 1 ? "setting" : "settings"} missing` : "", scheduler ? `${scheduler} from the scheduler` : ""].filter(Boolean).join(", ");
  if (issues) return { tone: "warn", state: "issues", text: `${issues} ${issues === 1 ? "issue" : "issues"} found${notes ? ` (${notes})` : ""}` };
  const jobsRead = jobs ? !jobs.loading && !jobs.error && jobs.data && typeof jobs.data === "object" && !jobs.data.missing : true;
  if (!complete || automation.status === "failed" || !jobsRead) return { tone: "warn", state: "incomplete", text: "Checks incomplete: no issues in the checks that ran, but some results are missing." };
  return { tone: "ok", state: "clear", text: "No issues found in the checks below" };
}

export default function PlatformOperations({ onNavigate, onOpenBusiness }) {
  const r = useRefreshable(loadStatus);
  const automation = useRefreshable(loadAutomation);
  const { data, loading } = r;
  // each scheduled job's real and intended state (PLT-07); the n8n line says when its job is off
  const jobs = useLoad(() => rpc("zella_admin_scheduler_health"), []);
  // one Refresh in the page header reloads everything on the page, the go live checklist included
  const [refresh, setRefresh] = useState(0);
  const load = () => { r.reload(); automation.reload(); jobs.reload(); setRefresh((n) => n + 1); };

  const h = data?.health;
  const summary = healthSummary(r, automation, jobs);
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
          <p>Health of the Zella Voice platform and anything that needs fixing.</p>
        </div>
        <div className="op-heading-actions">
          <UpdatedAt r={r} />
          <button type="button" className="owner-secondary-button po-refresh" onClick={load} disabled={loading}>
            {loading ? "Checking…" : "Refresh"}
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

      <section className="owner-panel op-card">
        <div className="owner-panel-heading"><div><h2>Problems</h2><p>Things that block clients or need a person.</p></div></div>
        <ul className="op-list po-problems">
          {rows.map(([title, count, page, detail]) => (
            <li key={title}>
              <div>
                <strong>{title}</strong>
                <span>{detail}</span>
              </div>
              <div className="po-count">
                {/* a count the answer didn't include is unknown, not "None" */}
                <Pill tone={!isCount(count) ? "neutral" : count ? "danger" : "success"}>{!isCount(count) ? "Unknown" : count ? count : "None found"}</Pill>
                {isCount(count) && count > 0 && <button type="button" className="owner-secondary-button po-refresh" onClick={() => onNavigate(page)}>Review</button>}
              </div>
            </li>
          ))}
          {!rows.length && <li><span className="op-muted">{r.status === "loading" ? "Checking…" : "Not checked: the health check didn't return results."}</span></li>}
        </ul>
      </section>

      <GoLiveChecklist health={jobs} refresh={refresh} pageReady={r.status !== "loading" && automation.status !== "loading"} />

      <ScheduledJobs health={jobs} showRefresh={false} />

      <PlatformMonitoring onOpenBusiness={onOpenBusiness} />
    </section>
  );
}
