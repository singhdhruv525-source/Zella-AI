import { useState } from "react";
import { DataTable, ErrorNote, Panel, Pill, ReasonDialog, rpc, when, words } from "./adminOps";
import { allJobs, jobLabel, jobState } from "./jobState";

// The scheduled jobs panel: each job's real state beside its intended state (PLT-07). Recording an intent is a note
// for the team, kept in the audit log; it never switches a job on or off (that is the owner's live switch at go live).
export default function ScheduledJobs({ health }) {
  const [editing, setEditing] = useState(null);
  const s = health.data;
  const rows = allJobs(s);
  return (
    <Panel title="Scheduled jobs" description="Timed jobs inside the database, whether each is on, and whether that is on purpose."
      action={<button type="button" className="owner-secondary-button" onClick={health.reload}>Refresh</button>}>
      <ErrorNote error={health.error} onRetry={health.reload} />
      {s?.intent_mismatches > 0 && (
        <p className="op-muted" role="status" data-intent-mismatches={s.intent_mismatches}>
          {s.intent_mismatches} {s.intent_mismatches === 1 ? "job is" : "jobs are"} not in the state recorded for {s.intent_mismatches === 1 ? "it" : "them"}.
        </p>
      )}
      <DataTable error={health.error} loading={health.loading} rows={rows} rowKey={(j) => j.name} empty="No Zella Voice jobs found."
        columns={[
          ["Job", (j) => <span data-job={j.name}><strong>{jobLabel(j.name)}</strong><br /><span className="op-muted">{j.drives ?? <code>{j.name}</code>}</span></span>],
          ["State", (j) => { const st = jobState(s, j.name); return <Pill tone={st.tone}>{st.label}</Pill>; }],
          ["Intended", (j) => {
            const st = jobState(s, j.name);
            return <span data-intent={j.intended ?? "none"}>{st.intent ?? <span className="op-muted">Not recorded</span>}{st.mismatch && <> <Pill tone="warning">Not as intended</Pill></>}</span>;
          }],
          ["Last run", (j) => (j.last_run ? <span><Pill tone={j.last_run.status === "succeeded" ? "success" : "danger"}>{words(j.last_run.status)}</Pill> {when(j.last_run.at)}</span> : "Never")],
          ["Failures (24 h)", (j) => (j.failures_24h ? <Pill tone="danger">{j.failures_24h}</Pill> : j.exists ? 0 : "")],
          ["", (j) => <button type="button" className="op-link" onClick={() => setEditing(j)} aria-label={`Record intent for ${jobLabel(j.name)}`}>Record intent</button>],
        ]} />
      <p className="op-muted">Jobs are switched on at go live by the owner, not from this page, so a click here can't start sending to customers.</p>
      {editing && <IntentDialog job={editing} onClose={() => setEditing(null)} onSaved={health.reload} />}
    </Panel>
  );
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
