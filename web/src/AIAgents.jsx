import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { stageLabel, timeAgo } from "./ownerFormat";

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

function matches(agent, filter) {
  if (filter === "live") return agent.status === "active";
  if (filter === "off") return agent.status !== "active";
  if (filter === "missing") return !agent.checks.knowledge;
  if (filter === "ready") {
    return agent.checks.knowledge && agent.checks.hours && agent.checks.greeting && !agent.checks.phone;
  }
  return true;
}

export default function AIAgents({ onOpenBusiness, onOpenSetup }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState("all");
  const [search, setSearch] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("agents_list"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const query = search.trim().toLowerCase();
  const agents = (data?.agents ?? []).filter(
    (a) => matches(a, filter) && (!query || `${a.businessName} ${a.industry} ${a.name}`.toLowerCase().includes(query))
  );
  const s = data?.stats;
  const show = (v) => (loading && !data ? "…" : v ?? 0);

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">AI</div>
          <h1>AI receptionists</h1>
          <p>Every client's receptionist, how complete its setup is, and whether it's connected and answering calls.</p>
        </div>
        <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
          {loading ? "Loading..." : "↻ Refresh"}
        </button>
      </div>

      {error && <div className="owner-form-error op-gap">Could not load AI receptionists: {error}</div>}

      <div className="owner-stat-grid">
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Receptionists</span></div><div className="owner-stat-value">{show(s?.total)}</div><div className="owner-stat-note">One per business</div></div>
        <div className="owner-stat-card"><div className="owner-stat-top"><span>Live</span></div><div className="owner-stat-value">{show(s?.live)}</div><div className="owner-stat-note">Answering calls</div></div>
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

        <div className="owner-table-wrap">
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
                    <Pill tone={a.status === "active" ? "success" : a.status === "paused" ? "warning" : "neutral"}>
                      {a.status === "active" ? "Live" : a.status === "paused" ? "Paused" : "Off"}
                    </Pill>
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
                      {loading && !data
                        ? "Loading AI receptionists..."
                        : data?.agents?.length
                        ? "No receptionists match this filter."
                        : "No AI receptionists yet. One is created with each new business."}
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
