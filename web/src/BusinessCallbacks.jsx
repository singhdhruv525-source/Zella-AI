import { useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { Empty, Notice, PageHead, Segment, explain, loadPeople, orThrow, useLoad } from "./BusinessShared";
import { ATTEMPT_LABEL, CB_CLOSED, CB_REASON, CB_STATUS, NewCallbackModal, PRIORITY_TONE, when } from "./BusinessWork";
import { Assignee, useRoster } from "./BusinessLeads";

/* The callback work queue: what is due now, what is coming, what slipped, and
   what needs a person. Zella's own retries follow the business's rules (tries
   allowed, delay between tries, calling hours); people never bypass an opt-out here. */

const HOUR = 3600000;
const REVIEW = ["needs_review", "escalated"];

export function queueOf(cb, now = Date.now()) {
  if (CB_CLOSED.includes(cb.status)) return "done";
  if (REVIEW.includes(cb.status)) return "person";
  const due = new Date(cb.due_at ?? cb.created_at).getTime();
  if (due > now) return "upcoming";
  return now - due > HOUR ? "overdue" : "now";
}

const OUTCOMES = [
  ["reached", "Spoke with them"],
  ["booked", "Booked an appointment"],
  ["not_interested", "Not interested"],
  ["wrong_number", "Wrong number"],
  ["other", "Something else"],
];
const NEXT = [
  ["none", "Nothing more to do"],
  ["follow_up_1", "Follow up tomorrow"],
  ["follow_up_3", "Follow up in 3 days"],
  ["follow_up_7", "Follow up in a week"],
];

function optedOut(person) {
  return Boolean(person?.do_not_contact || person?.do_not_call);
}

function CallbackDetail({ cb, person, last, roster, workspace, startFinishing, onClose, onChanged, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const closed = CB_CLOSED.includes(cb.status);
  const blocked = optedOut(person);
  const { data, error: loadError } = useLoad(async () =>
    orThrow(await supabase.from("callback_attempts").select("*").eq("callback_id", cb.id).order("attempt_no")), [cb.id]);
  const [note, setNote] = useState("");
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [owner, setOwner] = useState(cb.assigned_to ?? "");
  const [finishing, setFinishing] = useState(Boolean(startFinishing));
  const [fin, setFin] = useState({ outcome: "reached", next: "none" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function call(work, message, keepOpen) {
    setBusy(true);
    setError("");
    const { error: failure } = await work();
    setBusy(false);
    if (failure) return setError(explain(failure));
    onNotice(message);
    onChanged();
    if (!keepOpen) onClose();
  }
  const update = (status, message, extra = {}) => call(() => supabase.rpc("zella_update_callback", { p_callback_id: cb.id, p_status: status, p_note: note.trim() || null, ...extra }), message);
  const attempt = (outcome, message) => call(() => supabase.rpc("zella_record_callback_attempt", { p_callback_id: cb.id, p_outcome: outcome, p_notes: note.trim() || null }), message);
  const reschedule = () => {
    if (!date || !time) return setError("Pick a day and time.");
    return call(() => supabase.rpc("zella_update_callback", { p_callback_id: cb.id, p_preferred_at: zonedDateTime(date, time, tz).toISOString(), p_note: note.trim() || null }), "Callback moved to the new time.");
  };
  const assign = () => call(() => supabase.rpc("zella_update_callback", { p_callback_id: cb.id, p_assign_to: owner || null }), owner ? "Callback assigned." : "Assignment kept.", true);

  async function finish(event) {
    event.preventDefault();
    const outcomeLabel = OUTCOMES.find(([k]) => k === fin.outcome)[1];
    const nextLabel = NEXT.find(([k]) => k === fin.next)[1];
    const summary = `Outcome: ${outcomeLabel}. Next: ${nextLabel}.${note.trim() ? ` ${note.trim()}` : ""}`;
    setBusy(true);
    setError("");
    // Record the conversation as a try (unless it never connected), then close it with what happened.
    if (!["wrong_number"].includes(fin.outcome) && cb.status !== "contacted") {
      const r = await supabase.rpc("zella_record_callback_attempt", { p_callback_id: cb.id, p_outcome: "connected", p_notes: summary });
      if (r.error) { setBusy(false); return setError(explain(r.error)); }
    }
    const done = await supabase.rpc("zella_update_callback", { p_callback_id: cb.id, p_status: "completed", p_note: summary });
    if (done.error) { setBusy(false); return setError(explain(done.error)); }
    if (fin.next.startsWith("follow_up") && cb.customer_id) {
      const days = Number(fin.next.split("_")[2]);
      const dueDay = new Date(Date.now() + days * 86400000).toLocaleDateString("en-CA", { timeZone: tz });
      const t = await supabase.rpc("zella_staff_create_task", {
        p_business_id: workspace.id, p_customer_id: cb.customer_id,
        p_title: `Follow up with ${personName(person) ?? cb.contact_number ?? "caller"}`, p_due_at: zonedDateTime(dueDay, "09:00", tz).toISOString(),
        p_assigned_to: cb.assigned_to ?? null, p_priority: cb.priority ?? "normal",
      });
      if (t.error) { setBusy(false); onChanged(); return setError(`Callback closed, but the follow-up task failed: ${explain(t.error)}`); }
    }
    setBusy(false);
    onNotice("Callback finished.");
    onChanged();
    onClose();
  }

  const [label, tone] = CB_STATUS[cb.status] ?? [cb.status, ""];
  return (
    <Modal wide title={personName(person) ?? cb.contact_number ?? "Callback"} onClose={onClose} busy={busy}
      description={`${CB_REASON[cb.reason] ?? "Call back"} · ${closed ? `closed ${timeAgo(cb.completed_at ?? cb.updated_at)}` : `due ${when(cb.due_at, tz)}`}`}>
      <div className="ba-modal-body">
        {(error || loadError) && <p className="ba-error" role="alert">{error || loadError}</p>}
        {blocked && <div className="ba-banner error">This person asked not to be contacted. Don't call or text them.</div>}
        <div className="ba-kn-head">
          <Pill tone={tone}>{label}</Pill>
          {cb.priority !== "normal" && <Pill tone={PRIORITY_TONE[cb.priority]}>{cb.priority === "urgent" ? "Urgent" : "High priority"}</Pill>}
          <Pill>{cb.attempts} of {cb.max_attempts} tries</Pill>
          {cb.status === "retry_scheduled" && <Pill tone="info">Zella retries {when(cb.due_at, tz)}</Pill>}
          {cb.auto_call && !closed && <Pill tone="info">Zella will call</Pill>}
          {cb.contact_number && !blocked && <a className="ba-btn sm" href={`tel:${cb.contact_number}`}><Icon name="call" size="sm" />{cb.contact_number}</a>}
          {person && <button type="button" className="ba-btn sm" onClick={() => { onClose(); onOpenPerson(person.id); }}>Open profile</button>}
        </div>
        {cb.summary && <p className="ba-item-text">{cb.summary}</p>}
        {cb.note && <p className="ba-muted">{cb.note}</p>}
        {last && <p className="ba-muted">Last try: {ATTEMPT_LABEL[last.outcome] ?? last.outcome}, {timeAgo(last.attempted_at)}.</p>}

        <h3 className="ba-sub">Tries</h3>
        {!data?.length ? <p className="ba-muted">No tries yet.</p> : (
          <ul className="ba-threads">
            {data.map((a) => (
              <li key={a.id}>
                <span className="ba-thread-icon"><Icon name={a.outcome === "connected" ? "call" : "phone_missed"} size="sm" /></span>
                <div><strong>{ATTEMPT_LABEL[a.outcome] ?? a.outcome}</strong><small>Try {a.attempt_no} · {when(a.attempted_at, tz)}{a.initiated_by === "system" ? " · Zella" : ""}{a.notes ? ` · ${a.notes}` : ""}</small></div>
              </li>
            ))}
          </ul>
        )}

        {!closed && (
          <>
            <h3 className="ba-sub">Assigned to</h3>
            <div className="ba-inline-form">
              <select value={owner} onChange={(e) => setOwner(e.target.value)} aria-label="Assigned to">
                <option value="">Unassigned</option>
                {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
              </select>
              <button type="button" className="ba-btn sm" disabled={busy || !owner || owner === (cb.assigned_to ?? "")} onClick={assign}>Assign</button>
            </div>

            <Field label="Note" full><textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} placeholder="What happened? Optional." /></Field>
            <div className="ba-form-actions wrap">
              <button type="button" className="ba-btn primary sm" disabled={busy} onClick={() => setFinishing(true)}>Mark contacted</button>
              <button type="button" className="ba-btn sm" disabled={busy} onClick={() => attempt("no_answer", "No answer noted.")}>No answer</button>
              <button type="button" className="ba-btn sm" disabled={busy} onClick={() => attempt("voicemail", "Voicemail noted.")}>Left voicemail</button>
              <button type="button" className="ba-btn sm" disabled={busy} onClick={() => attempt("invalid_number", "Number marked as not working.")}>Number not working</button>
              <button type="button" className="ba-btn sm" disabled={busy || cb.status === "in_progress"} onClick={() => update("in_progress", "Marked as in progress.")}>I'm calling now</button>
              <button type="button" className="ba-btn sm" disabled={busy} onClick={() => update("waiting_on_customer", "Waiting on the customer.")}>Waiting on them</button>
              <button type="button" className="ba-btn sm" disabled={busy || cb.status === "escalated"} onClick={() => update("escalated", "Escalated to a person.")}>Escalate</button>
              <button type="button" className="ba-btn sm danger-outline" disabled={busy} onClick={() => update("cancelled", "Callback canceled.")}>Cancel callback</button>
            </div>

            {finishing && (
              <form className="ba-form-grid ba-finish" onSubmit={finish}>
                <Field label="What happened?"><select value={fin.outcome} onChange={(e) => setFin({ ...fin, outcome: e.target.value })}>{OUTCOMES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
                <Field label="What's next?" hint={!cb.customer_id && fin.next !== "none" ? "Follow-up tasks need a known person." : undefined}>
                  <select value={fin.next} onChange={(e) => setFin({ ...fin, next: e.target.value })}>{NEXT.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
                </Field>
                <div className="full ba-form-actions">
                  <button type="submit" className="ba-btn primary sm" disabled={busy}>{busy ? "Saving…" : "Finish callback"}</button>
                  <button type="button" className="ba-btn sm" onClick={() => setFinishing(false)}>Not yet</button>
                </div>
              </form>
            )}

            <h3 className="ba-sub">Move to another time</h3>
            <div className="ba-form-grid">
              <Field label="Day"><input type="date" min={todayInput(tz)} value={date} onChange={(e) => setDate(e.target.value)} /></Field>
              <Field label="Time"><input type="time" value={time} onChange={(e) => setTime(e.target.value)} /></Field>
            </div>
            <div className="ba-form-actions"><button type="button" className="ba-btn sm" disabled={busy} onClick={reschedule}>Move callback</button></div>
            <p className="ba-muted">Times outside your calling hours move to the next available time.</p>
          </>
        )}
      </div>
    </Modal>
  );
}

const TABS = [["now", "Due now"], ["upcoming", "Upcoming"], ["overdue", "Overdue"], ["person", "Needs a person"], ["done", "Completed"]];

export function CallbacksPage({ workspace, refreshKey, onNotice, onOpenPerson, onChanged }) {
  const tz = workspace.timezone;
  const [tab, setTab] = useState(null);
  const [open, setOpen] = useState(null); // { cb, finishing }
  const [adding, setAdding] = useState(false);
  const roster = useRoster(workspace);
  const { data, error, loading, reload } = useLoad(async () => {
    const rows = orThrow(await supabase.from("callbacks").select("*").eq("business_id", workspace.id).order("due_at", { ascending: true, nullsFirst: false }).limit(400));
    const ids = rows.map((r) => r.customer_id).filter(Boolean);
    const people = await loadPeople(ids);
    // Opt-out flags and each callback's latest try.
    const flags = ids.length ? await supabase.from("customers").select("id, do_not_contact, do_not_call").in("id", [...new Set(ids)]) : { data: [] };
    (flags.data ?? []).forEach((f) => { if (people[f.id]) Object.assign(people[f.id], f); });
    const tries = rows.length ? await supabase.from("callback_attempts").select("callback_id, outcome, attempted_at, attempt_no").in("callback_id", rows.map((r) => r.id)).order("attempted_at", { ascending: false }).limit(1000) : { data: [] };
    const last = {};
    (tries.data ?? []).forEach((a) => { if (!last[a.callback_id]) last[a.callback_id] = a; });
    return { rows, people, last };
  }, [workspace.id, refreshKey]);

  const rows = data?.rows ?? [];
  const now = Date.now();
  const groups = useMemo(() => {
    const g = { now: [], upcoming: [], overdue: [], person: [], done: [] };
    rows.forEach((r) => g[queueOf(r)].push(r));
    g.done.sort((a, b) => new Date(b.completed_at ?? b.updated_at) - new Date(a.completed_at ?? a.updated_at));
    return g;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows]);
  const active = tab ?? (groups.person.length ? "person" : groups.overdue.length ? "overdue" : groups.now.length ? "now" : "upcoming");
  const shown = groups[active];
  const changed = () => { reload(); onChanged?.(); };
  const needPerson = groups.person.length;

  async function callNow(cb) {
    // Starting a call by hand marks it in progress so the try is counted once.
    if (cb.status !== "in_progress") {
      await supabase.rpc("zella_update_callback", { p_callback_id: cb.id, p_status: "in_progress" });
      changed();
    }
  }

  return (
    <>
      <PageHead crumb="Calls & messages / Callbacks" title="Callbacks"
        sub={needPerson ? `${needPerson === 1 ? "1 callback needs" : `${needPerson} callbacks need`} a person. Zella has stopped calling.` : "People waiting for a call back, and what happened on each try."}>
        <button type="button" className="ba-btn primary" onClick={() => setAdding(true)}><Icon name="add_call" size="sm" />Add callback</button>
      </PageHead>
      <div className="ba-toolbar ba-lead-tools">
        <Segment label="Callback queue" value={active} onChange={setTab}
          options={TABS.map(([k, l]) => [k, groups[k].length && k !== "done" ? `${l} (${groups[k].length})` : l])} />
      </div>
      <Notice error={error} onRetry={reload} />
      {loading && !data ? <p className="ba-muted">Loading…</p> : !shown.length ? (
        <Empty title={active === "done" ? "Nothing finished yet" : "Nothing here"}>
          {active === "person" ? "When Zella can't reach someone after its tries, or you escalate one, it shows up here."
            : active === "done" ? "Finished callbacks are kept here, with what happened."
            : "Missed calls, requests for a call back and failed transfers appear here with a time to call."}
        </Empty>
      ) : (
        <section className="ba-panel">
          <div className="ba-table-wrap">
            <table className="ba-table ba-queue">
              <thead><tr><th>Who</th><th>Reason</th><th>{active === "done" ? "Closed" : "Call at"}</th><th>Tries</th><th>Assigned to</th><th /></tr></thead>
              <tbody>
                {shown.map((c) => {
                  const person = data.people[c.customer_id];
                  const name = personName(person) ?? c.contact_number ?? "Unknown caller";
                  const last = data.last[c.id];
                  const [label, tone] = CB_STATUS[c.status] ?? [c.status, ""];
                  const closed = CB_CLOSED.includes(c.status);
                  const blocked = optedOut(person);
                  const late = active === "overdue" || (active === "now" && new Date(c.due_at).getTime() < now);
                  return (
                    <tr key={c.id} tabIndex={0} onClick={() => setOpen({ cb: c })} onKeyDown={(e) => e.key === "Enter" && setOpen({ cb: c })}>
                      <td>
                        <div className="ba-person">
                          <div className="ba-avatar sm">{initials(name)}</div>
                          <div><strong>{name}</strong><small>{c.contact_number ?? ""}</small></div>
                        </div>
                      </td>
                      <td>
                        <div className="ba-queue-reason">
                          <span>{CB_REASON[c.reason] ?? "Call back"}</span>
                          {c.priority !== "normal" && <Pill tone={PRIORITY_TONE[c.priority]}>{c.priority === "urgent" ? "Urgent" : "High"}</Pill>}
                          {!["new", "scheduled", "due"].includes(c.status) && <Pill tone={tone}>{label}</Pill>}
                          {blocked && <Pill tone="danger">Do not contact</Pill>}
                        </div>
                        {c.summary && <small className="ba-clip">{c.summary}</small>}
                      </td>
                      <td>{closed ? timeAgo(c.completed_at ?? c.updated_at) : <span className={late ? "ba-flag" : ""}>{when(c.due_at, tz)}</span>}</td>
                      <td>
                        {c.attempts} of {c.max_attempts}
                        {last && <small className="ba-clip">{ATTEMPT_LABEL[last.outcome] ?? last.outcome}</small>}
                      </td>
                      <td><Assignee id={c.assigned_to} nameOf={roster.nameOf} /></td>
                      <td className="ba-actions" onClick={(e) => e.stopPropagation()}>
                        {!closed && (
                          <>
                            {c.contact_number && !blocked
                              ? <a className="ba-btn sm primary" href={`tel:${c.contact_number}`} onClick={() => callNow(c)}><Icon name="call" size="sm" />Call now</a>
                              : null}
                            <button type="button" className="ba-btn sm" onClick={() => setOpen({ cb: c, finishing: true })}>Mark contacted</button>
                            <button type="button" className="ba-btn sm" onClick={() => setOpen({ cb: c })}>More</button>
                          </>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      )}
      {open && (
        <CallbackDetail
          key={open.cb.id + (open.finishing ? "f" : "")}
          cb={open.cb} person={data?.people[open.cb.customer_id]} last={data?.last[open.cb.id]} roster={roster}
          startFinishing={open.finishing} workspace={workspace}
          onClose={() => setOpen(null)} onChanged={changed} onNotice={onNotice} onOpenPerson={onOpenPerson}
        />
      )}
      {adding && <NewCallbackModal workspace={workspace} onClose={() => setAdding(false)} onSaved={(m) => { setAdding(false); onNotice(m); changed(); }} />}
    </>
  );
}
