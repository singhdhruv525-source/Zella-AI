import { useEffect, useRef } from "react";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { ErrorNote, Panel, Pill, rpc, useLoad } from "./adminOps";
import { STATE_PILL, goLiveChecklist } from "./goLive";

// The one go live checklist (UI-23) on Platform operations: secrets, settings, scheduled jobs and live switches.
// Automations, Messaging and Settings link here (/operations?view=go-live). Read only: nothing is switched on here.
export const GO_LIVE_PATH = "/operations?view=go-live";

// a table that isn't applied yet reads as "not checked", not as an error
const optional = (p) => p.catch(() => null);

export default function GoLiveChecklist({ health, pageReady = true }) {
  const server = useLoad(() => callOwnerFunction("go_live_checklist"), []);
  const triggers = useLoad(() => optional(rpc("zella_admin_email_triggers")), []);
  const ref = useRef(null);
  const scrolled = useRef(false);
  const loaded = pageReady && !server.loading && !health.loading;
  // opened from a link (/operations?view=go-live): scroll here once the lists above have loaded and taken their space
  useEffect(() => {
    if (!loaded || scrolled.current || new URLSearchParams(window.location.search).get("view") !== "go-live") return;
    scrolled.current = true;
    ref.current?.scrollIntoView({ block: "start" });
  }, [loaded]);
  const list = goLiveChecklist({ server: server.data, health: health.data, triggers: triggers.data });
  const reload = () => { server.reload(); triggers.reload(); health.reload(); };
  return (
    <div ref={ref} id="go-live" data-go-live-ready={list.ready} data-go-live-total={list.total}>
      <Panel title="Go live checklist"
        description={`${list.ready} of ${list.total} ready${list.unknown ? `, ${list.unknown} not checked` : ""}. ${list.approvals} ${list.approvals === 1 ? "step needs" : "steps need"} the owner's approval to switch on. Until every step is ready, nothing reaches customers.`}
        action={<button type="button" className="owner-secondary-button" onClick={reload}>Refresh</button>}>
        <ErrorNote error={server.error} onRetry={server.reload} />
        {list.groups.map((g) => (
          <section key={g.key} className="op-card" aria-label={g.title}>
            <h3 className="ao-h3">{g.title}</h3>
            {g.note && <p className="op-muted">{g.note}</p>}
            <ul className="op-list">
              {g.rows.map((r) => {
                const [tone, label] = STATE_PILL[r.state];
                return (
                  <li key={r.key} data-go-live={r.key} data-go-live-state={r.state}>
                    <div>
                      <strong title={r.hint}>{r.label}</strong>
                      <span title={r.hint}>{[r.detail, r.note, r.approval && r.state !== "ready" ? "Needs the owner's approval" : null].filter(Boolean).join(". ")}</span>
                    </div>
                    <Pill tone={tone}>{label}</Pill>
                  </li>
                );
              })}
            </ul>
          </section>
        ))}
      </Panel>
    </div>
  );
}
