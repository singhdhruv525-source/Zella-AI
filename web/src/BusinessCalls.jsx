import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { Empty, Notice, PAGE_SIZE, PageHead, Pager, Segment, clock, explain, loadPeople, orThrow, plural, useLoad } from "./BusinessShared";
import { EscalationControls, Transcript, isOpenEscalation } from "./BusinessProfile";
import { Assignee, useRoster } from "./BusinessLeads";
import { CB_CLOSED, CB_REASON, when } from "./BusinessWork";

/* Every call, what came of it, and who is looking after it. */

export const OUTCOMES = {
  resolved: "Resolved", booked: "Booked", callback_needed: "Callback needed", left_message: "Left a message",
  wrong_number: "Wrong number", spam: "Spam", other: "Other",
};
const OUTCOME_TONE = { resolved: "success", booked: "success", callback_needed: "warning", left_message: "", wrong_number: "", spam: "", other: "" };

// Recordings are shown unless the call was marked as not consented.
export const recordingAllowed = (call) => Boolean(call.recording_url) && call.metadata?.recording_consent !== false;

function CallDetail({ call, person, followUps, roster, workspace, onClose, onChanged, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [outcome, setOutcome] = useState(call.outcome ?? "");
  const [note, setNote] = useState(call.outcome_note ?? "");
  const [cb, setCb] = useState(null);
  const [lead, setLead] = useState(null);
  const missed = call.status === "missed";
  const number = person?.phone ?? call.from_number;

  async function run(key, work, message, after) {
    setBusy(key);
    setError("");
    const { data, error: failure } = await work();
    setBusy("");
    if (failure) { setError(explain(failure)); return null; }
    if (message) onNotice(message);
    onChanged();
    after?.(data);
    return data ?? true;
  }
  const saveOutcome = (event) => {
    event.preventDefault();
    if (!outcome) return setError("Choose what happened.");
    run("outcome", () => supabase.rpc("zella_call_update", { p_call_id: call.id, p_outcome: outcome, p_note: note.trim() || null }), "Outcome saved.");
  };
  const assign = (value) => run("assign", () => supabase.rpc("zella_call_update", value ? { p_call_id: call.id, p_assign_to: value } : { p_call_id: call.id, p_unassign: true }), "Assignment saved.");
  const schedule = (event) => {
    event.preventDefault();
    run("cb", () => supabase.rpc("zella_call_schedule_callback", { p_call_id: call.id, p_preferred_at: zonedDateTime(cb.date, cb.time, tz).toISOString(), p_summary: null, p_priority: "normal" }), "Callback scheduled.", () => setCb(null));
  };
  const createLead = (event) => {
    event.preventDefault();
    run("lead", () => supabase.rpc("zella_call_create_lead", { p_call_id: call.id, p_first_name: lead.first.trim() || null, p_last_name: lead.last.trim() || null }), null, (res) => {
      setLead(null);
      onNotice(res?.result === "needs_review" ? "This number may already be in your list. A task was added to check." : res?.result === "matched" ? "Linked to the person already on file." : "Lead created.");
    });
  };
  const followedUp = () => run("followed", () => supabase.from("calls").update({ metadata: { ...(call.metadata ?? {}), followed_up_at: new Date().toISOString() }, updated_at: new Date().toISOString() }).eq("id", call.id), "Missed call marked as followed up.");

  return (
    <Modal wide title={personName(person) ?? call.from_number ?? "Unknown caller"} onClose={onClose} busy={Boolean(busy)}
      description={`${call.direction === "outbound" ? "Outgoing" : "Incoming"} call · ${formatDay(call.created_at, tz)} · ${formatTime(call.created_at, tz)}`}>
      <div className="ba-modal-body">
        {error && <p className="ba-error" role="alert">{error}</p>}
        {isOpenEscalation(call) && <div className="ba-banner alert" role="alert"><span><strong>Needs a human.</strong> {call.escalation_reason || "The AI receptionist handed this call over."}</span></div>}

        <div className="ba-kn-head">
          <Pill tone={missed ? "danger" : "success"}>{missed ? "Missed" : "Answered"}</Pill>
          <Pill>{call.ai_handled ? "AI receptionist" : "Team"}</Pill>
          <Pill>{clock(call.duration_seconds)}</Pill>
          {call.outcome && <Pill tone={OUTCOME_TONE[call.outcome]}>{OUTCOMES[call.outcome]}</Pill>}
          {number && <a className="ba-btn sm" href={`tel:${number}`}><Icon name="call" size="sm" />Call back</a>}
          {person ? <button type="button" className="ba-btn sm" onClick={() => onOpenPerson(person.id)}><Icon name="person" size="sm" />Open profile</button>
            : number && <button type="button" className="ba-btn sm" onClick={() => setLead({ first: "", last: "" })}><Icon name="person_add" size="sm" />Create lead</button>}
          <button type="button" className="ba-btn sm" onClick={() => setCb({ date: todayInput(tz), time: "10:00" })}>Schedule callback</button>
          {missed && !call.metadata?.followed_up_at && <button type="button" className="ba-btn sm" disabled={Boolean(busy)} onClick={followedUp}>Mark followed up</button>}
        </div>

        {lead && (
          <form className="ba-form-grid ba-finish" onSubmit={createLead}>
            <Field label="First name"><input value={lead.first} onChange={(e) => setLead({ ...lead, first: e.target.value })} autoFocus /></Field>
            <Field label="Last name"><input value={lead.last} onChange={(e) => setLead({ ...lead, last: e.target.value })} /></Field>
            <p className="ba-muted full">Uses {call.from_number}. If they're already in your list, the call links to them instead.</p>
            <div className="full ba-form-actions"><button type="submit" className="ba-btn primary sm" disabled={Boolean(busy)}>Create lead</button><button type="button" className="ba-btn sm" onClick={() => setLead(null)}>Cancel</button></div>
          </form>
        )}
        {cb && (
          <form className="ba-form-grid ba-finish" onSubmit={schedule}>
            <Field label="Day"><input type="date" min={todayInput(tz)} value={cb.date} onChange={(e) => setCb({ ...cb, date: e.target.value })} required /></Field>
            <Field label="Time"><input type="time" value={cb.time} onChange={(e) => setCb({ ...cb, time: e.target.value })} required /></Field>
            <div className="full ba-form-actions"><button type="submit" className="ba-btn primary sm" disabled={Boolean(busy)}>Schedule</button><button type="button" className="ba-btn sm" onClick={() => setCb(null)}>Cancel</button></div>
          </form>
        )}

        {call.summary && <section><h3 className="ba-sub">Summary</h3><p className="ba-item-text">{call.summary}</p></section>}

        <h3 className="ba-sub">Outcome and owner</h3>
        <form className="ba-form-grid" onSubmit={saveOutcome}>
          <Field label="What happened?">
            <select value={outcome} onChange={(e) => setOutcome(e.target.value)}>
              <option value="">Not set</option>
              {Object.entries(OUTCOMES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
            </select>
          </Field>
          <Field label="Assigned to">
            <select value={call.assigned_to ?? ""} disabled={Boolean(busy)} onChange={(e) => assign(e.target.value)}>
              <option value="">Unassigned</option>
              {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
            </select>
          </Field>
          <Field label="Note" full><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional" /></Field>
          <div className="full ba-form-actions"><button type="submit" className="ba-btn primary sm" disabled={Boolean(busy)}>Save outcome</button></div>
        </form>

        <h3 className="ba-sub">Follow-up</h3>
        {!followUps.length ? <p className="ba-muted">No follow-up linked to this call.</p> : (
          <ul className="ba-threads">
            {followUps.map((f) => (
              <li key={f.id}>
                <span className="ba-thread-icon"><Icon name="phone_callback" size="sm" /></span>
                <div><strong>{f.kind === "callback" ? (CB_REASON[f.reason] ?? "Callback") : "Follow-up call"}</strong><small>{f.done ? "Done" : `Due ${when(f.due_at, tz)}`}</small></div>
              </li>
            ))}
          </ul>
        )}

        {recordingAllowed(call) && (
          <section>
            <h3 className="ba-sub">Recording</h3>
            <audio className="ba-audio" controls preload="none" src={call.recording_url}><a href={call.recording_url}>Listen to the recording</a></audio>
            <p className="ba-muted">Only share recordings where callers were told the call is recorded.</p>
          </section>
        )}
        {call.recording_url && !recordingAllowed(call) && <p className="ba-muted">A recording exists but is hidden because the caller didn't agree to be recorded.</p>}
        <section><h3 className="ba-sub">Transcript</h3><Transcript transcript={call.transcript} /></section>
        <section><h3 className="ba-sub">Hand-off</h3><EscalationControls call={call} onChanged={onChanged} onNotice={onNotice} /></section>
      </div>
    </Modal>
  );
}

const FILTERS = [["all", "All"], ["answered", "Answered"], ["missed", "Missed"], ["ai", "AI handled"], ["human", "Needs a human"], ["recorded", "Recordings"]];

export function CallsPage({ workspace, refreshKey, onNotice, onOpenPerson, transcriptsOnly }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("all");
  const [page, setPage] = useState(0);
  const [openId, setOpenId] = useState(null);
  const roster = useRoster(workspace);
  const { data, error, loading, reload } = useLoad(async () => {
    const calls = orThrow(await supabase.from("calls").select("*").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(300));
    const ids = calls.map((c) => c.id);
    // Follow-ups linked to these calls (optional: older workspaces just show none).
    const [cbs, fus] = ids.length ? await Promise.all([
      supabase.from("callbacks").select("id, call_id, status, reason, due_at").in("call_id", ids),
      supabase.from("followup_tasks").select("id, call_id, status, due_at").in("call_id", ids),
    ]) : [{ data: [] }, { data: [] }];
    const links = {};
    (cbs.data ?? []).forEach((c) => { (links[c.call_id] ||= []).push({ id: c.id, kind: "callback", reason: c.reason, due_at: c.due_at, done: CB_CLOSED.includes(c.status) }); });
    (fus.data ?? []).forEach((f) => { (links[f.call_id] ||= []).push({ id: f.id, kind: "followup", due_at: f.due_at, done: ["completed", "cancelled"].includes(f.status) }); });
    return { calls, links, people: await loadPeople(calls.map((c) => c.customer_id)) };
  }, [workspace.id, refreshKey]);

  const all = useMemo(() => (data?.calls ?? []).filter((c) => !transcriptsOnly || c.transcript || recordingAllowed(c)), [data, transcriptsOnly]);
  const rows = all.filter((c) =>
    filter === "missed" ? c.status === "missed" : filter === "ai" ? c.ai_handled : filter === "answered" ? c.status !== "missed"
      : filter === "human" ? isOpenEscalation(c) : filter === "recorded" ? recordingAllowed(c) : true);
  useEffect(() => setPage(0), [filter]);
  const pages = Math.max(1, Math.ceil(rows.length / PAGE_SIZE));
  const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
  const missedOpen = all.filter((c) => c.status === "missed" && !c.metadata?.followed_up_at && !(data.links[c.id] ?? []).length).length;
  const open = openId ? (data?.calls ?? []).find((c) => c.id === openId) : null;

  return (
    <>
      <PageHead
        crumb={transcriptsOnly ? "AI & Intelligence / Transcripts" : "Communications / Calls"}
        title={transcriptsOnly ? "Transcripts and recordings" : "Calls"}
        sub={transcriptsOnly ? "What callers said and how your AI receptionist answered." : missedOpen ? `${plural(missedOpen, "missed call")} still waiting for a follow-up.` : "Every call, what came of it, and who is following up."}
      >
        <Segment label="Call filter" value={filter} onChange={setFilter} options={FILTERS} />
      </PageHead>

      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !rows.length ? (
          <div className="ba-panel-body"><Empty title={filter === "all" ? "No calls yet" : "No calls match"}>{filter === "all" ? "Calls appear here once your phone line is live." : "Try another filter."}</Empty></div>
        ) : (
          <>
            <div className="ba-table-wrap">
              <table className="ba-table">
                <thead><tr><th>Caller</th><th>When</th><th>Result</th><th>Handled by</th><th>Length</th><th>Outcome</th><th>Assigned to</th><th /></tr></thead>
                <tbody>
                  {visible.map((c) => {
                    const person = data.people[c.customer_id];
                    const name = personName(person) ?? c.from_number ?? "Unknown caller";
                    const missed = c.status === "missed";
                    const links = data.links[c.id] ?? [];
                    const openLinks = links.filter((l) => !l.done).length;
                    return (
                      <tr key={c.id} onClick={() => setOpenId(c.id)} tabIndex={0} onKeyDown={(e) => e.key === "Enter" && setOpenId(c.id)}>
                        <td><div className="ba-person"><div className="ba-avatar sm">{initials(name)}</div><div><strong>{name}</strong><small>{person ? c.from_number ?? "" : "Not in your list yet"}</small></div></div></td>
                        <td><span title={`${formatDay(c.created_at, tz)} ${formatTime(c.created_at, tz)}`}>{timeAgo(c.created_at)}</span></td>
                        <td><Pill tone={missed ? "danger" : "success"}>{missed ? (c.metadata?.followed_up_at ? "Missed, followed up" : "Missed") : "Answered"}</Pill></td>
                        <td>{c.ai_handled ? "AI receptionist" : "Team"}</td>
                        <td>{clock(c.duration_seconds)}</td>
                        <td>{c.outcome ? <Pill tone={OUTCOME_TONE[c.outcome]}>{OUTCOMES[c.outcome]}</Pill> : <span className="ba-muted">—</span>}</td>
                        <td><Assignee id={c.assigned_to} nameOf={roster.nameOf} /></td>
                        <td className="ba-actions">
                          {isOpenEscalation(c) && <Pill tone="danger">Needs a human</Pill>}
                          {openLinks > 0 && <Pill tone="info" >Follow-up set</Pill>}
                          {recordingAllowed(c) && <Icon name="graphic_eq" size="sm" />}
                          {c.transcript && <Icon name="subject" size="sm" />}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <Pager page={page} pages={pages} total={rows.length} onPage={setPage} noun="call" />
          </>
        )}
      </section>

      {open && (
        <CallDetail
          key={open.id} call={open} person={data.people[open.customer_id]} followUps={data.links[open.id] ?? []} roster={roster} workspace={workspace}
          onClose={() => setOpenId(null)} onChanged={reload} onNotice={onNotice}
          onOpenPerson={(id) => { setOpenId(null); onOpenPerson(id); }}
        />
      )}
    </>
  );
}
