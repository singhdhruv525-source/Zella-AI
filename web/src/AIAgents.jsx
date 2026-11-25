import { useEffect, useState } from "react";
import "./OwnerPages.css";
import "./AIAgents.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { stageLabel, formatDateTime } from "./ownerFormat";
import { Icon } from "./BusinessUI";
import { Metric } from "./admin/adminOps";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { emptyText, metric } from "./admin/loadStatus";
import { answeringText, countText, livePill, missingForLive, outcomePill, relativeText, versionText } from "./connectionState.js";
import AgentDeliveries from "./AgentDeliveries";
import AiTesting from "./AiTesting";

// The five setup checks, in the order an admin fixes them. The second word is how a missing one reads.
const CHECKS = [
  ["knowledge", "knowledge", "Services or FAQs added"],
  ["hours", "hours", "Business hours set"],
  ["greeting", "greeting", "Greeting written"],
  ["phone", "phone", "Active phone number"],
  ["voice", "voice", "Number linked to Vapi"],
];

const plural = (n, word) => `${countText(n) || 0} ${word}${Number(n) === 1 ? "" : "s"}`;

// The phone and voice checks come from the connection state: when it isn't available they are unknown, not missing.
const CONNECTION_CHECKS = new Set(["phone", "voice"]);

// "3 of 5 set" and what is missing on a muted line that wraps (the full list is in the title). The words alone carry it:
// the row of dots was removed (owner approved 25 Nov 2026).
function SetupCell({ checks, available = true }) {
  const known = CHECKS.filter(([key]) => available || !CONNECTION_CHECKS.has(key));
  const done = known.filter(([key]) => checks?.[key]);
  const missing = known.filter(([key]) => !checks?.[key]);
  const unknown = CHECKS.length - known.length;
  const detail = CHECKS.map(([key, , title]) => `${title}: ${!known.some(([k]) => k === key) ? "not available" : checks?.[key] ? "yes" : "no"}`).join("\n");
  return (
    <div className="ag-setup" title={detail}>
      <div className="ag-setup-top">
        <span className="ag-setup-count">{done.length} of {CHECKS.length} set</span>
      </div>
      <span className="ag-line ag-setup-missing">
        {missing.length ? `Missing: ${missing.map(([, word]) => word).join(", ")}` : unknown ? "Everything else set" : "Everything set"}
        {unknown ? `${missing.length ? "; " : ". "}phone and voice not available` : ""}
      </span>
    </div>
  );
}

const FILTERS = [
  ["all", "All"],
  ["live", "Live"],
  ["answering", "Answering"],
  ["off", "Not live"],
  ["missing", "Missing knowledge"],
  ["ready", "Ready to connect"],
];

// Filters that need the connection state; while it isn't available they are switched off rather than guessing.
const CONNECTION_FILTERS = new Set(["live", "answering", "off", "ready"]);

// Live and answering come from the server's one definition (docs/PRODUCT.md §9.1): the page never works them out.
function matches(agent, filter, available = true) {
  if (!available && CONNECTION_FILTERS.has(filter)) return false;
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
  const [tab, setTab] = useState("receptionists");
  const [testingRefresh, setTestingRefresh] = useState(0);
  const [me, setMe] = useState(null);
  useEffect(() => {
    let live = true;
    callOwnerFunction("me_admin").then((m) => live && setMe(m)).catch(() => live && setMe(null));
    return () => { live = false; };
  }, []);

  const available = data?.connectionsAvailable !== false;
  const query = search.trim().toLowerCase();
  const agents = (data?.agents ?? []).filter(
    (a) => matches(a, filter, available) && (!query || `${a.businessName} ${a.industry} ${a.name}`.toLowerCase().includes(query))
  );
  const s = data?.stats;
  const show = (v) => metric(v, state);   // missing or not loaded: "—", never 0
  const showLink = (v) => (available ? show(v) : "Not available");

  return (
    <section className="owner-page ag-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">AI and communications</div>
          <h1>AI receptionists</h1>
          <p>Every client's receptionist, how complete its setup is, and whether it's connected and answering calls.</p>
        </div>
        <div className="op-heading-actions">
          <UpdatedAt r={state} />
          <button type="button" className="owner-secondary-button ag-refresh" onClick={() => { load(); setTestingRefresh((n) => n + 1); }} disabled={loading}>
            <Icon name="refresh" size="sm" />{loading ? "Loading..." : "Refresh"}
          </button>
        </div>
      </div>

      <LoadNotice r={state} what="AI receptionists" />

      <div className="ag-filters ait-tabs op-gap" role="tablist" aria-label="AI receptionists views">
        {[["receptionists", "Receptionists"], ["testing", "AI testing"]].map(([key, label]) => (
          <button key={key} type="button" role="tab" aria-selected={tab === key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>{label}</button>
        ))}
      </div>

      {tab === "testing" ? <AiTesting me={me} onOpenBusiness={onOpenBusiness} refresh={testingRefresh} /> : <>

      <div className="owner-stat-grid">
        <Metric label="Receptionists" value={show(s?.total)} note={typeof s?.missingKnowledge === "number" ? `One per business, ${countText(s.missingKnowledge)} missing knowledge` : "One per business"} />
        <Metric label="Live" value={showLink(s?.live)} note="Switched on, number linked to Vapi" />
        <Metric label="Answering" value={showLink(s?.answering)} note={typeof s?.notReady7d === "number" ? `Answered a call in the last 7 days, ${countText(s.notReady7d)} had calls not ready` : "Answered a call in the last 7 days"} />
        <Metric label="Ready to connect" value={showLink(s?.readyToConnect)} note="Set up, number not linked to Vapi" />
      </div>

      <section className="owner-panel">
        <div className="owner-panel-heading ag-toolbar">
          <div className="ag-filters" role="tablist" aria-label="Show receptionists">
            {FILTERS.map(([key, label]) => (
              <button
                key={key}
                type="button"
                role="tab"
                aria-selected={filter === key}
                className={filter === key ? "active" : ""}
                disabled={!available && CONNECTION_FILTERS.has(key)}
                title={!available && CONNECTION_FILTERS.has(key) ? "Not available until the connection state can be read" : undefined}
                onClick={() => setFilter(key)}
              >
                {label}
              </button>
            ))}
          </div>
          <input
            className="ag-search"
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search business"
            aria-label="Search business"
          />
        </div>

        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table owner-table--cards ag-table">
            <thead>
              <tr>
                <th>Business</th>
                <th>Receptionist</th>
                <th>Setup</th>
                <th>Status</th>
                <th>Calls served, last 7 days</th>
                <th className="num">AI calls, last 30 days</th>
                <th className="col-actions" aria-label="Actions" />
              </tr>
            </thead>
            <tbody>
              {agents.map((a) => {
                const [tone, word] = livePill(a, available);
                const needs = available && !a.live ? missingForLive(a) : [];
                const answering = answeringText(a.answering, a.lastServedAt, available);
                const statusLine = needs.length ? `Needs ${needs.join(", ")}` : answering;
                const knowledge = `${plural(a.services, "service")}, ${plural(a.faqs, "FAQ")}`;
                const custom = a.name && a.name !== "Receptionist" ? a.name : "";
                return (
                  <tr key={a.agentId}>
                    <td>
                      <div className="ag-cell">
                        <button type="button" className="op-name ag-name" title={a.businessName} onClick={() => onOpenBusiness(a.businessId)}>
                          {a.businessName}
                        </button>
                        <span className="ag-line">{a.industry} · {a.stage === "active" ? "Setup finished" : stageLabel(a.stage)}</span>
                      </div>
                    </td>
                    <td data-label="Receptionist">
                      <div className="ag-cell" title={[custom, a.personality].filter(Boolean).join(", ") || undefined}>
                        <span className="ag-nowrap">{knowledge}</span>
                        {custom && <span className="ag-line">{custom}</span>}
                      </div>
                    </td>
                    <td data-label="Setup"><SetupCell checks={a.checks} available={available} /></td>
                    <td data-label="Status">
                      {/* an unrecognised or missing status is shown as unknown, never as live or off */}
                      <div className="ag-cell" title={needs.length ? `${answering}. ${statusLine}.` : statusLine}>
                        <span><Pill tone={tone}>{word}</Pill></span>
                        <span className="ag-line">{statusLine}</span>
                      </div>
                    </td>
                    <td data-label="Calls served, last 7 days">
                      {a.delivery ? (
                        <div className="ag-cell">
                          <span>{a.delivery.lastOutcome
                            ? <><Pill tone={outcomePill(a.delivery.lastOutcome)[0]}>{outcomePill(a.delivery.lastOutcome)[1]}</Pill> {relativeText(a.delivery.lastAt)}</>
                            : "No calls reached Zella Voice yet"}</span>
                          <span className="ag-line">{countText(a.delivery.served7d) || "0"} served, {countText(a.delivery.notReady7d) || "0"} not ready</span>
                          <span className="ag-line">{versionText(a.delivery)}</span>
                        </div>
                      ) : <span className="op-muted">Not available</span>}
                    </td>
                    <td data-label="AI calls, last 30 days" className="num">
                      <span title={a.lastCallAt ? `Last call ${relativeText(a.lastCallAt)} (${formatDateTime(a.lastCallAt)})` : "No calls yet"}>
                        {countText(a.aiCallsLast30Days) || "0"}
                      </span>
                    </td>
                    <td className="col-actions">
                      {data?.deliveriesAvailable && (
                        <button type="button" className="owner-secondary-button op-small ag-action" onClick={() => setDrawer({ agent: a, asOf: state.lastOk })}>
                          Calls served
                        </button>
                      )}
                      <button type="button" className="owner-secondary-button op-small ag-action" onClick={() => onOpenSetup(a.businessId)}>
                        Edit setup
                      </button>
                    </td>
                  </tr>
                );
              })}
              {!agents.length && (
                <tr className="ag-empty-row">
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
        <div className="owner-panel-footer ag-foot">
          <span>{countText(agents.length) || 0} shown</span>
          <span>Live: switched on, with an active number linked to Vapi. Answering: Zella Voice served it a call in the last 7 days.</span>
        </div>
      </section>
      </>}
      {drawer && <AgentDeliveries agent={drawer.agent} asOf={drawer.asOf} onClose={() => setDrawer(null)} />}
    </section>
  );
}
