// AI-TESTING: each business's test questions checked against its knowledge, with stored runs (sql/zella_ai_eval_admin.sql).
// It checks knowledge retrieval only, not live calls: no provider is called, nothing is sent and nothing costs money.
// A failing run is a warning; it never stops a business going live.
import { useEffect, useState } from "react";
import { Pager, PAGE, Pill, can, friendlyError, rpc } from "./admin/adminOps";
import { timeAgo } from "./ownerFormat";
import { evalPill, evalSummary } from "./aiTestingWords.js";
import "./AiTesting.css";

// refresh: a number the page's Refresh button raises, so it reloads this view too.
export default function AiTesting({ me, onOpenBusiness, refresh = 0 }) {
  const [offset, setOffset] = useState(0);
  const [reloads, setReloads] = useState(0);
  const [state, setState] = useState({ key: null, data: null, error: "" });
  const [running, setRunning] = useState(null);
  const [runError, setRunError] = useState("");
  const [open, setOpen] = useState(null);
  const key = `${offset}|${reloads}|${refresh}`;
  useEffect(() => {
    let live = true;
    rpc("zella_admin_eval_overview", { p_limit: PAGE, p_offset: offset })
      .then((data) => live && setState({ key, data, error: "" }))
      .catch((e) => live && setState({ key, data: null, error: friendlyError(e) }));
    return () => { live = false; };
  }, [offset, key]);
  const loading = state.key !== key;
  const canRun = can(me, "businesses.manage");

  async function runTests(businessId) {
    setRunning(businessId); setRunError("");
    try { await rpc("zella_admin_eval_run", { p_business_id: businessId }); setOpen(businessId); setReloads((n) => n + 1); }
    catch (e) { setRunError(friendlyError(e)); }
    finally { setRunning(null); }
  }

  // a valid answer has a total and a list; anything else is "couldn't load", never "no business"
  const valid = !loading && state.data && Number.isFinite(Number(state.data.total)) && Array.isArray(state.data.businesses);
  // rows of the page asked for only: while the next page loads the previous one is not shown under its range
  const rows = valid ? state.data.businesses : [];
  const emptyText = loading ? "Loading..."
    : !valid ? "Couldn't load AI testing."
      : Number(state.data.total) === 0 ? "No business has test questions yet. A business adds them in its settings, under AI receptionist."
        : "Nothing on this page. Go back a page to see the businesses.";
  return (
    <section className="owner-panel">
      <div className="owner-panel-heading">
        <div>
          <h2>AI testing</h2>
          <p>Each business's test questions, checked against its knowledge. This checks what the receptionist can look up, not live calls: nothing is sent and nothing is charged.
            A business passes when it has at least {state.data?.min_cases ?? 3} questions and every one passes. A failing run is a warning only; it never stops a business going live.</p>
        </div>
        {valid && <Pill tone="neutral">{`${state.data.passing} of ${state.data.total} passing`}</Pill>}
      </div>
      {(state.error || runError) && (
        <div className="owner-form-error" role="alert">
          {state.error || runError}{" "}
          {state.error && <button type="button" className="owner-link-button" onClick={() => setReloads((n) => n + 1)}>Try again</button>}
        </div>
      )}
      <div className="owner-table-wrap" tabIndex={0}>
        <table className="owner-table ait-table">
          <thead><tr><th>Business</th><th>Test questions</th><th>Last run</th><th>Result</th><th /></tr></thead>
          <tbody>
            {rows.map((b) => (
              <tr key={b.business_id} className={open === b.business_id && b.last_run?.failed?.length > 0 ? "ait-selected" : undefined}>
                <td><button type="button" className="op-name" onClick={() => onOpenBusiness(b.business_id)}>{b.name}</button></td>
                <td>{b.cases}</td>
                <td>{b.last_run ? timeAgo(b.last_run.run_at) : <span className="op-muted">Not run yet</span>}</td>
                <td>
                  <div className="owner-business-cell">
                    <span><Pill tone={evalPill(b.last_run, b.cases)[0]}>{evalPill(b.last_run, b.cases)[1]}</Pill></span>
                    <span>{evalSummary(b.last_run)}</span>
                    {open === b.business_id && b.last_run?.failed?.length > 0 && (
                      <ul className="op-bullets">
                        {b.last_run.failed.map((f, i) => <li key={i}>{f.question}{f.expected ? ` (expected ${f.expected})` : ""}</li>)}
                      </ul>
                    )}
                  </div>
                </td>
                <td>
                  <div className="op-heading-actions">
                    {b.last_run?.failed?.length > 0 && (
                      <button type="button" className="owner-secondary-button op-small" onClick={() => setOpen(open === b.business_id ? null : b.business_id)}>
                        {open === b.business_id ? "Hide failed" : "Show failed"}
                      </button>
                    )}
                    {canRun && (
                      <button type="button" className="owner-secondary-button op-small" disabled={running !== null} onClick={() => runTests(b.business_id)}>
                        {running === b.business_id ? "Running…" : "Run tests"}
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {!rows.length && (
              <tr><td colSpan={5}><div className="op-empty">{emptyText}</div></td></tr>
            )}
          </tbody>
        </table>
      </div>
      {valid && state.data.total > 0 && (
        <div className="ait-foot">
          <Pager total={state.data.total} offset={offset} onChange={setOffset} />
        </div>
      )}
    </section>
  );
}
