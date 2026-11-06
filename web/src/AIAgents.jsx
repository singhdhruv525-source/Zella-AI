import { useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { stageLabel, timeAgo } from "./ownerFormat";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { emptyText, metric } from "./admin/loadStatus";

const CHECKS = [
  ["knowledge", "Knowledge", "Services or FAQs added"],
  ["hours", "Hours", "Business hours set"],
  ["greeting", "Greeting", "Greeting written"],
  ["phone", "Phone", "Telnyx number connected"],
  ["voice", "Voice", "Vapi agent connected"],
];

const FILTERS = [
  ["all", "All"],
  ["live", "Live"],
  ["off", "Off"],
  ["missing", "Missing knowledge"],
  ["ready", "Ready to connect"],
];

// Live only when the server reports it active AND its phone (Telnyx) and voice (Vapi) connections active. New agents
// start "active" in the database before anything is connected, so status alone doesn't mean it answers calls.
const isLive = (agent) => agent?.status === "active" && agent?.checks?.phone === true && agent?.checks?.voice === true;

function matches(agent, filter) {
  if (filter === "live") return isLive(agent);
  if (filter === "off") return !isLive(agent);
  if (filter === "missing") return !agent.checks.knowledge;
  if (filter === "ready") {
    return agent.checks.knowledge && agent.checks.hours && agent.checks.greeting && !agent.checks.phone;
  }
  return true;
}

// The status the server reports (ai_agents.status: active, paused, disabled); anything else shows as unknown.
const STATUS_PILL = { paused: ["warning", "Paused"], disabled: ["neutral", "Off"] };
function agentPill(agent) {
  if (isLive(agent)) return ["success", "Live"];
  if (agent?.status === "active") return ["neutral", "Not connected"];
  return STATUS_PILL[agent?.status] ?? ["neutral", "Unknown"];
}
const loadAgents = () => callOwnerFunction("agents_list");

export default function AIAgents({ onOpenBusiness, onOpenSetup }) {
  const state = useRefreshable(loadAgents);
  const { data, loading } = state;
  const load = state.reload;
  const [filter, setFilter] = useState("all");
  const [search, setSearch] = useState("");

  const query = search.trim().toLowerCase();
  const agents = (data?.agents ?? []).filter(
    (a) => matches(a, filter) && (!query || `${a.businessName} ${a.industry} ${a.name}`.toLowerCase().includes(query))
  );
  const s = data?.stats;
  const show = (v) => metric(v, state);   // missing or not loaded: "—", never 0
  const liveCount = Array.isArray(data?.agents) ? data.agents.filter(isLive).length : null;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">AI</div>
          <h1>AI receptionists</h1>
          <p>Every client's receptionist, how complete its setup is, and whether it's connected and answering calls.</p>
        </div>
        <div className="op-heading-actions">
          <UpdatedAt r={state} />
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "↻ Refresh"}
          </button>
        </div>
      </div>

      <LoadNotice r={state} what="AI receptionists" />

      <div className="owner-stat-grid">
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Receptionists</span></div><div className="owner-stat-value">{show(s?.total)}</div><div className="owner-stat-note">One per business</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Live</span></div><div className="owner-stat-value">{show(liveCount)}</div><div className="owner-stat-note">Active, with phone and voice connected</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Ready to connect</span></div><div className="owner-stat-value">{show(s?.readyToConnect)}</div><div className="owner-stat-note">Set up, phone not connected</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Missing knowledge</span></div><div className="owner-stat-value">{show(s?.missingKnowledge)}</div><div className="owner-stat-note">No services or FAQs</div></div>
      </div>

      <section className="owner-panel">
        <div className="owner-panel-heading ag-toolbar">
          <div className="ag-filters" role="tablist">
            {FILTERS.map(([key, label]) => (
              <button
                key={key}
                type="button"
                role="tab"
                aria-selected={filter === key}
                className={filter === key ? "active" : ""}
                onClick={() => setFilter(key)}
              >
                {label}
              </button>
            ))}
          </div>
          <input
            className="ag-search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search business"
            aria-label="Search business"
          />
        </div>

        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead>
              <tr>
                <th>Business</th>
                <th>Receptionist</th>
                <th>Setup</th>
                <th>Status</th>
                <th>AI calls (30 d)</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {agents.map((a) => (
                <tr key={a.agentId}>
                  <td>
                    <div className="owner-business-cell">
                      <button type="button" className="op-name" onClick={() => onOpenBusiness(a.businessId)}>
                        {a.businessName}
                      </button>
                      <span>{a.industry} · {stageLabel(a.stage)}</span>
                    </div>
                  </td>
                  <td>
                    <div className="owner-business-cell">
                      <strong>{a.name}</strong>
                      <span>{a.services} services · {a.faqs} FAQs{a.personality ? ` · ${a.personality}` : ""}</span>
                    </div>
                  </td>
                  <td>
                    <div className="ag-checks" aria-label={`${a.ready} of ${CHECKS.length} setup checks done`}>
                      {CHECKS.map(([key, label, title]) => (
                        <span key={key} className={a.checks[key] ? "ok" : ""} title={`${title}: ${a.checks[key] ? "yes" : "no"}`}>
                          {label}
                        </span>
                      ))}
                    </div>
                  </td>
                  <td>
                    {/* an unrecognised or missing status is shown as unknown, never as live or off */}
                    <Pill tone={agentPill(a)[0]}>{agentPill(a)[1]}</Pill>
                  </td>
                  <td>
                    <div className="owner-business-cell">
                      <strong>{a.aiCallsLast30Days}</strong>
                      <span>{a.lastCallAt ? `Last call ${timeAgo(a.lastCallAt)}` : "No calls yet"}</span>
                    </div>
                  </td>
                  <td>
                    <button type="button" className="owner-secondary-button op-small" onClick={() => onOpenSetup(a.businessId)}>
                      Edit setup
                    </button>
                  </td>
                </tr>
              ))}
              {!agents.length && (
                <tr>
                  <td colSpan={6}>
                    <div className="op-empty">
                      {data?.agents?.length
                        ? "No receptionists match this filter."
                        : emptyText(state, Array.isArray(data?.agents) ? "No AI receptionists yet. One is created with each new business." : "Not reported.", "AI receptionists")}
                    </div>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <div className="owner-panel-footer">
          <span>{agents.length} shown</span>
          <span>A receptionist goes live only after its phone number and voice agent are connected.</span>
        </div>
      </section>
    </section>
  );
}
