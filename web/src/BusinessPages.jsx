import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { makeTerm, receptionistState } from "./businessWorkspace";
import { dayRange, formatDay, formatLongDate, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import {
  APPT_LABEL, APPT_TONE, Empty, Notice, PAGE_SIZE, PageHead, Pager, Segment, clock, friendly, loadPeople,
  availabilityAt, explain, findConflict, noShowNotice, orThrow, plural, setCheckIn, sourceLabel, useLoad,
} from "./BusinessShared";
import { EscalationControls, Transcript, isOpenEscalation } from "./BusinessProfile";
import { AddCustomerModal, BookAppointmentModal, RescheduleModal } from "./BusinessForms";
import { MonthGrid, TimeGrid, clockText, dayInfo, minutesInto } from "./BusinessCalendar";
import { ActivationCard } from "./BusinessWork";

// The rest of the business app: Leads, People (Patients / Customers / Clients…),
// Calendar, Calls, Messages, AI Receptionist, Automations, Team and Settings.
// Everything is read with the signed-in member's own session, so Row Level
// Security returns this business's records only. Where there is nothing yet,
// each page says so instead of showing made-up numbers.

/* ------------------------------------------------------------------ */
/* Leads and people                                                    */
/* ------------------------------------------------------------------ */

function PeoplePage({ mode, workspace, query, refreshKey, onOpenPerson }) {
  const term = makeTerm(workspace);
  const isLeads = mode === "leads";
  const [filter, setFilter] = useState(isLeads ? "new" : "all");
  const [source, setSource] = useState("all");
  const [page, setPage] = useState(0);
  const [adding, setAdding] = useState(false);
  const [added, setAdded] = useState("");
  const { data, error, loading, reload } = useLoad(async () => {
    return orThrow(await supabase
      .from("customers")
      .select("*")
      .eq("business_id", workspace.id)
      .order("created_at", { ascending: false })
      .limit(1000));
  }, [workspace.id, refreshKey]);

  const rows = useMemo(() => {
    const q = (query ?? "").trim().toLowerCase();
    const cutoff = Date.now() - 30 * 86400000;
    return (data ?? []).filter((p) => {
      if (isLeads) {
        if (new Date(p.created_at).getTime() < cutoff) return false;
        if (filter === "new" && p.last_contacted_at) return false;
        if (filter === "contacted" && !p.last_contacted_at) return false;
      }
      if (source !== "all" && (p.source || "other") !== source) return false;
      if (!q) return true;
      return [personName(p), p.phone, p.email, p.company_name].some((v) => v && v.toLowerCase().includes(q));
    });
  }, [data, filter, source, query, isLeads]);

  useEffect(() => setPage(0), [filter, source, query, mode]);
  const pages = Math.max(1, Math.ceil(rows.length / PAGE_SIZE));
  const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
  const sources = [...new Set((data ?? []).map((p) => p.source || "other"))].sort();
  const noun = isLeads ? "lead" : term("customer").toLowerCase();

  return (
    <>
      <PageHead
        crumb={`Core / ${isLeads ? "Leads" : term("customers")}`}
        title={isLeads ? "Leads" : term("customers")}
        sub={isLeads
          ? "People who reached out in the last 30 days. Follow up with anyone you haven't contacted yet."
          : `Everyone your business has spoken with, with their ${term("appointments").toLowerCase()} and calls.`}
      >
        {isLeads && (
          <Segment label="Lead filter" value={filter} onChange={setFilter} options={[["new", "Needs follow-up"], ["contacted", "Contacted"], ["all", "All"]]} />
        )}
        {!isLeads && workspace.role !== "viewer" && (
          <button type="button" className="ba-btn primary" onClick={() => { setAdded(""); setAdding(true); }}>
            <Icon name="person_add" /><span>Add {term("customer").toLowerCase()}</span>
          </button>
        )}
      </PageHead>
      {added && <div className="ba-banner success" role="status"><span>{added}</span></div>}
      {adding && (
        <AddCustomerModal workspace={workspace} term={term} onClose={() => setAdding(false)} onDone={(res) => {
          setAdding(false);
          setAdded(res?.result === "exists" ? "They're already on file, so nobody new was added. Their profile is open."
            : res?.result === "needs_review" ? "Someone similar is already on file. A duplicate check was added to Tasks."
            : "Added.");
          reload();
          if (res?.customer_id && res.result !== "needs_review") onOpenPerson(res.customer_id);
        }} />
      )}

      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        <div className="ba-toolbar">
          <span className="ba-muted">Use the search box at the top to find someone by name, phone or email.</span>
          <label className="ba-select">
            <span>Source</span>
            <select value={source} onChange={(e) => setSource(e.target.value)}>
              <option value="all">All sources</option>
              {sources.map((s) => <option key={s} value={s}>{sourceLabel(s)}</option>)}
            </select>
          </label>
        </div>

        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !rows.length ? (
          <div className="ba-panel-body">
            <Empty title={query || source !== "all" ? "No matches" : isLeads ? "No leads to follow up" : `No ${term("customers").toLowerCase()} yet`}>
              {query || source !== "all"
                ? "Try a different search or source."
                : isLeads
                  ? "New leads from calls, your website and the team will appear here."
                  : `${term("customers")} appear when someone calls, books or is added by your team.`}
            </Empty>
          </div>
        ) : (
          <>
            <div className="ba-table-wrap">
              <table className="ba-table">
                <thead>
                  <tr><th>Name</th><th>Phone</th><th>Source</th><th>Added</th><th>Last contacted</th><th /></tr>
                </thead>
                <tbody>
                  {visible.map((p) => {
                    const name = personName(p) ?? "Unnamed";
                    return (
                      <tr key={p.id} onClick={() => onOpenPerson(p.id)} tabIndex={0} onKeyDown={(e) => e.key === "Enter" && onOpenPerson(p.id)}>
                        <td>
                          <div className="ba-person">
                            <div className="ba-avatar sm">{initials(name)}</div>
                            <div><strong>{name}</strong><small>{p.email ?? ""}</small>{p.tags?.length > 0 && <span className="ba-tags inline">{p.tags.slice(0, 3).map((t) => <Pill key={t} tone="indigo">{t}</Pill>)}</span>}</div>
                          </div>
                        </td>
                        <td>{p.phone ?? "—"}</td>
                        <td><Pill tone="indigo">{sourceLabel(p.source)}</Pill></td>
                        <td>{timeAgo(p.created_at)}</td>
                        <td>{p.last_contacted_at ? timeAgo(p.last_contacted_at) : <span className="ba-flag">Not yet</span>}</td>
                        <td className="ba-actions" onClick={(e) => e.stopPropagation()}>
                          {p.phone && <a className="ba-btn sm" href={`tel:${p.phone}`} aria-label={`Call ${name}`}><Icon name="call" size="sm" /></a>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <Pager page={page} pages={pages} total={rows.length} onPage={setPage} noun={noun} />
          </>
        )}
      </section>

    </>
  );
}

export { LeadsPage } from "./BusinessLeads";
export const CustomersPage = (props) => <PeoplePage mode="customers" {...props} />;

/* ------------------------------------------------------------------ */
/* Calendar                                                            */
/* ------------------------------------------------------------------ */

function AppointmentDetail({ workspace, appt, person, tz, term, onClose, onChanged, onNotice, onOpenPerson }) {
  const [moving, setMoving] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [confirmForm, setConfirmForm] = useState({ date: todayInput(tz), time: "09:00", minutes: "30" });
  const requested = appt.booking_state === "requested";
  const tentative = appt.booking_state === "tentative";

  // A request is not a booking: the schedule must accept the time first.
  async function confirmRequest(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    const { error: rpcError } = await supabase.rpc("zella_confirm_requested_appointment", {
      p_appointment_id: appt.id, p_start: zonedDateTime(confirmForm.date, confirmForm.time, tz).toISOString(), p_duration_minutes: Number(confirmForm.minutes) || 30, p_staff_id: null,
    });
    setBusy(false);
    if (rpcError) return setError(explain(rpcError));
    onNotice("Booking confirmed. Reminders are set.");
    onChanged();
  }

  async function setStatus(status) {
    setBusy(true);
    setError("");
    const { error: updateError } = await supabase.from("appointments").update({ status, updated_at: new Date().toISOString() }).eq("id", appt.id);
    setBusy(false);
    if (updateError) return setError(friendly(updateError));
    onNotice(status === "no_show"
      ? await noShowNotice(appt.id, personName(person) ?? appt.title, tz)
      : `${appt.title} marked ${APPT_LABEL[status].toLowerCase()}.`);
    onChanged();
  }

  async function toggleCheckIn() {
    setBusy(true);
    setError("");
    const { error: updateError } = await setCheckIn(appt.id, !appt.checked_in_at);
    setBusy(false);
    if (updateError) return setError(friendly(updateError));
    onNotice(appt.checked_in_at ? "Check-in undone." : `${personName(person) ?? "Guest"} checked in.`);
    onChanged();
  }

  const name = personName(person);
  const active = ["scheduled", "confirmed"].includes(appt.status) && !requested;
  const next = ["confirmed", "completed", "no_show", "cancelled"].filter((s) => s !== appt.status);
  return (
    <>
    <Modal
      title={appt.title}
      description={`${formatLongDate(appt.start_time, tz)} · ${formatTime(appt.start_time, tz)} to ${formatTime(appt.end_time, tz)}`}
      onClose={onClose}
      busy={busy}
      footer={
        <>
          {active && (
            <button type="button" className="ba-btn primary" disabled={busy} onClick={toggleCheckIn}>
              <Icon name={appt.checked_in_at ? "undo" : "how_to_reg"} size="sm" />{appt.checked_in_at ? "Undo check-in" : "Check in"}
            </button>
          )}
          {["scheduled", "confirmed", "no_show"].includes(appt.status) && !requested && (
            <button type="button" className="ba-btn" disabled={busy} onClick={() => setMoving(true)}><Icon name="event_repeat" size="sm" />Reschedule</button>
          )}
          {next.map((s) => (
            <button key={s} type="button" className={`ba-btn ${s === "cancelled" || s === "no_show" ? "danger-outline" : ""}`} disabled={busy} onClick={() => setStatus(s)}>
              {s === "confirmed" ? "Confirm" : s === "completed" ? "Mark done" : s === "no_show" ? "No-show" : "Cancel"}
            </button>
          ))}
        </>
      }
    >
      <div className="ba-detail">
        {error && <div className="ba-banner error">{error}</div>}
        {appt.conflict_note && <div className="ba-banner error"><span><strong>Needs rearranging.</strong> {appt.conflict_note} Reschedule it, or check your Tasks for suggested times.</span></div>}
        {tentative && <div className="ba-banner"><span><strong>Held, not confirmed.</strong> This time is held until {formatTime(appt.hold_expires_at, tz)} while the customer decides.</span></div>}
        {requested && (
          <form className="ba-banner" onSubmit={confirmRequest}>
            <span><strong>Requested, not booked.</strong> Zella couldn't confirm a time. Pick one to book it.</span>
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
        <dl className="ba-facts">
          {appt.original_start_time && <div><dt>Moved from</dt><dd>{formatLongDate(appt.original_start_time, tz)} · {formatTime(appt.original_start_time, tz)}{appt.reschedule_requested_by ? ` · asked by ${appt.reschedule_requested_by === "ai" ? "Zella" : appt.reschedule_requested_by}` : ""}</dd></div>}
          <div><dt>Status</dt><dd><Pill tone={APPT_TONE[appt.status]}>{APPT_LABEL[appt.status] ?? appt.status}</Pill>{requested && <Pill tone="warning">Requested</Pill>}{tentative && <Pill tone="warning">Held</Pill>}</dd></div>
          <div><dt>Check-in</dt><dd>{appt.checked_in_at ? <Pill tone="success">Arrived {formatTime(appt.checked_in_at, tz)}</Pill> : "Not arrived"}</dd></div>
          <div>
            <dt>{term("customer")}</dt>
            <dd>{name ? <button type="button" className="ba-namebtn" onClick={() => onOpenPerson(person.id)}>{name}</button> : "Not linked"}</dd>
          </div>
          <div><dt>Phone</dt><dd>{person?.phone ? <a className="ba-link" href={`tel:${person.phone}`}>{person.phone}</a> : "—"}</dd></div>
          <div><dt>Where</dt><dd>{appt.location ?? "—"}</dd></div>
        </dl>
        {appt.description && <p className="ba-note pre">{appt.description}</p>}
      </div>
    </Modal>
    {moving && (
      <RescheduleModal
        workspace={workspace}
        term={term}
        appt={appt}
        person={person}
        onClose={() => setMoving(false)}
        onSaved={(message) => { onNotice(message); onChanged(); }}
      />
    )}
    </>
  );
}

const BLOCK_REASONS = ["Lunch break", "Time off", "Holiday", "Training", "Meeting", "Closed", "Other"];

export function BlockTimeModal({ workspace, staff = [], defaultStaffId = "", defaultDate, onClose, onSaved }) {
  const term = makeTerm(workspace);
  const tz = workspace.timezone;
  const [form, setForm] = useState({
    title: BLOCK_REASONS[0], staffId: defaultStaffId, date: defaultDate, endDate: defaultDate, start: "12:00", end: "13:00", allDay: false, note: "",
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (key) => (e) => setForm({ ...form, [key]: e.target.type === "checkbox" ? e.target.checked : e.target.value });

  async function save(event) {
    event.preventDefault();
    if (!form.date) return setError("Choose a date.");
    let start;
    let end;
    if (form.allDay) {
      if (!form.endDate || form.endDate < form.date) return setError("The last day can't be before the first day.");
      start = zonedDateTime(form.date, "00:00", tz);
      end = new Date(zonedDateTime(form.endDate, "23:59", tz).getTime() + 60000);
    } else {
      if (!form.start || !form.end) return setError("Choose a start and end time.");
      start = zonedDateTime(form.date, form.start, tz);
      end = zonedDateTime(form.date, form.end, tz);
      if (end <= start) return setError("The end time must be after the start time.");
    }
    setBusy(true);
    setError("");
    let userId = null;
    try { userId = (await supabase.auth.getUser())?.data?.user?.id ?? null; } catch { /* saved without a name */ }
    const { error: insertError } = await supabase.from("blocked_times").insert({
      business_id: workspace.id, staff_id: form.staffId || null, title: form.title, reason: form.note.trim() || null,
      start_time: start.toISOString(), end_time: end.toISOString(), all_day: form.allDay, created_by: userId,
    });
    setBusy(false);
    if (insertError) return setError(friendly(insertError));
    onSaved("Time blocked. Nobody can book into it.");
  }

  return (
    <Modal
      title="Block time"
      description={`Times are in ${workspace.name}'s time zone (${tz.replace("_", " ")}). Your AI receptionist won't offer blocked times.${staff.length ? ` Pick a ${term("staff").toLowerCase()} if only they are away.` : ""}`}
      onClose={onClose}
      busy={busy}
    >
      <form className="ba-form-grid ba-modal-body" onSubmit={save}>
        {error && <div className="ba-banner error full">{error}</div>}
        {staff.length > 0 && (
          <Field label="Who is unavailable" full>
            <select value={form.staffId} onChange={set("staffId")}>
              <option value="">Whole business (everyone)</option>
              {staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>
          </Field>
        )}
        <Field label="What for" full>
          <select value={form.title} onChange={set("title")}>{BLOCK_REASONS.map((r) => <option key={r}>{r}</option>)}</select>
        </Field>
        <label className="ba-check full"><input type="checkbox" checked={form.allDay} onChange={set("allDay")} /><span>Whole day (or several days)</span></label>
        <Field label={form.allDay ? "First day" : "Date"}><input type="date" value={form.date} onChange={set("date")} required /></Field>
        {form.allDay ? (
          <Field label="Last day"><input type="date" value={form.endDate} min={form.date} onChange={set("endDate")} required /></Field>
        ) : (
          <>
            <Field label="From"><input type="time" value={form.start} onChange={set("start")} required /></Field>
            <Field label="Until"><input type="time" value={form.end} onChange={set("end")} required /></Field>
          </>
        )}
        <Field label="Note (optional)" full><input value={form.note} onChange={set("note")} placeholder="For example: dentist conference" /></Field>
        <div className="full ba-form-actions">
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Block time"}</button>
        </div>
      </form>
    </Modal>
  );
}

function BlockDetail({ block, who, tz, onClose, onChanged, onNotice }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function remove() {
    setBusy(true);
    const { error: deleteError } = await supabase.from("blocked_times").delete().eq("id", block.id);
    setBusy(false);
    if (deleteError) return setError(friendly(deleteError));
    onNotice("Block removed. The time is open again.");
    onChanged();
  }
  return (
    <Modal
      title={`${block.title}${who ? ` · ${who}` : ""}`}
      description={block.all_day ? `${formatDay(block.start_time, tz)} to ${formatDay(new Date(new Date(block.end_time).getTime() - 60000), tz)}, all day` : `${formatLongDate(block.start_time, tz)} · ${formatTime(block.start_time, tz)} to ${formatTime(block.end_time, tz)}`}
      onClose={onClose}
      busy={busy}
      footer={<button type="button" className="ba-btn danger-outline" disabled={busy} onClick={remove}>Remove block</button>}
    >
      <div className="ba-detail">
        {error && <div className="ba-banner error">{error}</div>}
        <p className="ba-note">{block.reason || "This time is blocked, so nobody can book into it."}</p>
      </div>
    </Modal>
  );
}

const VIEWS = [["day", "Day"], ["week", "Week"], ["month", "Month"]];

export function CalendarPage({ workspace, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const [view, setView] = useState("week");
  const [anchor, setAnchor] = useState(0); // whole days from today
  const [open, setOpen] = useState(null);
  const [openBlock, setOpenBlock] = useState(null);
  const [blocking, setBlocking] = useState(false);
  const [booking, setBooking] = useState(null);
  const [pending, setPending] = useState(null); // a drag that needs "Move anyway?"
  const [moving, setMoving] = useState(false);
  const [who, setWho] = useState("all");

  const a = useMemo(() => dayInfo(dayRange, tz, anchor), [tz, anchor]);
  const { first, count, month } = useMemo(() => {
    if (view === "day") return { first: anchor, count: 1, month: a.m };
    if (view === "week") return { first: anchor - a.dow, count: 7, month: a.m };
    const monthStart = anchor - (a.d - 1);
    const dow = dayInfo(dayRange, tz, monthStart).dow;
    return { first: monthStart - dow, count: 42, month: a.m };
  }, [view, anchor, a, tz]);
  const days = useMemo(() => Array.from({ length: count }, (_, i) => dayInfo(dayRange, tz, first + i)), [tz, first, count]);
  const rangeStart = days[0].start;
  const rangeEnd = days[count - 1].end;

  const { data, error, loading, reload } = useLoad(async () => {
    const appts = orThrow(await supabase.from("appointments").select("*").eq("business_id", workspace.id)
      .gte("start_time", rangeStart.toISOString()).lt("start_time", rangeEnd.toISOString()).order("start_time"));
    // Blocked time and team are optional until the latest Zella update is applied.
    const blockResult = await supabase.from("blocked_times").select("*").eq("business_id", workspace.id)
      .lt("start_time", rangeEnd.toISOString()).gt("end_time", rangeStart.toISOString()).order("start_time");
    const staffResult = await supabase.from("staff_members").select("*").eq("business_id", workspace.id)
      .eq("is_active", true).order("sort_order").order("name");
    return {
      appts,
      staff: staffResult.error ? [] : staffResult.data ?? [],
      blocks: blockResult.error ? [] : blockResult.data ?? [],
      people: await loadPeople(appts.map((x) => x.customer_id)),
    };
  }, [workspace.id, rangeStart.getTime(), rangeEnd.getTime(), refreshKey]);

  const staff = data?.staff ?? [];
  const staffName = Object.fromEntries(staff.map((m) => [m.id, m.name]));
  const people = data?.people ?? {};
  const appts = (data?.appts ?? []).filter((x) => who === "all" || x.staff_id === who);
  const blocks = (data?.blocks ?? []).filter((b) => who === "all" || !b.staff_id || b.staff_id === who);
  const inDay = (list, d) => list.filter((x) => {
    const t = new Date(x.start_time).getTime();
    return t >= d.start.getTime() && t < d.end.getTime();
  });
  const blocksIn = (d, staffId) => blocks.filter((b) =>
    new Date(b.start_time) < d.end && new Date(b.end_time) > d.start && (staffId === undefined || !b.staff_id || b.staff_id === (staffId || null)));

  // Columns of the hour grid.
  const columns = (() => {
    if (view === "month") return [];
    const todayStart = dayRange(tz, 0).start.getTime();
    if (view === "week") {
      return days.map((d) => ({
        key: d.dateStr, title: formatDay(d.start, tz), dayStart: d.start, today: d.start.getTime() === todayStart,
        staffId: undefined, appts: inDay(appts, d), blocks: blocksIn(d),
      }));
    }
    const d = days[0];
    const today = d.start.getTime() === todayStart;
    const dayAppts = inDay(appts, d);
    const shown = who === "all" ? staff : staff.filter((m) => m.id === who);
    if (!shown.length) return [{ key: "all", title: "Everyone", dayStart: d.start, today, staffId: undefined, appts: dayAppts, blocks: blocksIn(d) }];
    const cols = shown.map((m) => ({
      key: m.id, title: m.name, color: m.color, dayStart: d.start, today, staffId: m.id,
      appts: dayAppts.filter((x) => x.staff_id === m.id), blocks: blocksIn(d, m.id),
    }));
    const loose = dayAppts.filter((x) => !x.staff_id || !shown.some((m) => m.id === x.staff_id));
    if (loose.length || who === "all") cols.push({ key: "none", title: "Unassigned", dayStart: d.start, today, staffId: "", appts: loose, blocks: blocksIn(d, "") });
    return cols;
  })();

  // Show the usual working day, and stretch it to fit anything outside it.
  let lo = 7 * 60;
  let hi = 20 * 60;
  columns.forEach((c) => c.appts.forEach((x) => {
    lo = Math.min(lo, minutesInto(x.start_time, c.dayStart));
    hi = Math.max(hi, minutesInto(x.end_time, c.dayStart));
  }));
  const startMin = Math.max(0, Math.floor(lo / 60) * 60);
  const endMin = Math.min(24 * 60, Math.ceil(hi / 60) * 60);

  const shift = (dir) => setAnchor((cur) => {
    if (view === "day") return cur + dir;
    if (view === "week") return cur + dir * 7;
    const info = dayInfo(dayRange, tz, cur);
    const target = new Date(Date.UTC(info.y, info.m - 1 + dir, 1));
    const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
    const day = Math.min(info.d, lastDay);
    return cur + (Date.UTC(target.getUTCFullYear(), target.getUTCMonth(), day) - Date.UTC(info.y, info.m - 1, info.d)) / 86400000;
  });

  const title = view === "day"
    ? formatLongDate(days[0].start, tz)
    : view === "week"
      ? `${formatDay(days[0].start, tz)} to ${formatDay(days[6].start, tz)}`
      : new Date(Date.UTC(a.y, a.m - 1, 1)).toLocaleDateString("en-US", { timeZone: "UTC", month: "long", year: "numeric" });
  const total = appts.filter((x) => x.status !== "cancelled").length;
  const now = new Date();
  const dateOfColumn = (c) => days.find((d) => d.start.getTime() === c.dayStart.getTime())?.dateStr;

  function bookAt(colIndex, minute) {
    const c = columns[colIndex];
    setBooking({ date: dateOfColumn(c), time: clockText(minute), staffId: c.staffId ?? (who === "all" ? "" : who) });
  }

  async function applyMove(move) {
    setMoving(true);
    const { appt, start, end, staffId } = move;
    const was = `${new Date(appt.start_time).toLocaleDateString("en-US", { timeZone: tz, month: "short", day: "numeric" })}, ${formatTime(appt.start_time, tz)}`;
    const note = `Rescheduled from ${was}.`;
    const { error: updateError } = await supabase.from("appointments").update({
      start_time: start.toISOString(),
      end_time: end.toISOString(),
      status: "scheduled",
      checked_in_at: null,
      ...(staffId !== (appt.staff_id ?? "") ? { staff_id: staffId || null } : {}),
      description: appt.description ? `${appt.description}\n${note}` : note,
      updated_at: new Date().toISOString(),
    }).eq("id", appt.id);
    setMoving(false);
    setPending(null);
    if (updateError) { onNotice(friendly(updateError)); return; }
    const p = personName(people[appt.customer_id]);
    onNotice(`${appt.title} moved to ${formatDay(start, tz)}, ${formatTime(start, tz)}${p ? ` for ${p}` : ""}.`);
    reload();
  }

  async function dropAppt(appt, colIndex, top) {
    const c = columns[colIndex];
    const start = zonedDateTime(dateOfColumn(c), clockText(top), tz);
    const end = new Date(start.getTime() + (new Date(appt.end_time) - new Date(appt.start_time)));
    const staffId = view === "day" ? c.staffId ?? "" : appt.staff_id ?? "";
    const blockResult = await supabase.from("blocked_times").select("*").eq("business_id", workspace.id)
      .lt("start_time", end.toISOString()).gt("end_time", start.toISOString());
    const message = findConflict({ staff, blocks: blockResult.error ? [] : blockResult.data ?? [], start, end, staffId, timeZone: tz });
    const move = { appt, start, end, staffId, message };
    if (message) setPending(move); else applyMove(move);
  }

  const showWhosIn = view !== "month" && staff.length > 0 && data
    && days.some((d) => d.start.getTime() === dayRange(tz, 0).start.getTime());

  return (
    <>
      <PageHead crumb="Core / Calendar" title="Calendar" sub={`${term("appointments")} · ${title} (${tz.replace("_", " ")})`}>
        <div className="ba-segment" role="group" aria-label="Calendar view">
          {VIEWS.map(([id, label]) => (
            <button key={id} type="button" className={view === id ? "active" : ""} onClick={() => setView(id)}>{label}</button>
          ))}
        </div>
        <div className="ba-segment">
          <button type="button" onClick={() => shift(-1)} aria-label={`Previous ${view}`}><Icon name="chevron_left" size="sm" /></button>
          <button type="button" className={anchor === 0 ? "active" : ""} onClick={() => setAnchor(0)}>Today</button>
          <button type="button" onClick={() => shift(1)} aria-label={`Next ${view}`}><Icon name="chevron_right" size="sm" /></button>
        </div>
        {staff.length > 0 && (
          <label className="ba-select">
            <span>{term("staff")}</span>
            <select value={who} onChange={(e) => setWho(e.target.value)}>
              <option value="all">Everyone</option>
              {staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>
          </label>
        )}
        <button type="button" className="ba-btn" onClick={() => setBlocking(true)}><Icon name="block" size="sm" /><span>Block time</span></button>
        <button type="button" className="ba-btn primary" onClick={() => setBooking({ date: days[0].dateStr, time: "09:00", staffId: who === "all" ? "" : who })}><Icon name="add" size="sm" /><span>Book</span></button>
      </PageHead>

      <Notice error={error} onRetry={reload} />
      {showWhosIn && (
        <div className="ba-whos-in" aria-label="Who is available right now">
          {staff.map((m) => {
            const st = availabilityAt(m, data.blocks, now, tz);
            return (
              <span key={m.id} className={`ba-who ${st.state}`} title={st.label}>
                <i style={{ background: m.color }} />
                <strong>{m.name}</strong>
                <small>{st.label}</small>
              </span>
            );
          })}
        </div>
      )}

      {view === "month" ? (
        <MonthGrid
          tz={tz}
          people={people}
          cells={days.map((d) => ({
            key: d.dateStr, offset: d.offset, d: d.d, inMonth: d.m === month,
            today: d.offset === 0, appts: inDay(appts, d), blocks: blocksIn(d),
          }))}
          onPickDay={(offset) => { setAnchor(offset); setView("day"); }}
          onOpen={setOpen}
        />
      ) : (
        <TimeGrid
          columns={columns} tz={tz} startMin={startMin} endMin={endMin} people={people} staffName={staffName}
          now={now} term={term("appointment")}
          onOpen={setOpen} onOpenBlock={setOpenBlock} onBook={bookAt} onMove={dropAppt}
        />
      )}
      {!loading && data && total === 0 && !blocks.length && (
        <Empty title={`No ${term("appointments").toLowerCase()} here`}>Click an empty time to book one, or let your AI receptionist fill the calendar.</Empty>
      )}

      {open && (
        <AppointmentDetail
          workspace={workspace} appt={open} person={people[open.customer_id]} tz={tz} term={term}
          onClose={() => setOpen(null)}
          onChanged={() => { setOpen(null); reload(); }}
          onNotice={onNotice}
          onOpenPerson={(id) => { setOpen(null); onOpenPerson(id); }}
        />
      )}
      {openBlock && (
        <BlockDetail block={openBlock} who={openBlock.staff_id ? staffName[openBlock.staff_id] : "Whole business"} tz={tz} onClose={() => setOpenBlock(null)} onChanged={() => { setOpenBlock(null); reload(); }} onNotice={onNotice} />
      )}
      {blocking && (
        <BlockTimeModal
          workspace={workspace} staff={staff} defaultStaffId={who === "all" ? "" : who} defaultDate={days[0].dateStr}
          onClose={() => setBlocking(false)}
          onSaved={(message) => { setBlocking(false); onNotice(message); reload(); }}
        />
      )}
      {booking && (
        <BookAppointmentModal
          workspace={workspace} term={term} initial={booking}
          onClose={() => setBooking(null)}
          onSaved={(message) => { setBooking(null); onNotice(message); reload(); }}
        />
      )}
      {pending && (
        <Modal
          title="Move anyway?"
          description={pending.message}
          onClose={() => setPending(null)}
          busy={moving}
          footer={
            <>
              <button type="button" className="ba-btn" onClick={() => setPending(null)} disabled={moving}>Keep it where it was</button>
              <button type="button" className="ba-btn primary" onClick={() => applyMove(pending)} disabled={moving}>{moving ? "Moving..." : "Move anyway"}</button>
            </>
          }
        >
          <p className="ba-note">{pending.appt.title} would move to {formatDay(pending.start, tz)}, {formatTime(pending.start, tz)}.</p>
        </Modal>
      )}
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Calls                                                               */
/* ------------------------------------------------------------------ */

export { CallsPage } from "./BusinessCalls";

/* ------------------------------------------------------------------ */
/* Messages                                                            */
/* ------------------------------------------------------------------ */

const CHANNEL_ICON = { sms: "sms", email: "mail", whatsapp: "chat", chat: "chat", voice: "call", phone: "call" };

export function MessagesPage({ workspace, refreshKey, onOpenPerson }) {
  const [filter, setFilter] = useState("all");
  const { data, error, loading, reload } = useLoad(async () => {
    const rows = orThrow(await supabase
      .from("conversations")
      .select("id, subject, channel, status, last_message_at, customer_id, ai_handled")
      .eq("business_id", workspace.id)
      .order("last_message_at", { ascending: false, nullsFirst: false })
      .limit(200));
    return { rows, people: await loadPeople(rows.map((r) => r.customer_id)) };
  }, [workspace.id, refreshKey]);

  const channels = [...new Set((data?.rows ?? []).map((r) => r.channel).filter(Boolean))];
  const rows = (data?.rows ?? []).filter((r) => filter === "all" || r.channel === filter);
  return (
    <>
      <PageHead crumb="Communications / Messages" title="Messages" sub="Conversations by text and email. Your AI receptionist answers the routine ones.">
        {channels.length > 1 && (
          <Segment label="Channel" value={filter} onChange={setFilter} options={[["all", "All"], ...channels.map((c) => [c, c.toUpperCase() === c ? c : c[0].toUpperCase() + c.slice(1)])]} />
        )}
      </PageHead>
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !rows.length ? (
          <div className="ba-panel-body"><Empty title="No conversations yet">Texts and emails from your {makeTerm(workspace)("customers").toLowerCase()} will appear here.</Empty></div>
        ) : (
          <ul className="ba-threads">
            {rows.map((r) => {
              const name = personName(data.people[r.customer_id]) ?? "Unknown contact";
              return (
                <li key={r.id}>
                  <span className="ba-thread-icon"><Icon name={CHANNEL_ICON[r.channel] ?? "forum"} size="sm" /></span>
                  <div>
                    {r.customer_id ? <button type="button" className="ba-namebtn strong" onClick={() => onOpenPerson(r.customer_id)}>{name}</button> : <strong>{name}</strong>}
                    <small>{r.subject || `${r.channel ?? "Message"} conversation`}</small>
                  </div>
                  <div className="ba-thread-meta">
                    {r.ai_handled && <Pill tone="indigo">AI</Pill>}
                    <Pill tone={r.status === "open" ? "warning" : r.status === "pending" ? "info" : ""}>{r.status}</Pill>
                    <span>{r.last_message_at ? timeAgo(r.last_message_at) : "—"}</span>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* AI Receptionist and automations                                     */
/* ------------------------------------------------------------------ */

export function ReceptionistPage({ workspace, onNotice, onReload }) {
  const tz = workspace.timezone;
  const agent = receptionistState(workspace);
  const { data, error, reload } = useLoad(async () => {
    const week = dayRange(tz, -6).start.toISOString();
    const [agents, calls] = await Promise.all([
      supabase.from("ai_agents").select("id, name, status, description, channels, is_default").eq("business_id", workspace.id).order("is_default", { ascending: false }),
      supabase.from("calls_view").select("id, status, ai_handled, duration_seconds").eq("business_id", workspace.id).gte("created_at", week).limit(1000),
    ]);
    return { agents: orThrow(agents), calls: orThrow(calls) };
  }, [workspace.id]);

  const calls = data?.calls ?? [];
  const aiCalls = calls.filter((c) => c.ai_handled);
  const missed = calls.filter((c) => c.status === "missed").length;
  const primary = data?.agents?.[0];
  const checks = [
    ["Receptionist created", Boolean(workspace.receptionist), "Zella sets this up for you."],
    ["Phone line connected", workspace.phone_connected, "Zella connects your number before going live."],
    ["Voice assistant connected", workspace.voice_connected, "Zella links the voice assistant to your number."],
    ["Receptionist switched on", workspace.receptionist?.status === "active", "It starts answering once everything above is done."],
  ];

  return (
    <>
      <PageHead crumb="AI & Intelligence / AI Receptionist" title={workspace.receptionist?.name ?? "AI receptionist"} sub="Answers your calls, books appointments and adds new people to your CRM.">
        <Pill tone={agent.tone} dot={agent.live} pulse={agent.live}>{agent.label}</Pill>
      </PageHead>
      <Notice error={error} onRetry={reload} />
      <ActivationCard workspace={workspace} onNotice={onNotice ?? (() => {})} onReload={onReload} />
      <div className="ba-grid-2">
        <section className="ba-panel">
          <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Setup status</h2><p>What has to be in place before calls are answered.</p></div></div></div>
          <ul className="ba-checks">
            {checks.map(([label, done, hint]) => (
              <li key={label} className={done ? "done" : ""}>
                <span><Icon name={done ? "check_circle" : "radio_button_unchecked"} size="sm" /></span>
                <div><strong>{label}</strong>{!done && <small>{hint}</small>}</div>
              </li>
            ))}
          </ul>
        </section>
        <section className="ba-panel">
          <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Last 7 days</h2><p>From your recorded calls.</p></div></div></div>
          <dl className="ba-stats">
            <div><dt>Calls</dt><dd>{calls.length}</dd></div>
            <div><dt>Handled by AI</dt><dd>{aiCalls.length}</dd></div>
            <div><dt>Missed</dt><dd>{missed}</dd></div>
            <div><dt>Avg length</dt><dd>{aiCalls.length ? clock(Math.round(aiCalls.reduce((s, c) => s + (c.duration_seconds ?? 0), 0) / aiCalls.length)) : "—"}</dd></div>
          </dl>
          {primary?.description && <p className="ba-note pad">{primary.description}</p>}
          {primary?.channels?.length > 0 && (
            <p className="ba-note pad">Works on: {primary.channels.map((c) => c.replace(/_/g, " ")).join(", ")}</p>
          )}
        </section>
      </div>
      <p className="ba-muted pad-top">To change what your receptionist says or knows, ask the Zella team. Editing from here is coming.</p>
    </>
  );
}

export { AutomationsPage } from "./BusinessControls";

/* ------------------------------------------------------------------ */
/* Team and settings                                                   */
/* ------------------------------------------------------------------ */
