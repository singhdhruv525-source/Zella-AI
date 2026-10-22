import { useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Pill, personName } from "./BusinessUI";
import { dayRange, formatTime } from "./businessTime";
import { makeTerm } from "./businessWorkspace";
import { APPT_LABEL, APPT_TONE, Empty, Notice, PageHead, explain, loadPeople, noShowNotice, orThrow, plural, useLoad } from "./BusinessShared";
import { RescheduleModal } from "./BusinessForms";
import { WalkInModal } from "./BusinessMore";

/* Who is expected, who has arrived, who is with someone, who is done.
   Attendance is recorded by a person (or a trusted integration), never guessed from the clock. */

const LATE_MIN = 10;
const NO_SHOW_REASONS = ["Didn't come and didn't call", "Called to say they weren't coming", "Came too late to be seen", "Other"];
const CANCEL_REASONS = ["Cancelled by the customer", "Cancelled by us", "Wants to reschedule", "Unwell", "Other"];

// Where an appointment is in the day. Cancelled, no-show and completed are final.
export function attendanceStage(a) {
  if (a.status === "completed") return "done";
  if (a.status === "no_show" || a.status === "cancelled") return "done";
  if (a.in_service_at) return "service";
  if (a.checked_in_at || a.arrived_at) return "waiting";
  return "expected";
}

export function minutesLate(a, nowMs = Date.now()) {
  const start = new Date(a.start_time).getTime();
  const here = a.checked_in_at ?? a.arrived_at;
  if (here) return Math.max(0, Math.round((new Date(here).getTime() - start) / 60000));
  return Math.max(0, Math.round((nowMs - start) / 60000));
}

function ReasonForm({ kind, onSubmit, onCancel, busy }) {
  const options = kind === "no_show" ? NO_SHOW_REASONS : CANCEL_REASONS;
  const [choice, setChoice] = useState(options[0]);
  const [more, setMore] = useState("");
  return (
    <form className="ba-reason" onSubmit={(e) => { e.preventDefault(); onSubmit(choice === "Other" && !more.trim() ? "" : [choice === "Other" ? null : choice, more.trim()].filter(Boolean).join(": ")); }}>
      <Field label={kind === "no_show" ? "Why a no-show?" : "Why cancelled?"}>
        <select value={choice} onChange={(e) => setChoice(e.target.value)}>{options.map((o) => <option key={o}>{o}</option>)}</select>
      </Field>
      <Field label="Note"><input value={more} onChange={(e) => setMore(e.target.value)} placeholder={choice === "Other" ? "Required" : "Optional"} /></Field>
      <div className="ba-form-actions">
        <button type="submit" className="ba-btn sm danger-outline" disabled={busy || (choice === "Other" && !more.trim())}>{kind === "no_show" ? "Mark no-show" : "Cancel appointment"}</button>
        <button type="button" className="ba-btn sm" onClick={onCancel}>Back</button>
      </div>
    </form>
  );
}

export function CheckInsPage({ workspace, refreshKey, onNotice, onOpenPerson, onChanged }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const hospitality = /restaurant|cafe|café|bar\b|food|dining|hotel|catering/i.test(`${workspace.industry ?? ""} ${term("appointment")}`);
  const [walkIn, setWalkIn] = useState(false);
  const [working, setWorking] = useState(null);
  const [moving, setMoving] = useState(null);
  const [reasonFor, setReasonFor] = useState(null); // { id, kind }
  const [search, setSearch] = useState("");
  const [provider, setProvider] = useState("all");
  const { data, error, loading, reload } = useLoad(async () => {
    const today = dayRange(tz, 0);
    const appts = orThrow(await supabase.from("appointments").select("*").eq("business_id", workspace.id)
      .gte("start_time", today.start.toISOString()).lt("start_time", today.end.toISOString()).order("start_time"));
    const staffResult = await supabase.from("staff_members").select("id, name, color, is_active").eq("business_id", workspace.id);
    const people = await loadPeople(appts.map((a) => a.customer_id));
    return { appts, staff: staffResult.error ? [] : staffResult.data ?? [], people };
  }, [workspace.id, refreshKey]);

  const staff = data?.staff ?? [];
  const staffName = Object.fromEntries(staff.map((m) => [m.id, m.name]));
  const nowMs = Date.now();
  const q = search.trim().toLowerCase();
  const matches = (a) => {
    if (provider !== "all" && (provider === "none" ? a.staff_id : a.staff_id !== provider)) return false;
    if (!q) return true;
    const p = data.people[a.customer_id];
    return [personName(p), p?.phone, p?.email, a.title].some((v) => v && String(v).toLowerCase().includes(q));
  };
  const groups = useMemo(() => {
    const g = { expected: [], waiting: [], service: [], done: [] };
    (data?.appts ?? []).filter((a) => matches(a)).forEach((a) => g[attendanceStage(a)].push(a));
    g.waiting.sort((a, b) => new Date(a.checked_in_at ?? a.arrived_at) - new Date(b.checked_in_at ?? b.arrived_at));
    return g;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data, search, provider]);

  async function act(a, action, message, { reason, staffId } = {}) {
    setWorking(a.id);
    const { error: failure } = await supabase.rpc("zella_set_attendance", { p_appointment_id: a.id, p_action: action, p_reason: reason ?? null, p_staff_id: staffId ?? null });
    if (failure) { setWorking(null); return onNotice(explain(failure)); }
    let text = message;
    if (action === "no_show") text = await noShowNotice(a.id, personName(data.people[a.customer_id]) ?? a.title, tz);
    setWorking(null);
    setReasonFor(null);
    onNotice(text);
    reload();
    onChanged?.();
  }

  const Card = ({ a, column }) => {
    const person = data.people[a.customer_id];
    const name = personName(person) ?? a.title;
    const busy = working === a.id;
    const late = minutesLate(a, nowMs);
    const started = new Date(a.start_time).getTime() <= nowMs;
    const lateNow = column === "expected" && late >= LATE_MIN;
    const arrivedLate = (column === "waiting" || column === "service") && late >= LATE_MIN;
    const sub = a.checked_in_at ? "Checked in" : "Arrived";
    return (
      <article className={`ba-item ${lateNow ? "alert" : ""}`}>
        <div className="ba-item-top">
          <div className="ba-item-name">{person ? <button type="button" className="ba-namebtn strong" onClick={() => onOpenPerson(person.id)}>{name}</button> : <strong>{name}</strong>}</div>
          <span className="ba-item-time">{formatTime(a.start_time, tz)}</span>
        </div>
        <div className="ba-item-meta">
          <span>{a.title}</span>
          {a.party_size && <span>· party of {a.party_size}</span>}
          {column === "waiting" && <Pill tone="success">{sub} · waiting {Math.max(0, Math.round((nowMs - new Date(a.checked_in_at ?? a.arrived_at).getTime()) / 60000))} min</Pill>}
          {column === "service" && <Pill tone="info">With {staffName[a.staff_id] ?? "the team"} since {formatTime(a.in_service_at, tz)}</Pill>}
          {lateNow && <Pill tone="danger">{late} min late</Pill>}
          {arrivedLate && <Pill tone="warning">Arrived {late} min late</Pill>}
          {column === "done" && <Pill tone={APPT_TONE[a.status]}>{APPT_LABEL[a.status]}</Pill>}
          {column === "done" && a.attendance_note && <small>{a.attendance_note}</small>}
          {column === "done" && a.cancel_reason && !a.attendance_note && <small>{a.cancel_reason}</small>}
        </div>

        {column !== "done" && staff.length > 0 && (
          <label className="ba-select ba-item-staff"><span>Provider</span>
            <select value={a.staff_id ?? ""} disabled={busy} onChange={(e) => e.target.value && act(a, "assign", "Provider assigned.", { staffId: e.target.value })}>
              <option value="">Not assigned</option>
              {staff.filter((m) => m.is_active || m.id === a.staff_id).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>
          </label>
        )}

        {reasonFor?.id === a.id ? (
          <ReasonForm kind={reasonFor.kind} busy={busy} onCancel={() => setReasonFor(null)}
            onSubmit={(reason) => act(a, reasonFor.kind, `${a.title} ${reasonFor.kind === "cancelled" ? "cancelled" : "marked no-show"}.`, { reason })} />
        ) : (
          <div className="ba-item-actions">
            {column === "expected" && (
              <>
                <button type="button" className="ba-btn sm" disabled={busy || a.arrived_at} onClick={() => act(a, "arrived", `${name} arrived.`)}><Icon name="directions_walk" size="sm" />Arrived</button>
                <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => act(a, "checked_in", `${name} checked in.`)}><Icon name="how_to_reg" size="sm" />Check in</button>
              </>
            )}
            {column === "waiting" && (
              <>
                {!a.checked_in_at && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => act(a, "checked_in", `${name} checked in.`)}>Check in</button>}
                <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => act(a, "in_service", `${name} is now being seen.`)}>Start</button>
                <button type="button" className="ba-btn sm" disabled={busy} onClick={() => act(a, "undo", "Undone.")}>Undo</button>
              </>
            )}
            {column === "service" && (
              <>
                <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => act(a, "completed", `${a.title} completed.`)}>Complete</button>
                <button type="button" className="ba-btn sm" disabled={busy} onClick={() => act(a, "undo", "Undone.")}>Undo</button>
              </>
            )}
            {column === "done" && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => act(a, "undo", "Reopened.")}>Reopen</button>}
            {column !== "done" && person?.phone && <a className="ba-btn sm" href={`tel:${person.phone}`}><Icon name="call" size="sm" />Call</a>}
            {column !== "done" && person?.phone && !person.do_not_sms && !person.do_not_contact && <a className="ba-btn sm" href={`sms:${person.phone}`}><Icon name="sms" size="sm" />Text</a>}
            {column === "expected" && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setMoving(a)}><Icon name="event_repeat" size="sm" />Reschedule</button>}
            {column === "expected" && started && <button type="button" className="ba-btn sm danger-outline" disabled={busy} onClick={() => setReasonFor({ id: a.id, kind: "no_show" })}>No-show</button>}
            {(column === "expected" || column === "waiting") && <button type="button" className="ba-btn sm danger-outline" disabled={busy} onClick={() => setReasonFor({ id: a.id, kind: "cancelled" })}>Cancel</button>}
          </div>
        )}
      </article>
    );
  };

  const Column = ({ title, icon, items, column, emptyText }) => (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><span className="ba-kpi-icon indigo"><Icon name={icon} size="sm" /></span><div><h2>{title}</h2><p>{plural(items.length, "person", "people")}</p></div></div></div>
      <div className="ba-panel-body">{items.length ? items.map((a) => <Card key={a.id} a={a} column={column} />) : <Empty>{emptyText}</Empty>}</div>
    </section>
  );

  return (
    <>
      <PageHead crumb="Core / Check-ins" title="Check-ins" sub={`Who is expected, who has arrived, and who is done today (${tz.replace("_", " ")}). You record each step.`}>
        <button type="button" className="ba-btn primary" onClick={() => setWalkIn(true)}><Icon name="directions_walk" size="sm" /><span>Add walk-in</span></button>
      </PageHead>
      <div className="ba-toolbar ba-lead-tools">
        <label className="ba-select ba-search"><span>Search</span>
          <input type="search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={`Name, phone or ${term("appointment").toLowerCase()}`} />
        </label>
        {staff.length > 0 && (
          <label className="ba-select"><span>Provider</span>
            <select value={provider} onChange={(e) => setProvider(e.target.value)}>
              <option value="all">Everyone</option><option value="none">Not assigned</option>
              {staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>
          </label>
        )}
      </div>
      <Notice error={error} onRetry={reload} />
      {loading && !data ? <p className="ba-muted">Loading…</p> : (
        <div className="ba-columns four">
          <Column title="Expected" icon="schedule" items={groups.expected} column="expected" emptyText={`No more ${term("appointments").toLowerCase()} expected today.`} />
          <Column title="Waiting now" icon="hourglass_top" items={groups.waiting} column="waiting" emptyText="Nobody is waiting." />
          <Column title="In service" icon="medical_services" items={groups.service} column="service" emptyText="Nobody is being seen right now." />
          <Column title="Done today" icon="task_alt" items={groups.done} column="done" emptyText="Nothing finished yet." />
        </div>
      )}
      {moving && (
        <RescheduleModal workspace={workspace} term={term} appt={moving} person={data?.people?.[moving.customer_id]}
          onClose={() => setMoving(null)} onSaved={(message) => { setMoving(null); onNotice(message); reload(); onChanged?.(); }} />
      )}
      {walkIn && (
        <WalkInModal workspace={workspace} staff={data?.staff ?? []} hospitality={hospitality}
          onClose={() => setWalkIn(false)} onSaved={(message) => { setWalkIn(false); onNotice(message); reload(); onChanged?.(); }} />
      )}
    </>
  );
}
