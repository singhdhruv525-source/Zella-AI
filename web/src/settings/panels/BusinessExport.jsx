import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, Field, LoadState, Pill, Table, useAsync, when } from "../SettingsKit";
import { exportState } from "../../businessLifecycle";

// Settings > Data lifecycle > Whole business export (SET-DL-EXPORT). An admin requests an export of one business, a
// Zella Voice owner other than the requester approves it, the worker writes it to a private bucket, and the requester
// or an owner downloads it for 7 days through links that end with it. Every step is audited.

const call = (action, payload) => callOwnerFunction(action, payload);

export default function BusinessExport({ me }) {
  const [q, setQ] = useState("");
  const state = useAsync(() => call("export_status"), []);
  // first 25 matches by name, kept with the words they were found for, so an older answer is never offered for new words
  const found = useAsync(async () => ({ q, result: await call("tenants_search", { q }) }), [q]);
  const [business, setBusiness] = useState("");
  const [notice, setNotice] = useState({ text: "", error: "" });
  const [asking, setAsking] = useState(false);
  const [deciding, setDeciding] = useState(null);   // { job, approve }
  const [links, setLinks] = useState(null);
  const manage = Boolean(me?.permissions?.includes("businesses.manage"));
  const done = (text) => { setNotice({ text, error: "" }); state.reload(); };
  // the worker changes jobs in the background: while one is waiting or running, look again every 30 seconds
  const open = (state.data?.jobs ?? []).some((j) => ["requested", "approved", "running"].includes(j.status));
  useEffect(() => {
    if (!open) return undefined;
    const t = setInterval(() => { if (document.visibilityState === "visible") state.reload(); }, 30000);
    return () => clearInterval(t);
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps
  // the business search: loading and failure are shown, and a failed or stale list can't be picked from
  const current = found.data?.q === q ? found.data.result : null;
  const searchProblem = found.error ? `The business search didn't answer: ${found.error}`
    : !found.loading && current && !Array.isArray(current.rows) ? "The business search isn't available right now." : "";
  const searchReady = !found.loading && !found.error && Array.isArray(current?.rows);
  const oops = (err) => setNotice({ text: "", error: err.message });
  async function download(j) {
    try { const r = await call("export_download", { id: j.id }); setLinks({ name: j.business_name, ...r }); }
    catch (err) { oops(err); }
  }
  return (
    <Card title="Whole business export" sub="Everything a business has, as one file per table plus its stored files. An admin asks for it, a Zella Voice owner other than the person who asked approves it, and it can be downloaded for 7 days. Secret keys, recording links and, in sensitive industries, call transcripts are never included.">
      <Banner tone="success">{notice.text}</Banner>
      <Banner tone="error">{notice.error}</Banner>
      <LoadState state={state}>{(s) => !s.available ? <p className="zs-muted">Business exports aren't installed on this database yet.</p> : (
        <>
          {manage && (<>
            <div className="zs-grid">
              <Field label="Find a business"><input type="search" aria-label="Find a business" placeholder="Business name" value={q} onChange={(e) => { setQ(e.target.value); setBusiness(""); }} /></Field>
              <Field label="Business to export"><select aria-label="Business to export" value={business} disabled={!searchReady} onChange={(e) => setBusiness(e.target.value)}>
                <option value="">{found.loading || (!searchReady && !searchProblem) ? "Searching…" : searchProblem ? "Search unavailable" : "Choose a business"}</option>
                {searchReady && current.rows.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
              </select></Field>
            </div>
            {searchProblem && <Banner tone="error">{searchProblem} <button type="button" className="zs-btn sm" onClick={found.reload}>Try again</button></Banner>}
            <div className="zs-actions">
              <button type="button" className="zs-btn" disabled={!business || !searchReady} onClick={() => setAsking(true)}>Request export</button>
              <button type="button" className="zs-btn ghost" disabled={state.loading} onClick={state.reload}>{state.loading ? "Checking…" : "Refresh"}</button>
            </div>
          </>)}
          <Table rows={s.jobs} empty="No exports yet." columns={[
            ["Business", (j) => j.business_name], ["Asked", (j) => when(j.created_at)],
            ["State", (j) => { const [label, tone] = exportState(j); return <Pill tone={tone}>{label}</Pill>; }],
            ["Progress", (j) => (j.status === "running" || j.status === "approved") && j.progress.tablesTotal ? `${j.progress.tables} of ${j.progress.tablesTotal} tables` : j.status === "ready" ? `Until ${when(j.expires_at)}` : (j.last_error ?? "")],
            ["", (j) => (
              <span className="zs-actions">
                {s.canDecide && !j.mine && j.status === "requested" && <>
                  <button type="button" className="zs-btn sm" onClick={() => setDeciding({ job: j, approve: true })}>Approve</button>
                  <button type="button" className="zs-btn sm danger-outline" onClick={() => setDeciding({ job: j, approve: false })}>Reject</button>
                </>}
                {j.status === "ready" && (j.mine || s.canDecide) && <button type="button" className="zs-btn sm" onClick={() => download(j)}>Download</button>}
              </span>
            )],
          ]} />
        </>
      )}</LoadState>
      {asking && createPortal(
        <Confirm title="Request a whole business export?" reason confirmLabel="Request" onClose={() => setAsking(false)}
          onConfirm={async (reason) => { try { await call("export_request", { businessId: business, reason }); done("Requested. A Zella Voice owner other than you approves it next."); } catch (err) { oops(err); } }}>
          <p>A Zella Voice owner other than you approves it. Then it is prepared in the background and kept for 7 days.</p>
        </Confirm>, document.body)}
      {deciding && createPortal(
        <Confirm title={`${deciding.approve ? "Approve" : "Reject"} the export of ${deciding.job.business_name}?`} reason={!deciding.approve} danger={!deciding.approve}
          confirmLabel={deciding.approve ? "Approve" : "Reject"} onClose={() => setDeciding(null)}
          onConfirm={async (reason) => { try { await call("export_decide", { id: deciding.job.id, approve: deciding.approve, reason }); done(deciding.approve ? "Approved. It is prepared in the background." : "Rejected."); } catch (err) { oops(err); } }}>
          <p>Asked for this reason: {deciding.job.request_reason}</p>
        </Confirm>, document.body)}
      {links && createPortal(
        <Confirm title={`Export of ${links.name}`} confirmLabel="Done" onClose={() => setLinks(null)} onConfirm={() => true}>
          <p>These links work until {when(links.expiresAt)}. Downloading is recorded in the audit log.</p>
          <ul className="zs-link-list">{links.links.map((l) => <li key={l.path}><a href={l.url} target="_blank" rel="noopener noreferrer">{l.path.split("/").slice(1).join("/")}</a></li>)}</ul>
        </Confirm>, document.body)}
    </Card>
  );
}
