import { useEffect, useState } from "react";
import { DATA_RIGHTS_ROLES, PersonDataRights } from "./BusinessDataRights";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { makeTerm } from "./businessWorkspace";
import { CB_CLOSED, CB_REASON, LeadTab, when } from "./BusinessWork";
import { useRoster } from "./BusinessLeads";
import { EmailField, PhoneField } from "./formFields";
import { checkEmail, validatePhone } from "./formValidation";
import { formatDay, formatTime, timeAgo } from "./businessTime";
import {
  APPT_LABEL, APPT_TONE, changed, clock, friendly, orThrow, sourceLabel, transcriptLines, useLoad,
} from "./BusinessShared";

// One place for everything about a person: their details, every call with the
// full transcript, appointments and conversations in one timeline, and any
// hand-off to a human. Opened by clicking a name anywhere in the app.

export const isOpenEscalation = (call) => Boolean(call?.needs_human) && !call?.escalation_resolved_at;

const ESCALATION_REASONS = [
  "Caller asked for a person",
  "Medical or urgent question",
  "Complaint or upset caller",
  "Billing or insurance",
  "AI couldn't answer",
  "Other",
];

// Flag a call for a human, or mark a hand-off as dealt with.
export function EscalationControls({ call, onChanged, onNotice, compact }) {
  const [reason, setReason] = useState(ESCALATION_REASONS[0]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const open = isOpenEscalation(call);

  // The database records who did it and when, and checks the person belongs to this business.
  async function save(flag, message) {
    setBusy(true);
    setError("");
    const { error: updateError } = await supabase.rpc("zella_call_set_escalation", { p_call_id: call.id, p_flag: flag, p_reason: flag ? reason : null });
    setBusy(false);
    if (updateError) return setError(friendly(updateError));
    onNotice?.(message);
    onChanged?.();
  }

  const resolve = () => save(false, "Hand-off marked as handled.");

  const flag = () => save(true, "Flagged for a human.");

  return (
    <div className={`ba-escalate ${compact ? "compact" : ""}`}>
      {error && <div className="ba-banner error">{error}</div>}
      {open ? (
        <button type="button" className="ba-btn primary sm" disabled={busy} onClick={resolve}>
          <Icon name="task_alt" size="sm" />Mark handled
        </button>
      ) : call.needs_human ? (
        <span className="ba-muted">Handled {timeAgo(call.escalation_resolved_at)}</span>
      ) : (
        <>
          <select value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Reason for hand-off" disabled={busy}>
            {ESCALATION_REASONS.map((r) => <option key={r}>{r}</option>)}
          </select>
          <button type="button" className="ba-btn sm danger-outline" disabled={busy} onClick={flag}>
            <Icon name="support_agent" size="sm" />Needs a human
          </button>
        </>
      )}
    </div>
  );
}

export function Transcript({ transcript }) {
  const lines = transcriptLines(transcript);
  if (!lines.length) return <p className="ba-muted">No transcript was saved for this call.</p>;
  return (
    <div className="ba-transcript">
      {lines.map((l, i) => {
        const ai = /assistant|ai|bot/i.test(l.who);
        return (
          <p key={i} className={ai ? "ai" : "caller"}>
            {l.who && <b>{ai ? "Receptionist" : "Caller"}</b>}
            {l.text}
          </p>
        );
      })}
    </div>
  );
}

export function CallCard({ call, tz, defaultOpen, onChanged, onNotice }) {
  const [open, setOpen] = useState(Boolean(defaultOpen));
  const missed = call.status === "missed";
  const flagged = isOpenEscalation(call);
  return (
    <article className={`ba-item ${flagged ? "alert" : ""}`}>
      <button type="button" className="ba-item-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <div className="ba-item-name">
          <Icon name={missed ? "phone_missed" : call.direction === "outbound" ? "call_made" : "call_received"} size="sm" />
          <span>{formatDay(call.created_at, tz)} · {formatTime(call.created_at, tz)}</span>
        </div>
        <div className="ba-item-meta">
          {flagged && <Pill tone="danger">Needs a human</Pill>}
          <Pill tone={missed ? "danger" : "success"}>{missed ? "Missed" : "Answered"}</Pill>
          <span>{call.ai_handled ? "AI" : "Team"} · {clock(call.duration_seconds)}</span>
          <Icon name={open ? "expand_less" : "expand_more"} size="sm" />
        </div>
      </button>
      {call.summary && <p className="ba-item-text">{call.summary}</p>}
      {call.needs_human && call.escalation_reason && <p className="ba-item-text"><strong>Why:</strong> {call.escalation_reason}</p>}
      {open && call.recording_url && (
        <audio className="ba-audio" controls preload="none" src={call.recording_url}>
          <a href={call.recording_url}>Listen to the recording</a>
        </audio>
      )}
      {open && <Transcript transcript={call.transcript} />}
      <EscalationControls call={call} onChanged={onChanged} onNotice={onNotice} compact />
    </article>
  );
}

function followLabel(f) {
  const tries = `${f.attempts ?? 0} of ${f.max_attempts ?? 2} tries`;
  if (f.status === "pending") return "Zella will call to offer a new time";
  if (f.status === "in_progress") return "Zella is calling to offer a new time";
  if (f.status === "cancelled") return "Follow-up call cancelled";
  const o = { rescheduled: "Rebooked after the follow-up call", wants_callback: "Asked for a call from the team", declined: "Declined a new time", no_answer: `No answer after ${tries}`, voicemail: `Voicemail after ${tries}`, failed: `Call failed after ${tries}`, sms_sent: "Text sent offering a new time" };
  return o[f.outcome] ?? "Follow-up finished";
}

function buildTimeline(person, calls, appts, convos, follows = [], cbs = [], tasks = []) {
  const events = [
    ...calls.map((c) => ({ key: `c${c.id}`, at: c.created_at, kind: "call", call: c })),
    ...appts.map((a) => ({ key: `a${a.id}`, at: a.start_time, kind: "appt", appt: a })),
    ...follows.map((f) => ({ key: `f${f.id}`, at: f.status === "pending" ? f.due_at : (f.completed_at ?? f.updated_at ?? f.due_at), kind: "follow", follow: f })),
    ...convos.map((c) => ({ key: `v${c.id}`, at: c.last_message_at ?? c.created_at, kind: "convo", convo: c })),
    ...cbs.map((c) => ({ key: `b${c.id}`, at: c.completed_at ?? c.due_at ?? c.created_at, kind: "cb", cb: c })),
    ...tasks.map((k) => ({ key: `k${k.id}`, at: k.completed_at ?? k.due_at ?? k.created_at, kind: "task", task: k })),
    { key: "added", at: person.created_at, kind: "added" },
  ].filter((e) => e.at);
  return events.sort((a, b) => new Date(b.at) - new Date(a.at));
}

const TABS = [["overview", "Overview"], ["appointments", "Appointments"], ["timeline", "Timeline"], ["calls", "Calls"], ["messages", "Messages"], ["followups", "Follow-ups"], ["lead", "Lead & quotes"], ["privacy", "Privacy"]];

export default function PersonProfile({ personId, workspace, onClose, onChanged, onNotice }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const [tab, setTab] = useState("overview");
  const [form, setForm] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const { data, error: loadError, loading, reload } = useLoad(async () => {
    const [person, calls, appts, convos] = await Promise.all([
      supabase.from("customers").select("*").eq("id", personId).limit(1),
      supabase.from("calls_view").select("*").eq("customer_id", personId).order("created_at", { ascending: false }).limit(100),
      supabase.from("appointments").select("*").eq("customer_id", personId).order("start_time", { ascending: false }).limit(100),
      supabase.from("conversations").select("*").eq("customer_id", personId).order("last_message_at", { ascending: false, nullsFirst: false }).limit(50),
    ]);
    const row = orThrow(person)[0];
    if (!row) throw new Error("This person could not be found.");
    // Follow-up calls are optional: workspaces without the latest update just show none.
    const followRes = await supabase.from("followup_tasks").select("*").eq("customer_id", personId).order("created_at", { ascending: false }).limit(20);
    const cbRes = await supabase.from("callbacks").select("*").eq("customer_id", personId).order("created_at", { ascending: false }).limit(30);
    const taskRes = await supabase.from("crm_tasks").select("*").eq("customer_id", personId).order("created_at", { ascending: false }).limit(30);
    const staffRes = await supabase.from("staff_members").select("id, name").eq("business_id", workspace.id);
    // Texts, emails and record changes come from the server timeline (calls, appointments and the rest are loaded above).
    const tlRes = await supabase.rpc("zella_customer_timeline", { p_business_id: workspace.id, p_customer_id: personId, p_limit: 100 });
    return {
      person: row, calls: orThrow(calls), appts: orThrow(appts), convos: orThrow(convos), follows: followRes.error ? [] : (followRes.data ?? []),
      cbs: cbRes.error ? [] : cbRes.data ?? [], tasks: taskRes.error ? [] : taskRes.data ?? [], staff: staffRes.error ? [] : staffRes.data ?? [],
      server: tlRes.error ? [] : (tlRes.data ?? []).filter((e) => ["text", "email", "change"].includes(e.type)),
    };
  }, [personId]);

  useEffect(() => {
    const p = data?.person;
    if (!p) return;
    setForm({
      first_name: p.first_name ?? "", last_name: p.last_name ?? "", phone: p.phone ?? "", email: p.email ?? "",
      date_of_birth: p.date_of_birth ?? "", address: p.address ?? "", preferred_contact: p.preferred_contact ?? "",
      tags: (p.tags ?? []).join(", "), notes: p.notes ?? "", do_not_contact: Boolean(p.do_not_contact),
      do_not_call: Boolean(p.do_not_call), do_not_sms: Boolean(p.do_not_sms), do_not_email: Boolean(p.do_not_email),
    });
  }, [data?.person]);

  const refresh = () => { reload(); onChanged?.(); };

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    if (validatePhone(form.phone)) return setError(`Phone: ${validatePhone(form.phone)}`);
    if (checkEmail(form.email)) return setError(`Email: ${checkEmail(form.email)}`);
    setBusy(true);
    setError("");
    const values = {
      first_name: form.first_name.trim() || null,
      last_name: form.last_name.trim() || null,
      phone: form.phone.trim() || null,
      email: form.email.trim() ? form.email.trim().toLowerCase() : null,
      date_of_birth: form.date_of_birth || null,
      address: form.address.trim() || null,
      preferred_contact: form.preferred_contact || null,
      tags: form.tags.split(",").map((t) => t.trim()).filter(Boolean),
      notes: form.notes.trim() || null,
      do_not_contact: form.do_not_contact,
      do_not_call: form.do_not_call, do_not_sms: form.do_not_sms, do_not_email: form.do_not_email,
      updated_at: new Date().toISOString(),
    };
    const { error: updateError } = await changed(supabase.from("customers").update(values).eq("id", personId));
    setBusy(false);
    if (updateError) return setError(friendly(updateError));
    onNotice?.("Details saved.");
    refresh();
  }

  async function markContacted() {
    setBusy(true);
    const { error: updateError } = await changed(supabase.from("customers").update({ last_contacted_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", personId));
    setBusy(false);
    if (updateError) return setError(friendly(updateError));
    onNotice?.("Marked as contacted.");
    refresh();
  }

  const person = data?.person;
  const name = person ? personName(person) ?? "Unnamed" : "Loading…";
  const openCalls = (data?.calls ?? []).filter(isOpenEscalation);
  const [showErrors, setShowErrors] = useState(false);
  const set = (key) => (e) => setForm({ ...form, [key]: e.target.type === "checkbox" ? e.target.checked : e.target.value });
  const timeline = person
    ? [...buildTimeline(person, data.calls, data.appts, data.convos, data.follows, data.cbs, data.tasks),
      ...data.server.map((e) => ({ key: `s-${e.type}-${e.id}`, kind: `srv-${e.type}`, at: e.at, srv: e }))]
      .sort((a, b) => new Date(b.at) - new Date(a.at))
    : [];
  const roster = useRoster(workspace);
  const staffName = Object.fromEntries((data?.staff ?? []).map((m) => [m.id, m.name]));
  const usualProvider = (() => {
    const counts = {};
    (data?.appts ?? []).forEach((a) => { if (a.staff_id && a.status !== "cancelled") counts[a.staff_id] = (counts[a.staff_id] ?? 0) + 1; });
    const top = Object.entries(counts).sort((x, y) => y[1] - x[1])[0];
    return top ? staffName[top[0]] : null;
  })();
  const assignTo = async (userId) => {
    setBusy(true);
    setError("");
    const { error: failure } = await supabase.rpc("zella_assign_lead", { p_customer_id: personId, p_user_id: userId || null });
    setBusy(false);
    if (failure) return setError(friendly(failure));
    onNotice?.(userId ? "Assigned." : "Unassigned.");
    refresh();
  };

  return (
    <Modal
      wide
      title={name}
      description={person ? `${term("customer")} · added ${timeAgo(person.created_at)} · ${sourceLabel(person.source)}${person.last_contacted_at ? ` · last contacted ${timeAgo(person.last_contacted_at)}` : " · not contacted yet"}` : undefined}
      onClose={onClose}
      busy={busy}
    >
      <div className="ba-detail">
        {(error || loadError) && <div className="ba-banner error">{error || loadError}</div>}
        {loading && !data && <p className="ba-muted">Loading…</p>}

        {person && (
          <>
            {openCalls.length > 0 && (
              <div className="ba-banner alert" role="alert">
                <span>
                  <strong>Needs a human.</strong>{" "}
                  {openCalls[0].escalation_reason || "The AI receptionist handed this over."}{" "}
                  {openCalls.length > 1 ? `(${openCalls.length} open hand-offs)` : ""}
                </span>
                {person.phone && <a className="ba-btn primary sm" href={`tel:${person.phone}`}><Icon name="call" size="sm" />Call now</a>}
              </div>
            )}
            {person.do_not_contact && <div className="ba-banner error">This person asked not to be contacted.</div>}

            <div className="ba-profile-top">
              <div className="ba-avatar">{initials(name)}</div>
              <div className="ba-profile-contact">
                {person.phone && <a className="ba-btn sm" href={`tel:${person.phone}`}><Icon name="call" size="sm" />{person.phone}</a>}
                {person.email && <a className="ba-btn sm" href={`mailto:${person.email}`}><Icon name="mail" size="sm" />{person.email}</a>}
                <button type="button" className="ba-btn sm" disabled={busy} onClick={markContacted}>Mark contacted</button>
              </div>
              <div className="ba-tags">{(person.tags ?? []).map((t) => <Pill key={t} tone="indigo">{t}</Pill>)}</div>
            </div>
            <div className="ba-inbox-controls">
              {roster.list.length > 0 && (
                <label className="ba-select"><span>Assigned to</span>
                  <select value={person.assigned_to ?? ""} disabled={busy} onChange={(e) => assignTo(e.target.value)}>
                    <option value="">Unassigned</option>
                    {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
                  </select>
                </label>
              )}
              {usualProvider && <span className="ba-muted">Usually sees {usualProvider}</span>}
            </div>

            <div className="ba-segment" role="tablist" aria-label="Profile sections">
              {TABS.filter(([key]) => key !== "privacy" || DATA_RIGHTS_ROLES.includes(workspace.role)).map(([key, label]) => (
                <button key={key} type="button" role="tab" aria-selected={tab === key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>
                  {label}{key === "calls" ? ` (${data.calls.length})` : key === "appointments" ? ` (${data.appts.length})` : key === "messages" ? ` (${data.convos.length})` : key === "followups" ? ` (${data.cbs.length + data.tasks.length + data.follows.length})` : ""}
                </button>
              ))}
            </div>

            {tab === "overview" && form && (
              <form className="ba-form-grid" onSubmit={save}>
                <Field label="First name"><input value={form.first_name} onChange={set("first_name")} /></Field>
                <Field label="Last name"><input value={form.last_name} onChange={set("last_name")} /></Field>
                <Field label="Phone" bare><PhoneField value={form.phone} onChange={(phone) => setForm((f) => ({ ...f, phone }))} showErrors={showErrors} label="Phone" /></Field>
                <Field label="Email" bare><EmailField value={form.email} onChange={(email) => setForm((f) => ({ ...f, email }))} showErrors={showErrors} /></Field>
                <Field label="Date of birth"><input value={form.date_of_birth} onChange={set("date_of_birth")} type="date" /></Field>
                <Field label="Prefers to be contacted by">
                  <select value={form.preferred_contact} onChange={set("preferred_contact")}>
                    <option value="">No preference</option><option value="phone">Phone call</option><option value="sms">Text message</option><option value="email">Email</option>
                  </select>
                </Field>
                <Field label="Address" full><input value={form.address} onChange={set("address")} /></Field>
                <Field label="Tags" hint="Separate with commas, for example: new patient, insurance" full><input value={form.tags} onChange={set("tags")} /></Field>
                <Field label="Administrative notes" hint="For the front desk only, such as preferences or how to reach them. Don't record medical or treatment details here." full><textarea value={form.notes} onChange={set("notes")} placeholder="Anything the team should know" /></Field>
                <fieldset className="ba-prefs full">
                  <legend>How we may contact them</legend>
                  <label className="ba-check"><input type="checkbox" checked={form.do_not_call} onChange={set("do_not_call")} /><span>No phone calls</span></label>
                  <label className="ba-check"><input type="checkbox" checked={form.do_not_sms} onChange={set("do_not_sms")} /><span>No text messages</span></label>
                  <label className="ba-check"><input type="checkbox" checked={form.do_not_email} onChange={set("do_not_email")} /><span>No emails</span></label>
                  <label className="ba-check"><input type="checkbox" checked={form.do_not_contact} onChange={set("do_not_contact")} /><span>Do not contact at all (no calls, texts, emails or reminders)</span></label>
                </fieldset>
                <div className="full ba-form-actions"><button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Save details"}</button></div>
              </form>
            )}

            {tab === "privacy" && <PersonDataRights person={person} workspace={workspace} onChanged={refresh} onNotice={onNotice} />}

            {tab === "lead" && <LeadTab person={person} workspace={workspace} onChanged={refresh} onNotice={onNotice} />}

            {tab === "timeline" && (
              timeline.length ? (
                <ol className="ba-timeline">
                  {timeline.map((e) => (
                    <li key={e.key} className={e.kind}>
                      <span className="ba-tl-dot"><Icon size="sm" name={e.kind === "srv-text" ? "sms" : e.kind === "srv-email" ? "mail" : e.kind === "srv-change" ? "edit" : e.kind === "call" ? "call" : e.kind === "appt" ? "event" : e.kind === "convo" ? "chat" : e.kind === "follow" || e.kind === "cb" ? "phone_callback" : e.kind === "task" ? "task_alt" : "person_add"} /></span>
                      <div>
                        <strong>
                          {e.kind === "call" && `${e.call.status === "missed" ? "Missed call" : e.call.ai_handled ? "Call answered by the AI receptionist" : "Call answered by the team"}`}
                          {e.kind === "appt" && `${e.appt.title} · ${APPT_LABEL[e.appt.status] ?? e.appt.status}${e.appt.attendance_note || e.appt.cancel_reason ? ` (${e.appt.attendance_note || e.appt.cancel_reason})` : ""}`}
                          {e.kind === "convo" && `${e.convo.channel ?? "Message"} conversation${e.convo.subject ? `: ${e.convo.subject}` : ""}`}
                          {e.kind === "follow" && followLabel(e.follow)}
                          {e.kind === "cb" && `${CB_REASON[e.cb.reason] ?? "Callback"}${CB_CLOSED.includes(e.cb.status) ? " · done" : ` · due ${formatDay(e.cb.due_at, tz)}`}`}
                          {e.kind === "task" && `${e.task.title}${e.task.status === "open" ? "" : " · done"}`}
                          {e.kind === "added" && `Added to your ${term("customers").toLowerCase()}`}
                          {e.srv && `${e.srv.title}${e.srv.status ? ` · ${String(e.srv.status).replace(/_/g, " ")}` : ""}`}
                        </strong>
                        <small>
                          {formatDay(e.at, tz)} · {formatTime(e.at, tz)}
                          {e.kind === "call" && ` · ${clock(e.call.duration_seconds)}`}
                          {e.kind === "appt" && e.appt.checked_in_at && ` · checked in ${formatTime(e.appt.checked_in_at, tz)}`}
                        </small>
                        {e.kind === "call" && isOpenEscalation(e.call) && <Pill tone="danger">Needs a human</Pill>}
                        {e.kind === "call" && e.call.summary && <p className="ba-item-text">{e.call.summary}</p>}
                        {e.srv?.detail && e.srv.type !== "change" && <p className="ba-item-text">{e.srv.detail}</p>}
                      </div>
                    </li>
                  ))}
                </ol>
              ) : <p className="ba-muted">Nothing here yet.</p>
            )}

            {tab === "calls" && (
              data.calls.length ? data.calls.map((c, i) => (
                <CallCard key={c.id} call={c} tz={tz} defaultOpen={i === 0 && Boolean(c.transcript)} onChanged={refresh} onNotice={onNotice} />
              )) : <p className="ba-muted">No calls from this {term("customer").toLowerCase()} yet.</p>
            )}

            {tab === "appointments" && (() => {
              const nowMs = Date.now();
              const upcoming = data.appts.filter((a) => ["scheduled", "confirmed"].includes(a.status) && new Date(a.end_time ?? a.start_time).getTime() >= nowMs).sort((x, y) => new Date(x.start_time) - new Date(y.start_time));
              const previous = data.appts.filter((a) => !upcoming.includes(a));
              const row = (a) => (
                <div key={a.id} className="ba-mini">
                  <span>
                    {a.title}
                    <small>{formatDay(a.start_time, tz)} · {formatTime(a.start_time, tz)}{staffName[a.staff_id] ? ` · ${staffName[a.staff_id]}` : ""}{a.location ? ` · ${a.location}` : ""}{a.checked_in_at ? ` · checked in ${formatTime(a.checked_in_at, tz)}` : ""}</small>
                    {(a.attendance_note || a.cancel_reason) && <small>{a.attendance_note || a.cancel_reason}</small>}
                  </span>
                  <Pill tone={APPT_TONE[a.status]}>{APPT_LABEL[a.status] ?? a.status}</Pill>
                </div>
              );
              return data.appts.length ? (
                <>
                  <h3 className="ba-sub">Upcoming</h3>
                  {upcoming.length ? upcoming.map(row) : <p className="ba-muted">Nothing booked.</p>}
                  <h3 className="ba-sub">Previous</h3>
                  {previous.length ? previous.map(row) : <p className="ba-muted">No past {term("appointments").toLowerCase()}.</p>}
                </>
              ) : <p className="ba-muted">No {term("appointments").toLowerCase()} yet.</p>;
            })()}

            {tab === "messages" && (
              data.convos.length ? data.convos.map((c) => (
                <div key={c.id} className="ba-mini">
                  <span>{c.subject || `${c.channel ?? "Message"} conversation`}<small>{c.channel ?? "Message"} · last message {c.last_message_at ? timeAgo(c.last_message_at) : "never"}{c.ai_handled ? " · AI handling" : ""}</small></span>
                  <Pill tone={c.status === "open" ? "warning" : ""}>{c.status}</Pill>
                </div>
              )) : <p className="ba-muted">No messages yet.</p>
            )}

            {tab === "followups" && (() => {
              const items = [
                ...data.cbs.map((c) => ({ key: `cb${c.id}`, at: c.due_at ?? c.created_at, title: CB_REASON[c.reason] ?? "Callback", icon: "phone_callback", done: CB_CLOSED.includes(c.status), detail: `${c.attempts} of ${c.max_attempts} tries${c.summary ? ` · ${c.summary}` : ""}`, status: c.status })),
                ...data.tasks.map((k) => ({ key: `t${k.id}`, at: k.due_at ?? k.created_at, title: k.title, icon: "task_alt", done: k.status !== "open", detail: k.body ?? "", status: k.status })),
                ...data.follows.map((f) => ({ key: `f${f.id}`, at: f.status === "pending" ? f.due_at : (f.completed_at ?? f.due_at), title: followLabel(f), icon: "forward_to_inbox", done: !["pending", "in_progress"].includes(f.status), detail: "", status: f.status })),
              ].sort((a, b) => new Date(b.at) - new Date(a.at));
              return items.length ? items.map((i) => (
                <div key={i.key} className="ba-mini">
                  <span><Icon name={i.icon} size="sm" /> {i.title}<small>{when(i.at, tz)}{i.detail ? ` · ${i.detail}` : ""}</small></span>
                  <Pill tone={i.done ? "success" : "warning"}>{i.done ? "Done" : "Open"}</Pill>
                </div>
              )) : <p className="ba-muted">No follow-ups yet.</p>;
            })()}
          </>
        )}
      </div>
    </Modal>
  );
}
