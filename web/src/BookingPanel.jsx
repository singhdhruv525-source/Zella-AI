import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { supabase } from "./supabase";
import { Field, Icon, Pill, personName } from "./BusinessUI";
import { formatLongDate, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { APPT_LABEL, APPT_TONE, availabilityAt, changed, explain, friendly, noShowNotice, setCheckIn, callResult, isAnswered } from "./BusinessShared";
import { RescheduleModal } from "./BusinessForms";
import { BookingMessages } from "./BookingMessages";
import { bookingFields, fieldValue, todayConfig } from "./todayConfig";

// The side panel a booking opens in, from the calendar. Sections: booking details, customer, assignment, activity
// and actions. Everything is read and changed with the member's own session (row level security keeps it to this
// business); actions only show when the booking's state allows them and the person's role may change bookings.
// Booking fields follow the industry (todayConfig.js), so a plumber never sees a table and a restaurant never sees
// a service address.

const WRITE_ROLES = ["owner", "admin", "manager", "staff"];
const ref = (id) => String(id).slice(0, 8).toUpperCase();
const mins = (a) => (a.end_time ? Math.round((new Date(a.end_time) - new Date(a.start_time)) / 60000) : null);

function Section({ title, children }) {
  return <section className="bp-section"><h3>{title}</h3>{children}</section>;
}
function Row({ label, children }) {
  if (children === null || children === undefined || children === "") return null;
  return <div className="bp-row"><dt>{label}</dt><dd>{children}</dd></div>;
}

// What a booking is for: the pet, vehicle, property ... (sql/zella_appointment_records.sql). A suggestion (when the
// customer has exactly one) is never treated as the answer until someone confirms it.
function BookingFor({ workspace, appt, canWrite, onChanged, onNotice }) {
  const [choices, setChoices] = useState(null);
  const [linked, setLinked] = useState(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  useEffect(() => {
    let live = true;
    (async () => {
      const ids = [appt.record_id, appt.record_suggested_id].filter(Boolean);
      const recs = ids.length ? await supabase.from("crm_records").select("id, title").in("id", ids) : { data: [] };
      let list = [];
      if (appt.customer_id) {
        const types = await supabase.from("crm_record_types").select("key, singular").eq("business_id", workspace.id).eq("enabled", true).eq("appointment_link", true);
        const keys = (types.data ?? []).map((t) => t.key);
        if (keys.length) {
          const r = await supabase.from("crm_records").select("id, title, type_key").eq("business_id", workspace.id).eq("customer_id", appt.customer_id)
            .in("type_key", keys).is("archived_at", null).order("title");
          const label = Object.fromEntries((types.data ?? []).map((t) => [t.key, t.singular]));
          list = (r.data ?? []).map((x) => ({ ...x, singular: label[x.type_key] }));
        }
      }
      if (live) { setLinked(Object.fromEntries((recs.data ?? []).map((x) => [x.id, x.title]))); setChoices(list); }
    })();
    return () => { live = false; };
  }, [appt.id, appt.record_id, appt.record_suggested_id, appt.customer_id, workspace.id]);
  if (choices === null || (!appt.record_id && !appt.record_suggested_id && choices.length === 0)) return null;
  async function run(work, message) {
    setBusy(true); setProblem("");
    const { error } = await work();
    setBusy(false);
    if (error) return setProblem(/RECORD_OTHER_CUSTOMER/.test(error.message) ? "That belongs to another customer." : /BAD_RECORD/.test(error.message) ? "That can't be booked for." : explain(error));
    onNotice(message); onChanged();
  }
  return (
    <dl className="bp-rows">
      {problem && <p className="ba-error" role="alert">{problem}</p>}
      {appt.record_id ? (
        <Row label="For"><strong>{linked?.[appt.record_id] ?? "Linked record"}</strong></Row>
      ) : appt.record_suggested_id ? (
        <Row label="For">
          <span>{linked?.[appt.record_suggested_id] ?? "Suggested"}? <Pill tone="warning">Not confirmed</Pill></span>
          {canWrite && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => run(() => supabase.rpc("zella_confirm_appointment_record", { p_appointment_id: appt.id }), "Confirmed.")}>Confirm</button>}
        </Row>
      ) : (
        <Row label="For"><Pill tone="warning">Not chosen</Pill></Row>
      )}
      {canWrite && choices.length > 0 && (
        <Row label={appt.record_id ? "Change" : "Choose"}>
          <select aria-label="What this booking is for" value="" disabled={busy}
            onChange={(e) => e.target.value && run(() => supabase.rpc("zella_set_appointment_record", { p_appointment_id: appt.id, p_record_id: e.target.value === "none" ? null : e.target.value }), "Saved.")}>
            <option value="">Pick…</option>
            {choices.filter((c) => c.id !== appt.record_id).map((c) => <option key={c.id} value={c.id}>{c.title}{c.singular ? ` (${c.singular.toLowerCase()})` : ""}</option>)}
            {appt.record_id && <option value="none">Nothing in particular</option>}
          </select>
        </Row>
      )}
    </dl>
  );
}

export function BookingPanel({ workspace, industry, appt, person, staff, blocks, tz, term, onClose, onChanged, onNotice, onOpenPerson }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [moving, setMoving] = useState(false);
  const [editing, setEditing] = useState(false);
  const [activity, setActivity] = useState(null);
  const [confirmForm, setConfirmForm] = useState({ date: todayInput(tz), time: "09:00", minutes: "30" });
  const panel = useRef(null);
  const cfg = todayConfig(industry);
  const staffName = Object.fromEntries(staff.map((m) => [m.id, m.name]));
  const canWrite = WRITE_ROLES.includes(workspace.role);
  const requested = appt.booking_state === "requested";
  // a visit booked from a recurring plan (Release 2) holds the time without a hold expiry until it's confirmed
  const planned = appt.booking_state === "tentative" && Boolean(appt.metadata?.planned);
  const tentative = appt.booking_state === "tentative" && !planned;
  const open = ["scheduled", "confirmed"].includes(appt.status) && !requested;
  const arrived = Boolean(appt.checked_in_at || appt.arrived_at);
  const name = personName(person);
  const oneWord = term("appointment");

  // Escape closes; focus moves into the panel so the keyboard starts there.
  useEffect(() => {
    panel.current?.focus();
    const onKey = (e) => { if (e.key === "Escape" && !busy && !moving) onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [busy, moving, onClose]);

  // Activity: this customer's recent calls and conversations.
  useEffect(() => {
    let live = true;
    (async () => {
      if (!appt.customer_id) { if (live) setActivity({ calls: [], convos: [] }); return; }
      const [calls, convos] = await Promise.all([
        supabase.from("calls_view").select("id, status, ai_handled, created_at, summary, outcome, duration_seconds").eq("business_id", workspace.id)
          .eq("customer_id", appt.customer_id).order("created_at", { ascending: false }).limit(4),
        supabase.from("conversations").select("id, channel, subject, status, last_message_at, ai_handled").eq("business_id", workspace.id)
          .eq("customer_id", appt.customer_id).order("last_message_at", { ascending: false, nullsFirst: false }).limit(4),
      ]);
      if (live) setActivity({ calls: calls.data ?? [], convos: convos.data ?? [] });
    })();
    return () => { live = false; };
  }, [appt.customer_id, workspace.id]);

  async function run(fn, message) {
    setBusy(true);
    setError("");
    const { error: e } = await fn();
    setBusy(false);
    if (e) { setError(friendly(e)); return false; }
    if (message) onNotice(message);
    onChanged();
    return true;
  }
  const setStatus = async (status) => {
    if (status === "no_show") {
      const ok = await run(() => changed(supabase.from("appointments").update({ status, updated_at: new Date().toISOString() }).eq("id", appt.id)));
      if (ok) onNotice(await noShowNotice(appt.id, name ?? appt.title, tz));
      return;
    }
    run(() => changed(supabase.from("appointments").update({ status, updated_at: new Date().toISOString(), ...(status === "cancelled" ? { cancelled_at: new Date().toISOString() } : {}) }).eq("id", appt.id)),
      `${appt.title} ${status === "cancelled" ? "cancelled" : `marked ${APPT_LABEL[status].toLowerCase()}`}.`);
  };
  async function confirmRequest(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    const { error: e } = await supabase.rpc("zella_confirm_requested_appointment", {
      p_appointment_id: appt.id, p_start: zonedDateTime(confirmForm.date, confirmForm.time, tz).toISOString(), p_duration_minutes: Number(confirmForm.minutes) || 30, p_staff_id: null,
    });
    setBusy(false);
    if (e) return setError(explain(e));
    onNotice("Booking confirmed. Reminders are set.");
    onChanged();
  }

  // Assignment: is the person free right now (working hours, time off), as the calendar's "who's in" bar works it out.
  const member = staff.find((m) => m.id === appt.staff_id);
  const availability = member ? availabilityAt(member, blocks, new Date(appt.start_time), tz) : null;
  // Only where bookings are assigned to someone: not for a business with no team listed, nor for a restaurant table.
  const showAssignment = Boolean(appt.staff_id) || (staff.length > 0 && cfg.staffColumn);
  const byAi = ["zella", "ai_receptionist"].includes(appt.metadata?.source);

  // History from the booking's own timestamps (Zella keeps no separate log of every status change).
  const history = [
    [appt.created_at, byAi ? "Booked by Zella" : appt.metadata?.source === "staff" ? "Booked by the team" : "Booked"],
    appt.original_start_time && [appt.rescheduled_at, `Moved from ${formatLongDate(appt.original_start_time, tz)} ${formatTime(appt.original_start_time, tz)}${appt.reschedule_requested_by === "ai" ? " (asked by phone)" : ""}`],
    appt.checked_in_at && [appt.checked_in_at, cfg.arrived],
    appt.cancelled_at && [appt.cancelled_at, `Canceled${appt.cancel_reason ? `: ${appt.cancel_reason}` : ""}`],
    appt.status === "completed" && [appt.updated_at, "Completed"],
    appt.status === "no_show" && [appt.updated_at, "No-show"],
  ].filter((x) => x && x[0]).sort((a, b) => new Date(a[0]) - new Date(b[0]));

  const box = (
    <div className="bp-backdrop" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <aside className="bp-panel" role="dialog" aria-modal="true" aria-label={`${oneWord} details`} tabIndex={-1} ref={panel}>
        <header className="bp-head">
          <div>
            <small>{oneWord} #{ref(appt.id)}</small>
            <h2>{name ?? appt.title}</h2>
            <p>{formatLongDate(appt.start_time, tz)} · {formatTime(appt.start_time, tz)}{appt.end_time ? ` to ${formatTime(appt.end_time, tz)}` : ""}</p>
          </div>
          <button type="button" className="ba-btn ghost sm" onClick={onClose} aria-label="Close"><Icon name="close" size="sm" /></button>
        </header>

        <div className="bp-body">
          {error && <div className="ba-banner error">{error}</div>}
          {appt.conflict_note && <div className="ba-banner error"><span><strong>Needs rearranging.</strong> {appt.conflict_note}</span></div>}
          {tentative && <div className="ba-banner"><span><strong>Held, not confirmed.</strong> Held until {formatTime(appt.hold_expires_at, tz)} while the customer decides.</span></div>}
          {planned && open && (
            <div className="ba-banner" data-planned="true">
              <span><strong>Planned visit.</strong> Booked from a recurring plan and holding the time. Nothing has been sent to the customer. Confirm it once it's agreed.</span>
              {canWrite && open && <button type="button" className="ba-btn primary sm" disabled={busy}
                onClick={async () => {
                  // confirm only if it's still an open planned visit (another person may have changed it meanwhile)
                  setBusy(true); setError("");
                  let res;
                  try {
                    res = await changed(supabase.from("appointments")
                      .update({ booking_state: "confirmed", status: "confirmed", updated_at: new Date().toISOString() })
                      .eq("id", appt.id).eq("booking_state", "tentative").in("status", ["scheduled", "confirmed"]));
                  } catch (e) { res = { error: e }; } finally { setBusy(false); }
                  if (res.error?.message === "NOT_CHANGED") { onNotice("Nothing was confirmed: this visit changed meanwhile (it may have been canceled). The calendar has been refreshed."); onChanged(); return; }
                  if (res.error) { setError(friendly(res.error)); return; }
                  onNotice("Visit confirmed."); onChanged();
                }}>Confirm visit</button>}
            </div>
          )}
          {requested && canWrite && (
            <form className="ba-banner bp-request" onSubmit={confirmRequest}>
              <span><strong>Requested, not booked.</strong> Pick a time to book it.</span>
              <span className="ba-inline-form">
                <input type="date" min={todayInput(tz)} value={confirmForm.date} onChange={(e) => setConfirmForm({ ...confirmForm, date: e.target.value })} aria-label="Day" />
                <input type="time" step="300" value={confirmForm.time} onChange={(e) => setConfirmForm({ ...confirmForm, time: e.target.value })} aria-label="Time" />
                <select value={confirmForm.minutes} onChange={(e) => setConfirmForm({ ...confirmForm, minutes: e.target.value })} aria-label="Length">
                  {["15", "30", "45", "60", "90", "120"].map((m) => <option key={m} value={m}>{m} min</option>)}
                </select>
                <button type="submit" className="ba-btn primary sm" disabled={busy}>Confirm booking</button>
              </span>
            </form>
          )}

          <Section title={`${oneWord} details`}>
            <dl className="bp-rows">
              <Row label="Reference">#{ref(appt.id)}</Row>
              <Row label="Status">
                <Pill tone={APPT_TONE[appt.status]}>{APPT_LABEL[appt.status] ?? appt.status}</Pill>
                {requested && <Pill tone="warning">Requested</Pill>}{tentative && <Pill tone="warning">Held</Pill>}{planned && <Pill tone="warning">Planned</Pill>}{arrived && open && <Pill tone="success">{cfg.arrived}</Pill>}
              </Row>
              <Row label="Duration">{mins(appt) ? `${mins(appt)} min` : null}</Row>
              <Row label="Booking">{appt.title}</Row>
              {bookingFields(industry, term("staff")).filter(([, key]) => key !== "staff" && key !== "notes").map(([label, key]) => (
                <Row key={key} label={label}>{fieldValue(key, appt, person, staffName)}</Row>
              ))}
              <Row label="Booked by">{byAi ? <><Icon name="smart_toy" size="sm" /> Zella (AI receptionist or online)</> : appt.metadata?.source === "staff" ? "Your team" : null}</Row>
            </dl>
          </Section>

          <BookingFor workspace={workspace} appt={appt} canWrite={canWrite} onChanged={onChanged} onNotice={onNotice} />

          <Section title={term("customer")}>
            {person ? (
              <dl className="bp-rows">
                <Row label="Name"><button type="button" className="ba-namebtn" onClick={() => onOpenPerson(person.id)}>{name}</button></Row>
                <Row label="Phone">{person.phone ? <a className="ba-link" href={`tel:${person.phone}`}>{person.phone}</a> : null}</Row>
                <Row label="Email">{person.email ? <a className="ba-link" href={`mailto:${person.email}`}>{person.email}</a> : null}</Row>
              </dl>
            ) : <p className="ba-muted">No {term("customer").toLowerCase()} linked to this {oneWord.toLowerCase()}.</p>}
            {person && <button type="button" className="ba-btn sm" onClick={() => onOpenPerson(person.id)}><Icon name="person" size="sm" />Open profile</button>}
          </Section>

          {showAssignment && <Section title="Assignment">
            <dl className="bp-rows">
              <Row label={term("staff")}>{member?.name ?? "Unassigned"}</Row>
              <Row label="Availability">{availability ? availability.label : null}</Row>
              <Row label="Assignment">{appt.staff_id ? <Pill tone="success">Assigned</Pill> : <Pill tone="warning">Needs assigning</Pill>}</Row>
            </dl>
          </Section>}

          <Section title="Messages">
            <BookingMessages workspace={workspace} appt={appt} tz={tz} term={term} />
          </Section>

          <Section title="Activity">
            {appt.description && <p className="ba-note pre bp-notes">{appt.description}</p>}
            {appt.internal_notes && <p className="ba-note pre bp-notes"><strong>Team note:</strong> {appt.internal_notes}</p>}
            <ul className="bp-feed">
              {(activity?.calls ?? []).map((c) => (
                <li key={`c${c.id}`}><Icon name={c.status === "missed" ? "phone_missed" : "call"} size="sm" />
                  <span>{c.status === "missed" ? "Missed call" : !isAnswered(c.status) ? `Call: ${callResult(c.status).label.toLowerCase()}` : c.ai_handled ? "Call answered by AI" : "Call"}{c.summary ? `: ${c.summary.slice(0, 80)}` : ""}</span><time>{timeAgo(c.created_at)}</time></li>
              ))}
              {(activity?.convos ?? []).map((c) => (
                <li key={`m${c.id}`}><Icon name={c.channel === "email" ? "mail" : "sms"} size="sm" />
                  <span>{c.subject || `${c.channel ?? "Message"} conversation`}{c.ai_handled ? " · AI" : ""}</span><time>{c.last_message_at ? timeAgo(c.last_message_at) : ""}</time></li>
              ))}
              {history.map(([at, text]) => (
                <li key={`h${text}`}><Icon name="history" size="sm" /><span>{text}</span><time>{timeAgo(at)}</time></li>
              ))}
            </ul>
            {activity && !activity.calls.length && !activity.convos.length && <p className="ba-muted">No calls or messages with this {term("customer").toLowerCase()} yet.</p>}
          </Section>

          {editing && <EditBooking appt={appt} staff={staff} cfg={cfg} industry={industry} term={term} busy={busy}
            onCancel={() => setEditing(false)}
            onSave={(row) => run(() => changed(supabase.from("appointments").update({ ...row, updated_at: new Date().toISOString() }).eq("id", appt.id)), `${oneWord} updated.`).then((ok) => ok && setEditing(false))} />}
        </div>

        {canWrite ? (
          <footer className="bp-foot">
            {person?.phone && <a className="ba-btn" href={`tel:${person.phone}`}><Icon name="call" size="sm" />Call</a>}
            {person?.phone && !person.do_not_sms && <a className="ba-btn" href={`sms:${person.phone}`}><Icon name="sms" size="sm" />Text</a>}
            {!editing && !requested && <button type="button" className="ba-btn" disabled={busy} onClick={() => setEditing(true)}><Icon name="edit" size="sm" />Edit</button>}
            {["scheduled", "confirmed", "no_show"].includes(appt.status) && !requested && <button type="button" className="ba-btn" disabled={busy} onClick={() => setMoving(true)}><Icon name="event_repeat" size="sm" />Reschedule</button>}
            {appt.status === "scheduled" && !requested && <button type="button" className="ba-btn" disabled={busy} onClick={() => setStatus("confirmed")}><Icon name="check" size="sm" />Confirm</button>}
            {open && <button type="button" className="ba-btn" disabled={busy} onClick={() => run(() => setCheckIn(appt.id, !appt.checked_in_at), appt.checked_in_at ? "Undone." : `${name ?? "Guest"}: ${cfg.arrived.toLowerCase()}.`)}>
              <Icon name={appt.checked_in_at ? "undo" : "how_to_reg"} size="sm" />{appt.checked_in_at ? `Undo ${cfg.arrived.toLowerCase()}` : cfg.arrived}</button>}
            {open && <button type="button" className="ba-btn primary" disabled={busy} onClick={() => setStatus("completed")}><Icon name="task_alt" size="sm" />Mark completed</button>}
            {open && new Date(appt.start_time) < new Date() && !arrived && <button type="button" className="ba-btn danger-outline" disabled={busy} onClick={() => setStatus("no_show")}>No-show</button>}
            {(open || requested) && <button type="button" className="ba-btn danger-outline" disabled={busy} onClick={() => setStatus("cancelled")}>Cancel</button>}
          </footer>
        ) : <footer className="bp-foot"><span className="ba-muted">Your role can view {term("appointments").toLowerCase()} but not change them.</span></footer>}
      </aside>
    </div>
  );
  const host = typeof document !== "undefined" ? document.querySelector(".ba-root") : null;
  return (
    <>
      {host ? createPortal(box, host) : box}
      {moving && <RescheduleModal workspace={workspace} term={term} appt={appt} person={person} onClose={() => setMoving(false)} onSaved={(m) => { setMoving(false); onNotice(m); onChanged(); }} />}
    </>
  );
}

// Edit the booking's details. Time changes go through Reschedule, which checks the schedule.
function EditBooking({ appt, staff, cfg, industry, term, busy, onCancel, onSave }) {
  const fields = bookingFields(industry, term("staff")).map(([, key]) => key);
  const [form, setForm] = useState({
    title: appt.title ?? "", appointment_type: appt.appointment_type ?? "", staff_id: appt.staff_id ?? "", party_size: appt.party_size ?? "",
    location: appt.location ?? "", description: appt.description ?? "", internal_notes: appt.internal_notes ?? "",
  });
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });
  const label = (key, fallback) => bookingFields(industry, term("staff")).find(([, k]) => k === key)?.[0] ?? fallback;
  function save(event) {
    event.preventDefault();
    const size = form.party_size === "" ? null : Number(form.party_size);
    onSave({
      title: form.title.trim() || appt.title, appointment_type: form.appointment_type.trim() || null, staff_id: form.staff_id || null,
      party_size: Number.isInteger(size) && size > 0 && size <= 500 ? size : null, location: form.location.trim() || null,
      description: form.description.trim() || null, internal_notes: form.internal_notes.trim() || null,
    });
  }
  return (
    <form className="bp-section bp-edit" onSubmit={save}>
      <h3>Edit details</h3>
      <div className="ba-form-grid">
        <Field label="Booking" full><input value={form.title} onChange={set("title")} maxLength={120} /></Field>
        {fields.includes("type") && <Field label={label("type", "Type")}><input value={form.appointment_type} onChange={set("appointment_type")} maxLength={80} /></Field>}
        {staff.length > 0 && <Field label={term("staff")}><select value={form.staff_id} onChange={set("staff_id")}><option value="">Unassigned</option>{staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></Field>}
        {(cfg.guests || fields.includes("party_size")) && <Field label={label("party_size", "Guests")}><input type="number" min="1" max="500" value={form.party_size} onChange={set("party_size")} /></Field>}
        {(fields.includes("location") || fields.includes("address")) && <Field label={label("location", label("address", "Where"))}><input value={form.location} onChange={set("location")} maxLength={200} /></Field>}
        <Field label={label("notes", "Notes")} full><textarea rows={3} value={form.description} onChange={set("description")} maxLength={2000} /></Field>
        <Field label="Team note (not sent to the customer)" full><textarea rows={2} value={form.internal_notes} onChange={set("internal_notes")} maxLength={2000} /></Field>
      </div>
      <div className="ba-form-actions">
        <button type="button" className="ba-btn" onClick={onCancel} disabled={busy}>Cancel</button>
        <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Save details"}</button>
      </div>
    </form>
  );
}
