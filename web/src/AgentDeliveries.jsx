// COM-03: one business's recent calls and what each got from Zella Voice (assistant_deliveries), for platform admins.
// Read only: it never changes the receptionist or calls anything outside Zella Voice.
import { useEffect, useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Drawer, Facts, Pill, friendlyError } from "./admin/adminOps";
import { timeAgo } from "./ownerFormat";
import { outcomePill, problemText, versionText } from "./connectionState.js";

export default function AgentDeliveries({ agent, onClose }) {
  const [state, setState] = useState({ loading: true, data: null, error: "" });
  useEffect(() => {
    let live = true;
    callOwnerFunction("agent_deliveries", { businessId: agent.businessId, limit: 25 })
      .then((data) => live && setState({ loading: false, data, error: "" }))
      .catch((e) => live && setState({ loading: false, data: null, error: friendlyError(e) }));
    return () => { live = false; };
  }, [agent.businessId]);
  const d = agent.delivery;
  const list = state.data?.deliveries ?? [];
  return (
    <Drawer title={`Calls served: ${agent.businessName}`} icon="call_log" onClose={onClose}>
      <Facts rows={[
        ["Last 7 days", d ? `${d.served7d} served · ${d.notReady7d} not ready · ${d.unknownNumber7d} unknown number · ${d.forwardedUsage7d} over its limit` : "Not available"],
        ["Version", versionText(d)],
        d?.syncError && ["Last check said", d.syncError],
        d?.lastProblems?.length && ["Last problem", `${d.lastProblems.map(problemText).join("; ")} (${timeAgo(d.lastProblemAt)})`],
      ]} />
      <h4 className="op-gap-top">Recent calls</h4>
      {state.loading ? <p className="op-muted">Loading…</p>
        : state.error ? <div className="owner-form-error" role="alert">{state.error}</div>
        : state.data?.available === false ? <div className="op-empty">Not available yet: the delivery records aren't switched on.</div>
        : !list.length ? <div className="op-empty">No calls have reached Zella Voice for this business yet. Calls are recorded here once its numbers send them to Zella Voice.</div>
        : (
          <ul className="op-list">
            {list.map((x) => (
              <li key={x.id}>
                <div>
                  <Pill tone={outcomePill(x.outcome)[0]}>{outcomePill(x.outcome)[1]}</Pill>
                  <strong>{timeAgo(x.at)}</strong>
                  <span>
                    {x.version != null ? `Version ${x.version}` : "No version"}{x.call ? ` · call ${x.call}` : ""}
                    {Array.isArray(x.problems) && x.problems.length > 0 && ` · ${x.problems.map(problemText).join("; ")}`}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        )}
      <p className="op-muted op-gap-top">Shows the last {state.data?.limit ?? 25} calls. Problems are platform settings the Zella Voice team fixes.</p>
    </Drawer>
  );
}
