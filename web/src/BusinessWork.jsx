import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { PhoneField } from "./formFields";
import { validatePhone } from "./formValidation";
import { noteIcon, pickQuiet, voiceTitle } from "./zellaVoice";
import { chime, desktopAlert, deviceAlerts, tabCount } from "./liveAlerts";
import { Empty, Notice, PageHead, Segment, explain, loadPeople, orThrow, plural, useLoad } from "./BusinessShared";

/* ------------------------------------------------------------------ */
/* Shared bits                                                         */
/* ------------------------------------------------------------------ */

export const PRIORITY_TONE = { urgent: "danger", high: "warning", normal: "" };
export const when = (value, tz) => (value ? `${formatDay(value, tz)} · ${formatTime(value, tz)}` : "—");

export function PersonPicker({ label = "Person", value, onChange, hint }) {
  const [query, setQuery] = useState("");
  const [rows, setRows] = useState([]);
  useEffect(() => {
    const text = query.trim();
    if (text.length < 2) { setRows([]); return undefined; }
    let live = true;
    const safe = text.replace(/[%,()*]/g, " ");
    const timer = setTimeout(async () => {
      const { data } = await supabase.from("customers").select("id, first_name, last_name, company_name, phone, email")
        .or(`first_name.ilike.*${safe}*,last_name.ilike.*${safe}*,phone.ilike.*${safe}*,email.ilike.*${safe}*`).limit(6);
      if (live) setRows(data ?? []);
    }, 250);
    return () => { live = false; clearTimeout(timer); };
  }, [query]);

  if (value) {
    return (
      <Field label={label}>
        <div className="ba-status-row">
          <strong>{personName(value) ?? value.phone}</strong>
          <button type="button" className="ba-btn sm" onClick={() => onChange(null)}>Change</button>
        </div>
      </Field>
    );
  }
  return (
    <Field label={label} hint={hint ?? "Search by name, phone or email."}>
      <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Start typing…" />
      {rows.length > 0 && (
        <ul className="ba-picklist">
          {rows.map((p) => (
            <li key={p.id}><button type="button" onClick={() => onChange(p)}>{personName(p) ?? "Unnamed"}<small>{p.phone ?? p.email ?? ""}</small></button></li>
          ))}
        </ul>
      )}
    </Field>
  );
}

function useAction(onNotice, reload, onChanged) {
  const [working, setWorking] = useState(null);
  const [error, setError] = useState("");
  async function run(key, work, message) {
    setWorking(key);
    setError("");
    const { error: failure } = await work();
    setWorking(null);
    if (failure) { setError(explain(failure)); return false; }
    if (message) onNotice?.(message);
    reload?.();
    onChanged?.();
    return true;
  }
  return { working, error, setError, run };
}

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

export const CB_REASON = {
  missed_call: "Missed call", new_lead: "New lead", requested: "Asked for a call back", needs_human: "Needs a person",
  transfer_failed: "Transfer didn't connect", appointment_request: "Appointment request", booking_failed: "Booking failed", after_hours: "After hours", other: "Call back",
};
export const CB_STATUS = {
  new: ["New", ""], scheduled: ["Scheduled", "warning"], due: ["Due", "warning"], in_progress: ["In progress", "info"], contacted: ["Reached", "success"],
  reschedule_requested: ["Reschedule requested", "warning"], retry_scheduled: ["Will retry", "warning"], waiting_on_customer: ["Waiting on them", ""],
  completed: ["Done", "success"], cancelled: ["Cancelled", ""], escalated: ["Escalated", "danger"], needs_review: ["Needs a person", "danger"],
};
export const CB_CLOSED = ["completed", "cancelled"];
export const ATTEMPT_LABEL = { connected: "Reached them", no_answer: "No answer", busy: "Busy", voicemail: "Voicemail", invalid_number: "Number not working", failed_connection: "Call failed", declined: "Declined" };

export function NewCallbackModal({ workspace, onClose, onSaved }) {
  const [person, setPerson] = useState(null);
  const [form, setForm] = useState({ phone: "", note: "", date: "", time: "", priority: "normal" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });
  const tz = workspace.timezone;

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    const phone = (person?.phone ?? form.phone).trim();
    if (!phone) return setError("Add a phone number.");
    if (!person && validatePhone(phone, { required: true })) return setError(`Phone: ${validatePhone(phone, { required: true })}`);
    setBusy(true);
    const when_ = form.date && form.time ? zonedDateTime(form.date, form.time, tz).toISOString() : null;
    const { error: failure } = await supabase.rpc("zella_staff_create_callback", {
      p_business_id: workspace.id, p_contact_number: phone, p_summary: form.note.trim() || null, p_preferred_at: when_, p_customer_id: person?.id ?? null, p_priority: form.priority,
    });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onSaved("Callback added.");
  }

  return (
    <Modal title="Add a callback" description="Someone who needs a call back." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-new-callback" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Add callback"}</button></>}>
      <form id="ba-new-callback" className="ba-modal-body" onSubmit={save}>
        {error && <p className="ba-error" role="alert">{error}</p>}
        <PersonPicker label="Who" value={person} onChange={setPerson} hint="Optional. Or type a number below." />
        <div className="ba-form-grid">
          {!person && <Field label="Phone" bare><PhoneField value={form.phone} onChange={(phone) => setForm((f) => ({ ...f, phone }))} required showErrors={showErrors} label="Phone" /></Field>}
          <Field label="Priority"><select value={form.priority} onChange={set("priority")}><option value="normal">Normal</option><option value="high">High</option><option value="urgent">Urgent</option></select></Field>
          <Field label="Best day" hint="Optional."><input type="date" min={todayInput(tz)} value={form.date} onChange={set("date")} /></Field>
          <Field label="Best time"><input type="time" value={form.time} onChange={set("time")} /></Field>
          <Field label="What is it about?" full><textarea rows={3} value={form.note} onChange={set("note")} /></Field>
        </div>
      </form>
    </Modal>
  );
}

/* ------------------------------------------------------------------ */
/* Tasks (and possible duplicates)                                     */
/* ------------------------------------------------------------------ */

const TASK_KIND = {
  follow_up: "Follow up", overdue_contact: "Lead not contacted", duplicate_review: "Possible duplicate", onboarding: "Onboarding", quote_review: "Open quote",
  staff_unavailable: "Staff unavailable", appointment_request: "Appointment request", reactivation: "Win back", other: "Task",
};

function NewTaskModal({ workspace, onClose, onSaved }) {
  const [person, setPerson] = useState(null);
  const [form, setForm] = useState({ title: "", date: "", time: "", priority: "normal" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });
  async function save(event) {
    event.preventDefault();
    if (!form.title.trim()) return setError("Give it a short title.");
    setBusy(true);
    const due = form.date ? zonedDateTime(form.date, form.time || "09:00", workspace.timezone).toISOString() : null;
    const { error: failure } = await supabase.rpc("zella_staff_create_task", { p_business_id: workspace.id, p_customer_id: person?.id ?? null, p_title: form.title, p_due_at: due, p_priority: form.priority });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onSaved("Task added.");
  }
  return (
    <Modal title="Add a task" onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button><button type="submit" form="ba-new-task" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Add task"}</button></>}>
      <form id="ba-new-task" className="ba-modal-body" onSubmit={save}>
        {error && <p className="ba-error" role="alert">{error}</p>}
        <div className="ba-form-grid">
          <Field label="What needs doing?" full><input value={form.title} onChange={set("title")} autoFocus /></Field>
          <Field label="Due day"><input type="date" min={todayInput(workspace.timezone)} value={form.date} onChange={set("date")} /></Field>
          <Field label="Time"><input type="time" value={form.time} onChange={set("time")} /></Field>
          <Field label="Priority"><select value={form.priority} onChange={set("priority")}><option value="normal">Normal</option><option value="high">High</option><option value="urgent">Urgent</option></select></Field>
        </div>
        <PersonPicker label="About (optional)" value={person} onChange={setPerson} />
      </form>
    </Modal>
  );
}

export function TasksPage({ workspace, refreshKey, onNotice, onOpenPerson, onChanged }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("open");
  const [adding, setAdding] = useState(false);
  const { data, error, loading, reload } = useLoad(async () => {
    const tasks = orThrow(await supabase.from("crm_tasks").select("*").eq("business_id", workspace.id).order("due_at", { ascending: true, nullsFirst: false }).limit(300));
    const dups = orThrow(await supabase.from("duplicate_reviews").select("*").eq("business_id", workspace.id).eq("status", "open").order("created_at", { ascending: false }).limit(50));
    return { tasks, dups, people: await loadPeople([...tasks.map((t) => t.customer_id), ...dups.map((d) => d.customer_id)]) };
  }, [workspace.id, refreshKey]);
  const { working, error: actionError, run } = useAction(onNotice, reload, onChanged);

  const tasks = data?.tasks ?? [];
  const open = tasks.filter((t) => t.status === "open");
  const shown = filter === "open" ? open : tasks.filter((t) => t.status !== "open").sort((a, b) => new Date(b.completed_at ?? b.created_at) - new Date(a.completed_at ?? a.created_at));
  const dups = data?.dups ?? [];
  const now = Date.now();

  return (
    <>
      <PageHead crumb="Workspace / Tasks & Follow-ups" title="Tasks" sub={open.length ? `${plural(open.length, "thing")} to do.` : "Nothing waiting. Zella adds tasks when a lead needs contacting, a quote is open or a booking needs rearranging."}>
        <button type="button" className="ba-btn primary" onClick={() => setAdding(true)}><Icon name="add_task" size="sm" />Add task</button>
        <Segment label="Task filter" value={filter} onChange={setFilter} options={[["open", `To do (${open.length})`], ["done", "Done"]]} />
      </PageHead>
      <Notice error={error || actionError} onRetry={reload} />

      {dups.length > 0 && filter === "open" && (
        <section className="ba-panel">
          <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Possible duplicates ({dups.length})</h2><p className="ba-muted">Zella found a match it wasn't sure about, so it created nothing. You decide.</p></div></div></div>
          <div className="ba-panel-body ba-stack">
            {dups.map((d) => {
              const existing = data.people[d.customer_id];
              const inc = d.incoming ?? {};
              return (
                <div key={d.id} className="ba-dup">
                  <div><small>Already in your list</small><strong>{personName(existing) ?? "Unnamed"}</strong><span className="ba-muted">{existing?.phone ?? ""} {existing?.email ?? ""}</span></div>
                  <div><small>New enquiry</small><strong>{[inc.first_name, inc.last_name].filter(Boolean).join(" ") || "Unnamed"}</strong><span className="ba-muted">{inc.phone ?? ""} {inc.email ?? ""}</span></div>
                  <div className="ba-form-actions wrap">
                    {d.customer_id && <button type="button" className="ba-btn primary sm" disabled={working === `m-${d.id}`} onClick={() => run(`m-${d.id}`, () => supabase.rpc("zella_resolve_duplicate", { p_review_id: d.id, p_action: "merge" }), "Added to the existing record.")}>Same person: merge</button>}
                    <button type="button" className="ba-btn sm" disabled={working === `m-${d.id}`} onClick={() => run(`m-${d.id}`, () => supabase.rpc("zella_resolve_duplicate", { p_review_id: d.id, p_action: "keep_separate" }), "Added as a new person.")}>Different person</button>
                    <button type="button" className="ba-btn sm" disabled={working === `m-${d.id}`} onClick={() => run(`m-${d.id}`, () => supabase.rpc("zella_resolve_duplicate", { p_review_id: d.id, p_action: "dismiss" }), "Dismissed.")}>Dismiss</button>
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {loading && !data ? <p className="ba-muted">Loading…</p> : !shown.length ? (
        <Empty title={filter === "open" ? "All caught up" : "Nothing done yet"}>{filter === "open" ? "New tasks show up here." : "Finished tasks are kept here."}</Empty>
      ) : (
        <div className="ba-stack">
          {shown.map((t) => {
            const person = data.people[t.customer_id];
            const late = t.status === "open" && t.due_at && new Date(t.due_at).getTime() < now;
            return (
              <article key={t.id} className="ba-panel">
                <div className="ba-panel-body">
                  <div className="ba-kn-head">
                    <strong>{t.title}</strong>
                    <Pill>{TASK_KIND[t.kind] ?? "Task"}</Pill>
                    {t.priority !== "normal" && <Pill tone={PRIORITY_TONE[t.priority]}>{t.priority === "urgent" ? "Urgent" : "High"}</Pill>}
                    {late && <Pill tone="danger">Overdue</Pill>}
                    {t.escalated_at && <Pill tone="danger">Escalated</Pill>}
                  </div>
                  {t.body && <p className="ba-item-text">{t.body}</p>}
                  <p className="ba-muted">
                    {t.status === "open" ? (t.due_at ? `Due ${when(t.due_at, tz)}` : "No due time") : `${t.status === "done" ? "Done" : "Cancelled"} ${timeAgo(t.completed_at ?? t.created_at)}`}
                    {person && <> · <button type="button" className="ba-link" onClick={() => onOpenPerson(person.id)}>{personName(person)}</button></>}
                  </p>
                  {t.status === "open" && (
                    <div className="ba-form-actions">
                      <button type="button" className="ba-btn primary sm" disabled={working === t.id} onClick={() => run(t.id, () => supabase.rpc("zella_complete_task", { p_task_id: t.id }), "Task done.")}>Mark done</button>
                      <button type="button" className="ba-btn sm" disabled={working === t.id} onClick={() => run(t.id, () => supabase.rpc("zella_complete_task", { p_task_id: t.id, p_cancel: true }), "Task dismissed.")}>Dismiss</button>
                    </div>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      )}
      {adding && <NewTaskModal workspace={workspace} onClose={() => setAdding(false)} onSaved={(m) => { setAdding(false); onNotice(m); reload(); onChanged?.(); }} />}
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Waitlist                                                            */
/* ------------------------------------------------------------------ */

function JoinWaitlistModal({ workspace, term, onClose, onSaved }) {
  const [person, setPerson] = useState(null);
  const [form, setForm] = useState({ title: "", minutes: "30", from: "", to: "", notes: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const tz = workspace.timezone;
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });
  async function save(event) {
    event.preventDefault();
    if (!person) return setError(`Choose the ${term("customer").toLowerCase()}.`);
    setBusy(true);
    const { error: failure } = await supabase.rpc("zella_join_waitlist", {
      p_business_id: workspace.id, p_customer_id: person.id, p_title: form.title.trim() || null, p_duration_minutes: Number(form.minutes) || 30,
      p_earliest: form.from ? zonedDateTime(form.from, "00:00", tz).toISOString() : null,
      p_latest: form.to ? zonedDateTime(form.to, "23:59", tz).toISOString() : null, p_staff_id: null, p_notes: form.notes.trim() || null,
    });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onSaved("Added to the waitlist.");
  }
  return (
    <Modal title="Add to the waitlist" description="If a time opens up, Zella can offer it to them." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button><button type="submit" form="ba-waitlist" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Add to waitlist"}</button></>}>
      <form id="ba-waitlist" className="ba-modal-body" onSubmit={save}>
        {error && <p className="ba-error" role="alert">{error}</p>}
        <PersonPicker label={term("customer")} value={person} onChange={setPerson} />
        <div className="ba-form-grid">
          <Field label="For what?"><input value={form.title} onChange={set("title")} placeholder="e.g. Cleaning" /></Field>
          <Field label="How long (minutes)"><input type="number" min="5" step="5" value={form.minutes} onChange={set("minutes")} /></Field>
          <Field label="Any time from"><input type="date" min={todayInput(tz)} value={form.from} onChange={set("from")} /></Field>
          <Field label="Until"><input type="date" min={form.from || todayInput(tz)} value={form.to} onChange={set("to")} /></Field>
          <Field label="Notes" full><textarea rows={2} value={form.notes} onChange={set("notes")} /></Field>
        </div>
      </form>
    </Modal>
  );
}

export function WaitlistPage({ workspace, term, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("active");
  const [adding, setAdding] = useState(false);
  const { data, error, loading, reload } = useLoad(async () => {
    const rows = orThrow(await supabase.from("waitlist_entries").select("*").eq("business_id", workspace.id).order("created_at", { ascending: true }).limit(300));
    return { rows, people: await loadPeople(rows.map((r) => r.customer_id)) };
  }, [workspace.id, refreshKey]);
  const { working, error: actionError, run } = useAction(onNotice, reload);
  const rows = data?.rows ?? [];
  const active = rows.filter((r) => r.status === "waiting" || r.status === "offered");
  const shown = filter === "active" ? active : rows.filter((r) => r.status === "booked" || r.status === "removed");

  return (
    <>
      <PageHead crumb="Workspace / Waitlist" title="Waitlist" sub="People who want an earlier time. When someone cancels, Zella can offer the opening to the next person. Nothing is booked until they say yes.">
        <button type="button" className="ba-btn primary" onClick={() => setAdding(true)}><Icon name="playlist_add" size="sm" />Add to waitlist</button>
        <Segment label="Waitlist filter" value={filter} onChange={setFilter} options={[["active", `Waiting (${active.length})`], ["past", "Booked or removed"]]} />
      </PageHead>
      <Notice error={error || actionError} onRetry={reload} />
      {loading && !data ? <p className="ba-muted">Loading…</p> : !shown.length ? (
        <Empty title={filter === "active" ? "Nobody is waiting" : "Nothing here yet"}>{filter === "active" ? `Add ${term("customers").toLowerCase()} who'd take an earlier time.` : "Booked and removed entries are kept here."}</Empty>
      ) : (
        <div className="ba-stack">
          {shown.map((w) => {
            const person = data.people[w.customer_id];
            return (
              <article key={w.id} className="ba-panel">
                <div className="ba-panel-body">
                  <div className="ba-kn-head">
                    <button type="button" className="ba-link strong" onClick={() => person && onOpenPerson(person.id)}>{personName(person) ?? "Unnamed"}</button>
                    <Pill tone={w.status === "offered" ? "warning" : w.status === "booked" ? "success" : ""}>{w.status === "offered" ? "Offer sent" : w.status === "waiting" ? "Waiting" : w.status === "booked" ? "Booked" : "Removed"}</Pill>
                    {w.title && <Pill>{w.title}</Pill>}
                  </div>
                  <p className="ba-muted">
                    {w.duration_minutes} min · added {timeAgo(w.created_at)}
                    {(w.earliest_at || w.latest_at) && ` · ${w.earliest_at ? formatDay(w.earliest_at, tz) : "any time"} to ${w.latest_at ? formatDay(w.latest_at, tz) : "open"}`}
                  </p>
                  {w.status === "offered" && <p className="ba-item-text">Offered {when(w.offered_start, tz)}. Waiting for their answer until {formatTime(w.offer_expires_at, tz)}.</p>}
                  {w.notes && <p className="ba-item-text">{w.notes}</p>}
                  {(w.status === "waiting" || w.status === "offered") && (
                    <div className="ba-form-actions"><button type="button" className="ba-btn sm danger-outline" disabled={working === w.id} onClick={() => run(w.id, () => supabase.rpc("zella_remove_waitlist_entry", { p_id: w.id }), "Removed from the waitlist.")}>Remove</button></div>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      )}
      {adding && <JoinWaitlistModal workspace={workspace} term={term} onClose={() => setAdding(false)} onSaved={(m) => { setAdding(false); onNotice(m); reload(); }} />}
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Notifications bell                                                  */
/* ------------------------------------------------------------------ */

const NOTE_TONE = { urgent: "danger", warning: "warning", info: "" };
const POLL_MS = 20000;

// Pop-ups for notifications that arrive while the CRM is open (urgent ones stay until closed).
function NoteToasts({ toasts, workspace, onOpen, onClose }) {
  useEffect(() => {
    const timers = toasts.filter((t) => t.severity !== "urgent").map((t) => setTimeout(() => onClose(t.id), 7000));
    return () => timers.forEach(clearTimeout);
  }, [toasts, onClose]);
  if (!toasts.length) return null;
  const host = document.querySelector(".ba-root") ?? document.body;
  return createPortal(
    <div className="ba-toasts" role="region" aria-label="New notifications" aria-live="polite">
      {toasts.map((n) => {
        const { icon, tone } = noteIcon(n);
        return (
          <div key={n.id} className={`ba-toast ${tone}`} role={n.severity === "urgent" ? "alert" : "status"}>
            {tone === "celebrate" && <span className="ba-confetti" aria-hidden="true">{Array.from({ length: 10 }, (_, i) => <i key={i} />)}</span>}
            <span className="ba-toast-icon"><Icon name={icon} size="sm" /></span>
            <button type="button" className="ba-toast-main" onClick={() => onOpen(n)}>
              <strong>{voiceTitle(n, workspace)}</strong>
              {n.body && <small>{n.body}</small>}
            </button>
            <button type="button" className="ba-btn ghost sm" aria-label="Dismiss" onClick={() => onClose(n.id)}><Icon name="close" size="sm" /></button>
          </div>
        );
      })}
    </div>, host);
}

export function NotificationsBell({ workspace, onGo }) {
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState([]);
  const [missing, setMissing] = useState(false);
  const [toasts, setToasts] = useState([]);
  const [quiet] = useState(() => pickQuiet());
  const seen = useRef(null);

  async function load() {
    const { data, error } = await supabase.from("staff_notifications").select("*").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(30);
    if (error) { setMissing(true); return; }
    setMissing(false);
    const list = data ?? [];
    // Anything new since the last look (not on the first load) announces itself.
    if (seen.current) {
      const fresh = list.filter((n) => !seen.current.has(n.id) && !n.read_at && Date.now() - new Date(n.created_at).getTime() < 15 * 60000);
      if (fresh.length) {
        const prefs = deviceAlerts();
        if (prefs.popups) setToasts((t) => [...fresh.slice(0, 3).reverse(), ...t].slice(0, 3));
        const top = fresh.find((n) => n.severity === "urgent") ?? fresh[0];
        const { tone } = noteIcon(top);
        if (prefs.sound) chime(tone);
        if (prefs.desktop) desktopAlert(voiceTitle(top, workspace), fresh.length > 1 ? `and ${fresh.length - 1} more` : top.body, () => go(top));
      }
    }
    seen.current = new Set(list.map((n) => n.id));
    setRows(list);
  }
  useEffect(() => {
    seen.current = null;
    load();
    const timer = setInterval(load, POLL_MS);
    const onFocus = () => load();
    window.addEventListener("focus", onFocus);
    return () => { clearInterval(timer); window.removeEventListener("focus", onFocus); tabCount(0); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspace.id]);

  const unread = rows.filter((r) => !r.read_at);
  useEffect(() => { tabCount(unread.length); }, [unread.length]);
  async function markAll() {
    const ids = unread.map((r) => r.id);
    if (!ids.length) return;
    await supabase.rpc("zella_mark_notifications_read", { p_ids: ids });
    load();
  }
  async function go(note) {
    setToasts((t) => t.filter((x) => x.id !== note.id));
    if (!note.read_at) await supabase.rpc("zella_mark_notifications_read", { p_ids: [note.id] });
    setOpen(false);
    if (note.page_key) onGo(note.page_key);
    load();
  }
  const closeToast = useMemo(() => (id) => setToasts((t) => t.filter((x) => x.id !== id)), []);
  if (missing) return null;

  return (
    <div className="ba-bell">
      <button type="button" className={`ba-btn icon ${toasts.length ? "ringing" : ""}`} aria-label={unread.length ? `${unread.length} unread notifications` : "Notifications"} aria-expanded={open} onClick={() => { setOpen(!open); if (!open) load(); }}>
        <Icon name="notifications" />
        {unread.length > 0 && <span className={`ba-count ${unread.some((n) => n.severity === "urgent") ? "urgent" : ""}`}>{unread.length > 9 ? "9+" : unread.length}</span>}
      </button>
      {open && (
        <div className="ba-bell-panel" role="dialog" aria-label="Notifications">
          <div className="ba-bell-head"><strong>Notifications</strong>{unread.length > 0 && <button type="button" className="ba-link" onClick={markAll}>Mark all read</button>}</div>
          {!rows.length ? <p className="ba-muted pad">{quiet}</p> : (
            <ul>
              {rows.map((n) => {
                const { icon, tone } = noteIcon(n);
                return (
                  <li key={n.id} className={`${n.read_at ? "" : "unread"} ${n.severity === "urgent" ? "urgent" : ""}`}>
                    <button type="button" onClick={() => go(n)}>
                      <span className={`ba-note-icon ${tone}`}><Icon name={icon} size="sm" /></span>
                      <span className="ba-note-text">
                        <span className="ba-kn-head"><strong>{voiceTitle(n, workspace)}</strong>{n.severity !== "info" && <Pill tone={NOTE_TONE[n.severity]}>{n.severity === "urgent" ? "Urgent" : "Heads up"}</Pill>}</span>
                        {n.body && <small>{n.body}</small>}
                        <small>{timeAgo(n.created_at)}</small>
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
          <div className="ba-bell-foot"><button type="button" className="ba-link" onClick={() => { setOpen(false); onGo("settings/notifications/preferences"); }}>Notification settings</button></div>
        </div>
      )}
      <NoteToasts toasts={toasts} workspace={workspace} onOpen={go} onClose={closeToast} />
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Lead tab for the profile                                            */
/* ------------------------------------------------------------------ */

const STAGES = [["new", "New"], ["contacted", "Contacted"], ["qualified", "Qualified"], ["unqualified", "Not a fit"], ["quote_sent", "Quote sent"], ["won", "Won"], ["lost", "Lost"]];
const STAGE_LABEL = Object.fromEntries(STAGES);
const QUOTE_TONE = { issued: "warning", accepted: "success", declined: "", expired: "" };
const QUOTE_LABEL = { issued: "Open", accepted: "Accepted", declined: "Declined", expired: "Expired" };

export function LeadTab({ person, workspace, onChanged, onNotice }) {
  const tz = workspace.timezone;
  const { data, error, loading, reload } = useLoad(async () => {
    const quotes = orThrow(await supabase.from("quotes").select("*").eq("customer_id", person.id).order("issued_at", { ascending: false }).limit(20));
    const tasks = orThrow(await supabase.from("crm_tasks").select("*").eq("customer_id", person.id).eq("status", "open").order("due_at", { ascending: true, nullsFirst: false }).limit(20));
    const cbs = orThrow(await supabase.from("callbacks").select("*").eq("customer_id", person.id).order("created_at", { ascending: false }).limit(10));
    return { quotes, tasks, cbs };
  }, [person.id]);
  const { working, error: actionError, run } = useAction(onNotice, () => { reload(); onChanged?.(); });
  const [lost, setLost] = useState(false);
  const [reason, setReason] = useState("");
  const [days, setDays] = useState("");
  const [quoteTitle, setQuoteTitle] = useState("");
  const stage = person.lead_stage;
  const answers = Object.entries(person.qualification ?? {});

  const setStage = (s) => run(`s-${s}`, () => supabase.rpc("zella_set_lead_stage", { p_customer_id: person.id, p_stage: s }), `Marked ${STAGE_LABEL[s].toLowerCase()}.`);
  async function markLost(event) {
    event.preventDefault();
    const ok = await run("lost", () => supabase.rpc("zella_set_lead_stage", { p_customer_id: person.id, p_stage: "lost", p_reason: reason, p_reengage_days: days ? Number(days) : null }), "Marked lost. Sales reminders have stopped.");
    if (ok) { setLost(false); setReason(""); setDays(""); }
  }

  return (
    <div className="ba-stack">
      <Notice error={error || actionError} onRetry={reload} />
      <section>
        <h3 className="ba-sub">Where they are</h3>
        <div className="ba-kn-head">
          {stage ? <Pill tone={stage === "won" ? "success" : stage === "lost" ? "danger" : "warning"}>{STAGE_LABEL[stage]}</Pill> : <Pill>Not a lead</Pill>}
          {person.priority && person.priority !== "normal" && <Pill tone={PRIORITY_TONE[person.priority]}>{person.priority === "urgent" ? "Urgent" : "High priority"}</Pill>}
          {person.qualification_result && <Pill tone={person.qualification_result === "qualified" ? "success" : ""}>{person.qualification_result === "qualified" ? "Meets your criteria" : person.qualification_result === "unqualified" ? "Doesn't meet your criteria" : "Questions unanswered"}</Pill>}
          {person.contact_deadline_at && stage === "new" && <Pill tone="warning">Contact by {when(person.contact_deadline_at, tz)}</Pill>}
        </div>
        {stage === "lost" && person.lost_reason && <p className="ba-item-text">Lost: {person.lost_reason}{person.reactivate_after ? ` · Zella may reach out again around ${formatDay(person.reactivate_after, tz)}` : ""}</p>}
        <div className="ba-form-actions wrap">
          {STAGES.filter(([k]) => k !== "lost" && k !== stage && k !== "quote_sent").map(([k, l]) => (
            <button key={k} type="button" className="ba-btn sm" disabled={working === `s-${k}`} onClick={() => setStage(k)}>Mark {l.toLowerCase()}</button>
          ))}
          {stage !== "lost" && <button type="button" className="ba-btn sm danger-outline" onClick={() => setLost(true)}>Mark lost</button>}
        </div>
        {lost && (
          <form className="ba-form-grid" onSubmit={markLost}>
            <Field label="Why was it lost?" full><input value={reason} onChange={(e) => setReason(e.target.value)} autoFocus /></Field>
            <Field label="Reach out again in (days)" hint="Optional. Only if they haven't opted out."><input type="number" min="1" value={days} onChange={(e) => setDays(e.target.value)} /></Field>
            <div className="full ba-form-actions"><button type="submit" className="ba-btn primary sm" disabled={working === "lost" || !reason.trim()}>Save</button><button type="button" className="ba-btn sm" onClick={() => setLost(false)}>Cancel</button></div>
          </form>
        )}
      </section>

      <section>
        <h3 className="ba-sub">Quotes</h3>
        <form className="ba-inline-form" onSubmit={(e) => { e.preventDefault(); if (!quoteTitle.trim()) return; run("quote", () => supabase.rpc("zella_issue_quote", { p_customer_id: person.id, p_title: quoteTitle.trim() }), "Quote recorded. Zella will follow up if that's switched on.").then((ok) => ok && setQuoteTitle("")); }}>
          <input value={quoteTitle} onChange={(e) => setQuoteTitle(e.target.value)} placeholder="What was quoted? e.g. Kitchen repair" aria-label="Quote description" />
          <button type="submit" className="ba-btn sm" disabled={working === "quote"}>Record quote</button>
        </form>
        {loading && !data ? <p className="ba-muted">Loading…</p> : !data?.quotes.length ? <p className="ba-muted">No quotes yet.</p> : (
          <ul className="ba-threads">
            {data.quotes.map((q) => (
              <li key={q.id}>
                <span className="ba-thread-icon"><Icon name="request_quote" size="sm" /></span>
                <div><strong>{q.title}</strong><small>{when(q.issued_at, tz)} · {q.follow_ups_sent} follow-up{q.follow_ups_sent === 1 ? "" : "s"} sent</small></div>
                <div className="ba-thread-meta">
                  <Pill tone={QUOTE_TONE[q.status]}>{QUOTE_LABEL[q.status]}</Pill>
                  {q.status === "issued" && (<>
                    <button type="button" className="ba-btn sm" disabled={working === q.id} onClick={() => run(q.id, () => supabase.rpc("zella_set_quote_status", { p_quote_id: q.id, p_status: "accepted" }), "Quote accepted.")}>Accepted</button>
                    <button type="button" className="ba-btn sm" disabled={working === q.id} onClick={() => run(q.id, () => supabase.rpc("zella_set_quote_status", { p_quote_id: q.id, p_status: "declined" }), "Quote declined.")}>Declined</button>
                  </>)}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      {answers.length > 0 && (
        <section>
          <h3 className="ba-sub">Their answers</h3>
          <dl className="ba-facts pad">{answers.map(([k, v]) => <div key={k}><dt>{k.replace(/_/g, " ")}</dt><dd>{String(v)}</dd></div>)}</dl>
        </section>
      )}

      <section>
        <h3 className="ba-sub">Open to-dos</h3>
        {!data?.tasks.length && !data?.cbs.filter((c) => !CB_CLOSED.includes(c.status)).length ? <p className="ba-muted">Nothing open for them.</p> : (
          <ul className="ba-threads">
            {(data?.tasks ?? []).map((t) => <li key={t.id}><span className="ba-thread-icon"><Icon name="task_alt" size="sm" /></span><div><strong>{t.title}</strong><small>{t.due_at ? `Due ${when(t.due_at, tz)}` : "No due time"}</small></div></li>)}
            {(data?.cbs ?? []).filter((c) => !CB_CLOSED.includes(c.status)).map((c) => <li key={c.id}><span className="ba-thread-icon"><Icon name="phone_callback" size="sm" /></span><div><strong>{CB_REASON[c.reason]}</strong><small>{(CB_STATUS[c.status] ?? [c.status])[0]} · due {when(c.due_at, tz)}</small></div></li>)}
          </ul>
        )}
      </section>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Go-live checklist for the AI Receptionist page                      */
/* ------------------------------------------------------------------ */

export function ActivationCard({ workspace, onNotice, onReload }) {
  const canManage = ["owner", "admin", "manager"].includes(workspace.role);
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: report, error: failure } = await supabase.rpc("zella_activation_report", { p_business_id: workspace.id });
    if (failure) throw failure;
    return report;
  }, [workspace.id]);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  const live = Boolean(data?.live);
  if (error && /does not exist|schema cache|Could not find/i.test(error)) return null;

  async function goLive() {
    setBusy(true);
    setProblem("");
    const { data: report, error: failure } = await supabase.rpc("zella_request_activation", { p_business_id: workspace.id });
    setBusy(false);
    if (failure) return setProblem(explain(failure));
    if (report?.ready) { onNotice("You're live. Your AI receptionist is answering calls."); reload(); await onReload?.(); } else { onNotice("Not ready yet. Finish the items below first."); reload(); }
  }

  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>{live ? "You're live" : "Before you go live"}</h2>
        <p className="ba-muted">{live ? "Your AI receptionist is answering calls." : "Zella goes live only when everything below is done and a test call has passed."}</p></div></div></div>
      <div className="ba-panel-body">
        <Notice error={error} onRetry={reload} />
        {problem && <p className="ba-error" role="alert">{problem}</p>}
        {loading && !data ? <p className="ba-muted">Checking…</p> : (
          <ul className="ba-checklist">
            {(data?.checks ?? []).map((c) => (
              <li key={c.key} className={c.ok ? "ok" : ""}><Icon name={c.ok ? "check_circle" : "radio_button_unchecked"} size="sm" /><span>{c.label}</span></li>
            ))}
          </ul>
        )}
        {!live && (
          <div className="ba-form-actions">
            <button type="button" className="ba-btn primary" disabled={busy || !canManage || !data?.ready} onClick={goLive}>{busy ? "Checking…" : "Go live"}</button>
            <button type="button" className="ba-btn" onClick={reload}>Check again</button>
            {!canManage && <span className="ba-muted">Only an owner or manager can go live.</span>}
          </div>
        )}
      </div>
    </section>
  );
}
