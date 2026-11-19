import "./goLive.css";
import { useEffect, useRef, useState } from "react";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { Icon } from "../BusinessUI";
import { ErrorNote, Panel, Pill, rpc, useLoad } from "./adminOps";
import { STATE_PILL, goLiveChecklist } from "./goLive";

// The one go live checklist (UI-23) on Platform operations: secrets, settings and live switches, one list per group.
// Scheduled jobs are counted here but listed only in their own table below (one source per item). Automations,
// Messaging and Settings link here (/operations?view=go-live). Read only: nothing is switched on here.
export const GO_LIVE_PATH = "/operations?view=go-live";

// a table that isn't applied yet reads as "not checked", not as an error
const optional = (p) => p.catch(() => null);
const isReady = (r) => r.state === "ready";
const count = (rows) => ({ ready: rows.filter(isReady).length, total: rows.length });

// The words under an item: what it is, and any note
const detailOf = (r) => [r.detail, r.note].filter(Boolean).join(". ");

// "Secret RESEND_API_KEY" -> ["Secret", "RESEND_API_KEY"]: the kind in words, the name as code
function techOf(hint = "") {
  const m = /^(.*?)\s*([A-Za-z0-9_]+(?:\s+on\s+[a-z_]+)?)$/.exec(hint);
  return m ? [m[1] || "Name", m[2]] : ["Name", hint];
}

function Meter({ ready, total }) {
  const pct = total ? Math.round((ready / total) * 100) : 0;
  return <span className={`gl-meter${ready === total && total ? " done" : ""}`} aria-hidden="true"><span style={{ width: `${pct}%` }} /></span>;
}

function Group({ g }) {
  const [showReady, setShowReady] = useState(false);
  const c = count(g.rows);
  const open = g.rows.filter((r) => !isReady(r));
  const visible = showReady ? g.rows : open;
  return (
    <details className="gl-group" open={open.length > 0} aria-label={g.title}>
      <summary>
        <span className="gl-group-title"><strong>{g.title}</strong>, {c.ready} of {c.total} ready</span>
        <Meter {...c} />
      </summary>
      <div className="gl-group-body">
        {g.note && <p className="gl-note">{g.note}</p>}
        {visible.length > 0 ? (
          <table className="gl-table">
            <thead><tr><th scope="col">Item</th><th scope="col" className="gl-col-status">Status</th></tr></thead>
            <tbody>
              {g.rows.map((r) => {
                const [tone, label] = STATE_PILL[r.state];
                return (
                  <tr key={r.key} data-go-live={r.key} data-go-live-state={r.state} hidden={!showReady && isReady(r)}>
                    <td>
                      <span className="gl-item">{r.label}</span>
                      <span className="gl-item-detail">{detailOf(r)}</span>
                    </td>
                    <td className="gl-col-status"><Pill tone={tone}>{label}</Pill></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : <p className="gl-all-ready">Everything in this group is ready.</p>}
        <div className="gl-group-foot">
          {c.ready > 0 && open.length > 0 && (
            <button type="button" className="gl-text-button" aria-expanded={showReady} onClick={() => setShowReady((v) => !v)}>
              {showReady ? `Hide ready (${c.ready})` : `Show ready (${c.ready})`}
            </button>
          )}
          <details className="gl-tech">
            <summary>Technical details</summary>
            <dl>
              {g.rows.map((r) => { const [kind, name] = techOf(r.hint); return <div key={r.key}><dt>{r.label}</dt><dd>{kind} <code>{name}</code></dd></div>; })}
            </dl>
          </details>
        </div>
      </div>
    </details>
  );
}

export default function GoLiveChecklist({ health, pageReady = true, refresh = 0 }) {
  const server = useLoad(() => callOwnerFunction("go_live_checklist"), [refresh]);
  const triggers = useLoad(() => optional(rpc("zella_admin_email_triggers")), [refresh]);
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
  const shown = list.groups.filter((g) => g.key !== "jobs");
  const jobs = count(list.groups.find((g) => g.key === "jobs")?.rows ?? []);
  const all = count(shown.flatMap((g) => g.rows));
  const tiles = [...shown.map((g) => [g.key, g.title, count(g.rows)]), ["jobs", "Scheduled jobs", jobs]];
  return (
    <div ref={ref} id="go-live" data-go-live-ready={list.ready} data-go-live-total={list.total}>
      <Panel title="Go live checklist"
        description={`${all.ready} of ${all.total} ready${list.unknown ? `, ${list.unknown} not checked` : ""}. Each channel has its own switch: texts, emails and calls reach customers only once that channel is switched on and its own items are ready. This list switches nothing on.`}>
        <ErrorNote error={server.error} onRetry={server.reload} />
        <div className="gl-tiles">
          {tiles.map(([key, title, c]) => {
            const body = <><span className="gl-tile-label">{title}</span><span className="gl-tile-value">{c.ready} <small>of {c.total} {key === "jobs" ? "on" : "ready"}</small></span><Meter {...c} /></>;
            return key === "jobs"
              ? <a key={key} className="gl-tile gl-tile-link" href="#scheduled-jobs" aria-label={`Scheduled jobs, ${c.ready} of ${c.total} on. Open the table`}>{body}<Icon name="chevron_right" /></a>
              : <div key={key} className="gl-tile">{body}</div>;
          })}
        </div>
        <div className="gl-groups">{shown.map((g) => <Group key={g.key} g={g} />)}</div>
      </Panel>
    </div>
  );
}
