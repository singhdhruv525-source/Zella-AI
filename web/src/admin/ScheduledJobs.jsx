import { useState } from "react";
import { DataTable, ErrorNote, Panel, Pill, ReasonDialog, rpc, when, words } from "./adminOps";
import { allJobs, jobLabel, jobState } from "./jobState";
import { Icon } from "../BusinessUI";
import "./goLive.css";

// The scheduled jobs panel: each job's real state beside its intended state (PLT-07). Recording an intent is a note
// for the team, kept in the audit log; it never switches a job on or off (that is the owner's live switch at go live).
// showRefresh: false where the page header's Refresh already reloads the jobs (Platform operations).
export default function ScheduledJobs({ health, showRefresh = true }) {
  const [editing, setEditing] = useState(null);
  const s = health.data;
  const rows = allJobs(s);
  const mismatches = s?.intent_mismatches ?? 0;
  return (
    <div id="scheduled-jobs" className="sj-wrap">
      <Panel title="Scheduled jobs" description="Timed jobs inside the database, and whether each one is in the state it should be."
        action={showRefresh ? <button type="button" className="owner-secondary-button sj-btn-sm" onClick={health.reload}>Refresh</button> : null}>
        <ErrorNote error={health.error} onRetry={health.reload} />
        {mismatches > 0 && (
          <div className="sj-banner-warning banner-warning" role="status" data-intent-mismatches={mismatches}>
            <Icon name="warning" />
            <span><strong>{mismatches} {mismatches === 1 ? "job is" : "jobs are"} not as intended.</strong> {mismatches === 1 ? "Its state differs" : "Their state differs"} from the one recorded for {mismatches === 1 ? "it" : "them"}.</span>
          </div>
        )}
        <DataTable error={health.error} loading={health.loading} rows={rows} rowKey={(j) => j.name} empty="No Zella Voice jobs found."
          columns={[
            ["Job", (j) => <span data-job={j.name}><span className="sj-job">{jobLabel(j.name)}</span><span className="sj-sub" title={j.drives ?? j.name}>{j.drives ?? j.name}</span></span>],
            ["State", (j) => { const st = jobState(s, j.name); return <Pill tone={st.on ? "success" : "neutral"}>{st.label}</Pill>; }],
            ["Intended", (j) => {
              const st = jobState(s, j.name);
              return (
                <span className="sj-intent" data-intent={j.intended ?? "none"}>
                  {st.intent ? plainIntent(st.intent) : <span className="sj-empty">Not recorded</span>}
                  {st.mismatch && <><br /><Pill tone="warning">Not as intended</Pill></>}
                </span>
              );
            }],
            ["Last run", (j) => (j.last_run
              ? <span><Pill tone={j.last_run.status === "succeeded" ? "success" : "danger"}>{words(j.last_run.status)}</Pill><span className="sj-sub">{when(j.last_run.at)}</span></span>
              : <span className="sj-empty">Never</span>)],
            [<span key="f" className="sj-num">Failures, 24 hours</span>, (j) => (j.failures_24h ? <Pill tone="danger">{j.failures_24h}</Pill> : j.exists ? 0 : <span className="sj-empty">None</span>), "sj-num"],
            [<span key="a" className="sj-sr">Actions</span>, (j) => <button type="button" className="owner-secondary-button sj-btn-sm" onClick={() => setEditing(j)} aria-label={`Record intent for ${jobLabel(j.name)}`}>Record intent</button>, "sj-actions"],
          ]} />
        <p className="sj-foot">You switch jobs on when you go live. Nothing on this page starts sending to customers.</p>
        {editing && <IntentDialog job={editing} onClose={() => setEditing(null)} onSaved={health.reload} />}
      </Panel>
    </div>
  );
}

// A recorded reason in plain words: the default go live note reads "Off until you go live".
function plainIntent(text) {
  return /^deliberately off until go live\.?$/i.test(String(text).trim()) ? "Off until you go live" : text;
}

function IntentDialog({ job, onClose, onSaved }) {
  const [intended, setIntended] = useState(job.intended === "on" ? "on" : "off");
  return (
    <ReasonDialog title={`Intended state: ${jobLabel(job.name)}`} icon="schedule" confirmLabel="Record"
      onClose={onClose}
      onConfirm={async (reason) => { await rpc("zella_admin_job_intent_save", { p_job: job.name, p_intended: intended, p_reason: reason }); onSaved(); }}>
      <p>This records what the job should be, with your reason, in the audit log. It doesn't switch the job on or off.</p>
      <fieldset className="owner-field">
        <legend>Should be</legend>
        <label><input type="radio" name="intent" value="off" checked={intended === "off"} onChange={() => setIntended("off")} /> Off</label>{" "}
        <label><input type="radio" name="intent" value="on" checked={intended === "on"} onChange={() => setIntended("on")} /> On</label>
      </fieldset>
    </ReasonDialog>
  );
}
