import { useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { stageLabel, timeAgo } from "./ownerFormat";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { emptyText, metric } from "./admin/loadStatus";
import { answeringText, livePill, missingForLive, outcomePill, versionText } from "./connectionState.js";
import AgentDeliveries from "./AgentDeliveries";

const CHECKS = [
  ["knowledge", "Knowledge", "Services or FAQs added"],
  ["hours", "Hours", "Business hours set"],
  ["greeting", "Greeting", "Greeting written"],
  ["phone", "Phone", "Active phone number"],
  ["voice", "Voice", "Number linked to Vapi"],
];

const FILTERS = [
  ["all", "All"],
  ["live", "Live"],
  ["answering", "Answering"],
  ["off", "Not live"],
  ["missing", "Missing knowledge"],
  ["ready", "Ready to connect"],
];

// Live and answering come from the server's one definition (docs/PRODUCT.md §9.1): the page never works them out.
function matches(agent, filter) {
  if (filter === "live") return agent.live === true;
  if (filter === "answering") return agent.answering === true;
  if (filter === "off") return agent.live !== true;
  if (filter === "missing") return !agent.checks.knowledge;
  if (filter === "ready") {
    return agent.checks.knowledge && agent.checks.hours && agent.checks.greeting && !agent.checks.voice;
  }
  return true;
}
const loadAgents = () => callOwnerFunction("agents_list");

export default function AIAgents({ onOpenBusiness, onOpenSetup }) {
  const state = useRefreshable(loadAgents);
  const { data, loading } = state;
  const load = state.reload;
  const [filter, setFilter] = useState("all");
  const [search, setSearch] = useState("");
  const [drawer, setDrawer] = useState(null);

  const query = search.trim().toLowerCase();
  const agents = (data?.agents ?? []).filter(
    (a) => matches(a, filter) && (!query || `${a.businessName} ${a.industry} ${a.name}`.toLowerCase().includes(query))
  );
  const s = data?.stats;
  const show = (v) => metric(v, state);   // missing or not loaded: "—", never 0
  const available = data?.connectionsAvailable !== false;
  const showLink = (v) => (available ? show(v) : "Not available");

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
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Receptionists</span></div><div className="owner-stat-value">{show(s?.total)}</div><div className="owner-stat-note">{`One per business · ${show(s?.missingKnowledge)} missing knowledge`}</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Live</span></div><div className="owner-stat-value">{showLink(s?.live)}</div><div className="owner-stat-note">Switched on, number linked to Vapi</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Answering</span></div><div className="owner-stat-value">{showLink(s?.answering)}</div><div className="owner-stat-note">{typeof s?.notReady7d === "number" ? `Answered a call in 7 days · ${s.notReady7d} had calls not ready` : "Answered a call in the last 7 days"}</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Ready to connect</span></div><div className="owner-stat-value">{showLink(s?.readyToConnect)}</div><div className="owner-stat-note">Set up, number not linked to Vapi</div></div>
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
                <th>Calls served (7 d)</th>
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
                      <span>{a.industry} · {a.stage === "active" ? "Setup finished" : stageLabel(a.stage)}</span>
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
                    <div className="owner-business-cell">
                      <span><Pill tone={livePill(a, available)[0]}>{livePill(a, available)[1]}</Pill></span>
                      <span>{answeringText(a.answering, a.lastServedAt, available)}</span>
                      {available && !a.live && missingForLive(a).length > 0 && <span>Needs {missingForLive(a).join(", ")}</span>}
                    </div>
                  </td>
                  <td>
                    {a.delivery ? (
                      <div className="owner-business-cell">
                        <span>{a.delivery.lastOutcome
                          ? <><Pill tone={outcomePill(a.delivery.lastOutcome)[0]}>{outcomePill(a.delivery.lastOutcome)[1]}</Pill> {timeAgo(a.delivery.lastAt)}</>
                          : "No calls reached Zella Voice yet"}</span>
                        <span>{a.delivery.served7d} served · {a.delivery.notReady7d} not ready</span>
                        <span>{versionText(a.delivery)}</span>
                      </div>
                    ) : <span className="op-muted">Not available</span>}
                  </td>
                  <td>
                    <div className="owner-business-cell">
                      <strong>{a.aiCallsLast30Days}</strong>
                      <span>{a.lastCallAt ? `Last call ${timeAgo(a.lastCallAt)}` : "No calls yet"}</span>
                    </div>
                  </td>
                  <td>
                    <div className="op-heading-actions">
                      {data?.deliveriesAvailable && (
                        <button type="button" className="owner-secondary-button op-small" onClick={() => setDrawer(a)}>
                          Calls served
                        </button>
                      )}
                      <button type="button" className="owner-secondary-button op-small" onClick={() => onOpenSetup(a.businessId)}>
                        Edit setup
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
              {!agents.length && (
                <tr>
                  <td colSpan={7}>
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
          <span>Live: switched on, with an active number linked to Vapi. Answering: Zella Voice served it a call in the last 7 days.</span>
        </div>
      </section>
      {drawer && <AgentDeliveries agent={drawer} onClose={() => setDrawer(null)} />}
    </section>
  );
}
