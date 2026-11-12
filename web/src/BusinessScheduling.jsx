// Release 2: Dispatch, Resources and Recurring visits (sql/zella_scheduling.sql). The server checks every booking,
// assignment and step; these screens show the state and say plainly why something was refused.
import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, personName } from "./BusinessUI";
import { Empty, PageHead, useLoad } from "./BusinessShared";
import { PersonPicker } from "./BusinessWork";
import { formatDay, formatTime, todayInput, zonedDateTime } from "./businessTime";
import { JOB_STATUS, KIND_LABEL, RESOURCE_KINDS, WEEKDAY_OPTIONS, arrivalText, checklistProgress, describePlan, nextSteps, scheduleError } from "./schedulingLogic";

const MANAGERS = ["owner", "admin", "manager"];
const shiftDay = (day, n) => { const d = new Date(`${day}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const dayLabel = (day) => new Intl.DateTimeFormat("en-US", { timeZone: "UTC", weekday: "long", month: "short", day: "numeric" }).format(new Date(`${day}T12:00:00Z`));

// one call at a time; refusals are explained and the screen reloads to show the current state
function useRun(onNotice, reload) {
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  async function run(work, done) {
    if (busy) return false;
    setBusy(true); setProblem("");
    let res;
    try { res = await work(); }
    catch (err) { res = { error: err }; }
    finally { setBusy(false); }
    if (res?.error) { setProblem(scheduleError(res.error)); reload?.(); return false; }
    if (done) onNotice?.(typeof done === "function" ? done(res.data) : done);
    reload?.();
    return true;
  }
  return { busy, problem, setProblem, run };
}

function LoadState({ load, children, what }) {
  if (load.loading && !load.data) return <p className="ba-muted">Loading {what}…</p>;
  if (load.error && !load.data) {
    return <div className="ba-error" role="alert">{scheduleError({ message: load.error })} <button type="button" className="ba-btn sm" onClick={load.reload}>Try again</button></div>;
  }
  return (
    <>
      {load.error && <p className="ba-error" role="status">The latest refresh failed: showing what was loaded before. <button type="button" className="ba-btn sm" onClick={load.reload}>Try again</button></p>}
      {children}
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Dispatch                                                            */
/* ------------------------------------------------------------------ */

export function DispatchPage({ workspace, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [day, setDay] = useState(() => todayInput(tz));
  const board = useLoad(async () => {
    const { data, error } = await supabase.rpc("zella_dispatch_board", { p_business_id: workspace.id, p_day: day });
    if (error) throw error;
    if (!data || !Array.isArray(data.jobs) || !Array.isArray(data.technicians)) throw new Error("zella_dispatch_board returned an unexpected shape");
    return data;
  }, [workspace.id, day, refreshKey]);
  const { busy, problem, run } = useRun(onNotice, board.reload);
  const [assigning, setAssigning] = useState(null);
  const [checklist, setChecklist] = useState(null);
  const [returning, setReturning] = useState(null);
  const b = board.data;
  const techName = Object.fromEntries((b?.technicians ?? []).map((t) => [t.id, t.name]));
  const unassigned = (b?.jobs ?? []).filter((j) => !j.staff_id);
  const columns = (b?.technicians ?? []).map((t) => ({ ...t, jobs: (b?.jobs ?? []).filter((j) => j.staff_id === t.id || (j.crew ?? []).includes(t.id)) }));

  const card = (j, techId) => {
    const [label, tone] = JOB_STATUS[j.status] ?? [j.status, ""];
    const progress = checklistProgress(j.checklist);
    const isLead = !techId || j.staff_id === techId;
    return (
      <li key={`${techId ?? "u"}:${j.id}`} className="ba-job" data-job={j.status}>
        <div className="ba-job-head">
          <strong>{arrivalText(j.start, b.arrival_window_minutes, tz)}</strong>
          <Pill tone={tone}>{label}</Pill>
          {j.booking_state === "tentative" && <Pill tone="warning">Planned</Pill>}
          {!isLead && <Pill>Crew</Pill>}
        </div>
        <p className="ba-job-title">{j.title}</p>
        <p className="ba-muted ba-small">
          {j.customer && <button type="button" className="ba-link" onClick={() => onOpenPerson?.(j.customer.id)}>{j.customer.name ?? j.customer.phone ?? "Customer"}</button>}
          {j.record && <> · {j.record.title}</>}
          {j.location && <> · {j.location}</>}
        </p>
        {(j.crew ?? []).length > 0 && <p className="ba-muted ba-small">Crew: {j.crew.map((c) => techName[c] ?? "Someone").join(", ")}{j.staff_id ? ` · lead ${techName[j.staff_id] ?? ""}` : ""}</p>}
        {progress.total > 0 && <p className="ba-muted ba-small">Checklist: {progress.text}</p>}
        {j.return_of && <p className="ba-muted ba-small">Return visit for an earlier job.</p>}
        {j.note && <p className="ba-small">{j.note}</p>}
        {b.can_work && isLead && (
          <div className="ba-people-actions">
            {["unassigned", "assigned"].includes(j.status) && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setAssigning(j)}>{j.staff_id ? "Reassign" : "Assign"}</button>}
            {j.staff_id && nextSteps(j.status).map(([to, words]) => (
              <button key={to} type="button" className={`ba-btn sm${to === "completed" ? " primary" : ""}`} disabled={busy}
                onClick={() => run(() => supabase.rpc("zella_dispatch_status", { p_appointment_id: j.id, p_from: j.status, p_to: to }), `${j.title}: ${(JOB_STATUS[to] ?? [to])[0].toLowerCase()}.`)}>{words}</button>
            ))}
            {!["completed", "needs_return"].includes(j.status) && <button type="button" className="ba-btn sm ghost" disabled={busy} onClick={() => setChecklist(j)}>Checklist</button>}
            {j.status === "needs_return" && !j.returns && <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => setReturning(j)}>Book the return visit</button>}
            {j.status === "needs_return" && j.returns > 0 && <span className="ba-muted ba-small">Return visit booked.</span>}
          </div>
        )}
      </li>
    );
  };

  return (
    <>
      <PageHead crumb="Workspace / Dispatch" title="Dispatch" sub="Who is on which job today, where they are, and what's left. Nobody can be booked on two jobs at once.">
        <div className="ba-day-nav">
          <button type="button" className="ba-btn sm" onClick={() => setDay(shiftDay(day, -1))} aria-label="Previous day"><Icon name="chevron_left" size="sm" /></button>
          <button type="button" className="ba-btn sm" onClick={() => setDay(todayInput(tz))}>Today</button>
          <button type="button" className="ba-btn sm" onClick={() => setDay(shiftDay(day, 1))} aria-label="Next day"><Icon name="chevron_right" size="sm" /></button>
          <label className="td-date"><Icon name="calendar_month" size="sm" /><input type="date" value={day} onChange={(e) => e.target.value && setDay(e.target.value)} aria-label="Day" /></label>
        </div>
      </PageHead>
      {problem && <p className="ba-error" role="alert">{problem}</p>}
      <LoadState load={board} what="the board">
        {b && (
          <div data-dispatch="ready">
            <h2 className="ba-h3">{dayLabel(day)}</h2>
            {!b.can_work && <p className="ba-muted">You can view the board. Changes need a staff member or above.</p>}
            {!b.technicians.length && <Empty title="No technicians yet" icon="engineering">Add the people jobs are assigned to in Settings &gt; Team.</Empty>}
            <section className="ba-panel" aria-label="Unassigned jobs">
              <div className="ba-panel-body">
                <h3 className="ba-h3">Unassigned ({unassigned.length})</h3>
                {unassigned.length ? <ul className="ba-job-list">{unassigned.map((j) => card(j, null))}</ul> : <p className="ba-muted">Every job this day has someone.</p>}
              </div>
            </section>
            <div className="ba-dispatch-cols">
              {columns.map((t) => (
                <section key={t.id} className="ba-panel" aria-label={t.name}>
                  <div className="ba-panel-body">
                    <h3 className="ba-h3">{t.name} {t.time_off && <Pill tone="warning">Time off</Pill>}</h3>
                    {t.jobs.length ? <ul className="ba-job-list">{t.jobs.map((j) => card(j, t.id))}</ul> : <p className="ba-muted">No jobs.</p>}
                  </div>
                </section>
              ))}
            </div>
          </div>
        )}
      </LoadState>
      {assigning && <AssignModal key={assigning.id} job={assigning} technicians={b?.technicians ?? []} busy={busy} onClose={() => setAssigning(null)}
        onSave={async (lead, crew) => { if (await run(() => supabase.rpc("zella_dispatch_assign", { p_appointment_id: assigning.id, p_staff_id: lead, p_crew: crew }), "Assigned.")) setAssigning(null); }} />}
      {checklist && <ChecklistModal key={checklist.id} job={checklist} busy={busy} onClose={() => setChecklist(null)}
        onSave={async (items) => { if (await run(() => supabase.rpc("zella_dispatch_checklist", { p_appointment_id: checklist.id, p_items: items }), "Checklist saved.")) setChecklist(null); }} />}
      {returning && <ReturnVisitModal key={returning.id} job={returning} tz={tz} technicians={b?.technicians ?? []} busy={busy} onClose={() => setReturning(null)}
        onSave={async (start, minutes, staff, reason) => { if (await run(() => supabase.rpc("zella_dispatch_return_visit", { p_appointment_id: returning.id, p_start: start, p_duration_minutes: minutes, p_staff_id: staff, p_reason: reason }), "Return visit booked.")) setReturning(null); }} />}
    </>
  );
}

function AssignModal({ job, technicians, busy, onClose, onSave }) {
  const [lead, setLead] = useState(job.staff_id ?? "");
  const [crew, setCrew] = useState(job.crew ?? []);
  const toggle = (id) => setCrew((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]));
  return (
    <Modal title={`Assign: ${job.title}`} icon="engineering" onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-assign" className="ba-btn primary" disabled={busy || !lead}>{busy ? "Saving…" : "Assign"}</button></>}>
      <form id="ba-assign" className="ba-modal-body" onSubmit={(e) => { e.preventDefault(); if (lead && !busy) onSave(lead, crew.filter((c) => c !== lead)); }}>
        <Field label="Lead technician">
          <select value={lead} onChange={(e) => setLead(e.target.value)} required>
            <option value="">Choose…</option>
            {technicians.map((t) => <option key={t.id} value={t.id}>{t.name}{t.time_off ? " (time off)" : ""}</option>)}
          </select>
        </Field>
        <fieldset className="ba-prefs"><legend>Crew (optional)</legend>
          {technicians.filter((t) => t.id !== lead).map((t) => (
            <label key={t.id} className="ba-check"><input type="checkbox" checked={crew.includes(t.id)} onChange={() => toggle(t.id)} /><span>{t.name}</span></label>
          ))}
        </fieldset>
        <p className="ba-muted ba-small">If someone is already on another job then, Zella Voice refuses and says so.</p>
      </form>
    </Modal>
  );
}

function ChecklistModal({ job, busy, onClose, onSave }) {
  const [items, setItems] = useState(() => (job.checklist ?? []).map((i) => ({ ...i })));
  const [label, setLabel] = useState("");
  const set = (i, patch) => setItems((list) => list.map((x, n) => (n === i ? { ...x, ...patch } : x)));
  return (
    <Modal title={`Checklist: ${job.title}`} icon="checklist" onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="button" className="ba-btn primary" disabled={busy} onClick={() => onSave(items)}>{busy ? "Saving…" : "Save checklist"}</button></>}>
      <div className="ba-modal-body">
        {items.length ? (
          <ul className="ba-check-list">
            {items.map((it, i) => (
              <li key={`${it.label}:${i}`}>
                <label className="ba-check"><input type="checkbox" checked={Boolean(it.done)} onChange={(e) => set(i, { done: e.target.checked })} /><span>{it.label}</span></label>
                <label className="ba-check ba-small"><input type="checkbox" checked={Boolean(it.required)} onChange={(e) => set(i, { required: e.target.checked })} /><span>Required</span></label>
                <button type="button" className="ba-link" onClick={() => setItems((list) => list.filter((_, n) => n !== i))}>Remove</button>
              </li>
            ))}
          </ul>
        ) : <p className="ba-muted">No items yet. Required items must be ticked before the job can be completed.</p>}
        <form className="ba-inline" onSubmit={(e) => { e.preventDefault(); if (label.trim()) { setItems((l) => [...l, { label: label.trim(), required: false, done: false }]); setLabel(""); } }}>
          <Field label="Add an item"><input value={label} maxLength={120} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. Photos of the finished work" /></Field>
          <button type="submit" className="ba-btn sm" disabled={!label.trim()}>Add</button>
        </form>
      </div>
    </Modal>
  );
}

function ReturnVisitModal({ job, tz, technicians, busy, onClose, onSave }) {
  const [date, setDate] = useState(() => todayInput(tz));
  const [time, setTime] = useState("09:00");
  const [minutes, setMinutes] = useState(() => {
    const m = Math.round((new Date(job.end) - new Date(job.start)) / 60000);
    return String(Number.isFinite(m) ? Math.max(30, m) : 60);
  });
  const [staff, setStaff] = useState(job.staff_id ?? "");
  const [reason, setReason] = useState("");
  return (
    <Modal title={`Return visit: ${job.title}`} icon="event_repeat" onClose={onClose} busy={busy}
      description={`Times are in ${tz.replace("_", " ")}.`}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-return" className="ba-btn primary" disabled={busy}>{busy ? "Booking…" : "Book return visit"}</button></>}>
      <form id="ba-return" className="ba-modal-body ba-form-grid" onSubmit={(e) => { e.preventDefault(); if (!busy) onSave(zonedDateTime(date, time, tz).toISOString(), Number(minutes), staff || null, reason); }}>
        <Field label="Date"><input type="date" value={date} min={todayInput(tz)} onChange={(e) => setDate(e.target.value)} required /></Field>
        <Field label="Time"><input type="time" value={time} onChange={(e) => setTime(e.target.value)} required /></Field>
        <Field label="Minutes"><input type="number" min={5} max={720} value={minutes} onChange={(e) => setMinutes(e.target.value)} required /></Field>
        <Field label="Technician">
          <select value={staff} onChange={(e) => setStaff(e.target.value)}>
            <option value="">Same technician</option>
            {technicians.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </Field>
        <Field label="What's left to do" full><input value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Fit the part when it arrives" /></Field>
      </form>
    </Modal>
  );
}

/* ------------------------------------------------------------------ */
/* Resources                                                           */
/* ------------------------------------------------------------------ */

export function ResourcesPage({ workspace, refreshKey, onNotice }) {
  const tz = workspace.timezone;
  const canManage = MANAGERS.includes(workspace.role);
  const [day, setDay] = useState(() => todayInput(tz));
  const list = useLoad(async () => {
    const [res, needs] = await Promise.all([
      supabase.from("resources").select("*").eq("business_id", workspace.id).order("sort_order").order("name"),
      supabase.from("resource_needs").select("*").eq("business_id", workspace.id).order("service"),
    ]);
    if (res.error) throw res.error;
    if (needs.error) throw needs.error;
    return { resources: res.data ?? [], needs: needs.data ?? [] };
  }, [workspace.id, refreshKey]);
  const schedule = useLoad(async () => {
    const { data, error } = await supabase.rpc("zella_resource_day", { p_business_id: workspace.id, p_day: day });
    if (error) throw error;
    if (!Array.isArray(data)) throw new Error("zella_resource_day returned an unexpected shape");
    return data;
  }, [workspace.id, day, refreshKey]);
  const reloadBoth = () => { list.reload(); schedule.reload(); };
  const { busy, problem, run } = useRun(onNotice, reloadBoth);
  const [editing, setEditing] = useState(null);
  const [needsOpen, setNeedsOpen] = useState(false);

  return (
    <>
      <PageHead crumb="Workspace / Resources" title="Resources" sub="Rooms, chairs, bays, equipment and spaces that bookings use. Zella Voice never books one twice at the same time, and keeps the gap you set after each booking.">
        {canManage && <button type="button" className="ba-btn primary" onClick={() => setEditing("new")}><Icon name="add" size="sm" />Add a resource</button>}
        {canManage && <button type="button" className="ba-btn" onClick={() => setNeedsOpen(true)}>What services need</button>}
      </PageHead>
      {problem && <p className="ba-error" role="alert">{problem}</p>}
      {!canManage && <p className="ba-muted">You can view resources. Owners, admins and managers set them up.</p>}
      <LoadState load={list} what="resources">
        {list.data && (list.data.resources.length ? (
          <ul className="ba-stack" data-resources="ready">
            {list.data.resources.map((r) => (
              <li key={r.id} className="ba-panel"><div className="ba-panel-body ba-kn-head">
                <strong>{r.name}</strong> <Pill>{KIND_LABEL[r.kind] ?? r.kind}</Pill>
                {r.capacity > 1 && <Pill>Holds {r.capacity}</Pill>}
                {r.buffer_minutes > 0 && <span className="ba-muted ba-small">{r.buffer_minutes} min gap after each booking</span>}
                {!r.is_active && <Pill tone="warning">Out of use</Pill>}
                {canManage && <button type="button" className="ba-btn sm" onClick={() => setEditing(r)}>Edit</button>}
              </div></li>
            ))}
          </ul>
        ) : <Empty title="No resources yet" icon="meeting_room">Add the rooms, chairs, bays or equipment that bookings need.</Empty>)}
        {list.data && list.data.needs.length > 0 && (
          <p className="ba-muted ba-small">Services that need a resource: {list.data.needs.map((n) => `${n.service} → ${n.quantity} ${KIND_LABEL[n.kind]?.toLowerCase() ?? n.kind}`).join(" · ")}. A booking for one of these gets a free one picked.</p>
        )}
      </LoadState>
      <section className="ba-panel" aria-label="Resources by day">
        <div className="ba-panel-body">
          <div className="ba-kn-head"><h3 className="ba-h3">Who's using what</h3>
            <label className="td-date"><Icon name="calendar_month" size="sm" /><input type="date" value={day} onChange={(e) => e.target.value && setDay(e.target.value)} aria-label="Day" /></label></div>
          <LoadState load={schedule} what="the day">
            {schedule.data && (schedule.data.length ? schedule.data.map((r) => (
              <div key={r.id} className="ba-res-day">
                <strong>{r.name}</strong>
                {r.bookings.length || r.blocks.length ? (
                  <ul className="ba-small">
                    {r.blocks.map((x) => <li key={x.id}><Pill tone="warning">Blocked</Pill> {formatTime(x.start, tz)}–{formatTime(x.end, tz)} {x.title}</li>)}
                    {r.bookings.map((x) => <li key={x.id}>{formatTime(x.start, tz)}–{formatTime(x.end, tz)} {x.customer ?? x.title}{x.party_size > 1 ? ` (${x.party_size})` : ""}{x.state === "tentative" ? " · planned" : ""}</li>)}
                  </ul>
                ) : <span className="ba-muted ba-small"> Free all day.</span>}
              </div>
            )) : <p className="ba-muted">No resources in use.</p>)}
          </LoadState>
        </div>
      </section>
      {editing && <ResourceModal key={editing === "new" ? "new" : editing.id} resource={editing === "new" ? null : editing} busy={busy} onClose={() => setEditing(null)}
        onSave={async (f) => {
          if (await run(() => supabase.rpc("zella_resource_save", { p_business_id: workspace.id, p_id: f.id ?? null, p_name: f.name, p_kind: f.kind, p_capacity: Number(f.capacity),
            p_buffer_minutes: Number(f.buffer_minutes), p_notes: f.notes || null, p_sort_order: Number(f.sort_order) || 0, p_active: f.is_active }), f.id ? "Resource saved." : "Resource added.")) setEditing(null);
        }} />}
      {needsOpen && list.data && <NeedsModal needs={list.data.needs} busy={busy} onClose={() => setNeedsOpen(false)}
        onSave={async (rows) => { if (await run(() => supabase.rpc("zella_resource_needs_save", { p_business_id: workspace.id, p_needs: rows }), "Saved what services need.")) setNeedsOpen(false); }} />}
    </>
  );
}

function ResourceModal({ resource, busy, onClose, onSave }) {
  const [f, setF] = useState(() => ({ id: resource?.id, name: resource?.name ?? "", kind: resource?.kind ?? "room", capacity: String(resource?.capacity ?? 1),
    buffer_minutes: String(resource?.buffer_minutes ?? 0), notes: resource?.notes ?? "", sort_order: String(resource?.sort_order ?? 0), is_active: resource?.is_active ?? true }));
  const set = (k) => (e) => setF((x) => ({ ...x, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.value }));
  return (
    <Modal title={resource ? `Edit ${resource.name}` : "Add a resource"} icon="meeting_room" onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-resource" className="ba-btn primary" disabled={busy || !f.name.trim()}>{busy ? "Saving…" : "Save"}</button></>}>
      <form id="ba-resource" className="ba-modal-body ba-form-grid" onSubmit={(e) => { e.preventDefault(); if (f.name.trim() && !busy) onSave(f); }}>
        <Field label="Name"><input value={f.name} maxLength={80} onChange={set("name")} placeholder="e.g. Treatment room 1" required /></Field>
        <Field label="Kind"><select value={f.kind} onChange={set("kind")}>{RESOURCE_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        <Field label="Holds at once" hint="1 for a chair or room; more for a boarding area or a class room."><input type="number" min={1} max={500} value={f.capacity} onChange={set("capacity")} /></Field>
        <Field label="Gap after each booking (minutes)" hint="Cleaning or turnover time."><input type="number" min={0} max={240} value={f.buffer_minutes} onChange={set("buffer_minutes")} /></Field>
        <Field label="Notes (optional)" full><input value={f.notes} maxLength={300} onChange={set("notes")} /></Field>
        {resource && <label className="ba-check"><input type="checkbox" checked={f.is_active} onChange={set("is_active")} /><span>In use (untick to stop new bookings using it)</span></label>}
      </form>
    </Modal>
  );
}

function NeedsModal({ needs, busy, onClose, onSave }) {
  const [rows, setRows] = useState(() => needs.map((n) => ({ service: n.service, kind: n.kind, quantity: n.quantity })));
  const set = (i, patch) => setRows((r) => r.map((x, n) => (n === i ? { ...x, ...patch } : x)));
  return (
    <Modal title="What services need" icon="rule" onClose={onClose} busy={busy} wide
      description="When a booking's title or type mentions the service, Zella Voice picks free resources of that kind, or refuses the time when none is free."
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="button" className="ba-btn primary" disabled={busy || rows.some((r) => r.service.trim().length < 2)} onClick={() => onSave(rows.map((r) => ({ ...r, quantity: Number(r.quantity) || 1 })))}>{busy ? "Saving…" : "Save"}</button></>}>
      <div className="ba-modal-body">
        {rows.map((r, i) => (
          <div key={i} className="ba-form-grid">
            <Field label="Service"><input value={r.service} maxLength={80} onChange={(e) => set(i, { service: e.target.value })} placeholder="e.g. colour" /></Field>
            <Field label="Needs"><select value={r.kind} onChange={(e) => set(i, { kind: e.target.value })}>{RESOURCE_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
            <Field label="How many"><input type="number" min={1} max={10} value={r.quantity} onChange={(e) => set(i, { quantity: e.target.value })} /></Field>
            <button type="button" className="ba-link" onClick={() => setRows((x) => x.filter((_, n) => n !== i))}>Remove</button>
          </div>
        ))}
        <button type="button" className="ba-btn sm" onClick={() => setRows((x) => [...x, { service: "", kind: "chair", quantity: 1 }])}><Icon name="add" size="sm" />Add a service</button>
      </div>
    </Modal>
  );
}

/* ------------------------------------------------------------------ */
/* Recurring visits                                                    */
/* ------------------------------------------------------------------ */

export function RecurringPage({ workspace, refreshKey, onNotice }) {
  const tz = workspace.timezone;
  const canManage = MANAGERS.includes(workspace.role);
  const load = useLoad(async () => {
    const [plans, visits, staff, resources] = await Promise.all([
      supabase.from("recurring_plans").select("*").eq("business_id", workspace.id).order("is_active", { ascending: false }).order("title"),
      supabase.from("recurring_visits").select("id, plan_id, occurs_on, outcome, reason, appointment_id").eq("business_id", workspace.id).gte("occurs_on", todayInput(tz)).order("occurs_on").limit(500),
      supabase.from("staff_members").select("id, name").eq("business_id", workspace.id).eq("is_active", true).order("sort_order").order("name"),
      supabase.from("resources").select("id, name").eq("business_id", workspace.id).eq("is_active", true).order("sort_order").order("name"),
    ]);
    for (const r of [plans, visits, staff, resources]) if (r.error) throw r.error;
    const ids = [...new Set((plans.data ?? []).map((p) => p.customer_id).filter(Boolean))];
    const people = ids.length ? await supabase.from("customers").select("id, first_name, last_name, phone").in("id", ids) : { data: [] };
    if (people.error) throw people.error;
    return { plans: plans.data ?? [], visits: visits.data ?? [], staff: staff.data ?? [], resources: resources.data ?? [], people: Object.fromEntries((people.data ?? []).map((p) => [p.id, p])) };
  }, [workspace.id, refreshKey]);
  const { busy, problem, run } = useRun(onNotice, load.reload);
  const [editing, setEditing] = useState(null);
  const d = load.data;

  const generate = (planId) => run(() => supabase.rpc("zella_recurring_generate", { p_business_id: workspace.id, p_plan_id: planId ?? null, p_through: null }),
    (r) => `Booked ${r?.booked ?? 0} planned visit${r?.booked === 1 ? "" : "s"} up to ${r?.through ? formatDay(`${r.through}T12:00:00Z`, "UTC") : "4 weeks ahead"}${r?.skipped ? `; ${r.skipped} skipped (see why below)` : ""}.`);

  return (
    <>
      <PageHead crumb="Workspace / Recurring visits" title="Recurring visits" sub="Repeat work on a schedule: cleanings, maintenance, treatments. Zella Voice books the next weeks as planned visits that hold the time; nothing is sent to the customer. Confirm each visit when it's agreed.">
        {canManage && <button type="button" className="ba-btn primary" onClick={() => setEditing("new")}><Icon name="add" size="sm" />Add a plan</button>}
        {canManage && d?.plans.some((p) => p.is_active) && <button type="button" className="ba-btn" disabled={busy} onClick={() => generate(null)}>Book the next 4 weeks</button>}
      </PageHead>
      {problem && <p className="ba-error" role="alert">{problem}</p>}
      {!canManage && <p className="ba-muted">You can view plans. Owners, admins and managers set them up and book them.</p>}
      <LoadState load={load} what="plans">
        {d && (d.plans.length ? (
          <ul className="ba-stack" data-recurring="ready">
            {d.plans.map((p) => {
              const upcoming = d.visits.filter((v) => v.plan_id === p.id);
              const skipped = upcoming.filter((v) => v.outcome === "skipped");
              return (
                <li key={p.id} className="ba-panel" data-plan={p.title}><div className="ba-panel-body">
                  <div className="ba-kn-head">
                    <strong>{p.title}</strong> {!p.is_active && <Pill tone="warning">Paused</Pill>}
                    {canManage && <button type="button" className="ba-btn sm" onClick={() => setEditing(p)}>Edit</button>}
                    {canManage && p.is_active && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => generate(p.id)}>Book the next 4 weeks</button>}
                  </div>
                  <p className="ba-muted">{describePlan(p)} · {p.duration_minutes} min{p.customer_id && d.people[p.customer_id] ? ` · ${personName(d.people[p.customer_id]) ?? d.people[p.customer_id].phone}` : ""}
                    {p.staff_id ? ` · ${d.staff.find((s) => s.id === p.staff_id)?.name ?? "someone no longer on the team"}` : ""}
                    {` · from ${formatDay(`${p.starts_on}T12:00:00Z`, "UTC")}`}{p.ends_on ? ` to ${formatDay(`${p.ends_on}T12:00:00Z`, "UTC")}` : ""}</p>
                  <p className="ba-small">{upcoming.length ? `${upcoming.length - skipped.length} upcoming visit${upcoming.length - skipped.length === 1 ? "" : "s"} booked` : "No upcoming visits booked yet."}
                    {p.generated_through ? ` (up to ${formatDay(`${p.generated_through}T12:00:00Z`, "UTC")})` : ""}</p>
                  {skipped.length > 0 && (
                    <ul className="ba-small" aria-label="Skipped dates">
                      {skipped.map((v) => <li key={v.id}><Pill tone="warning">Skipped</Pill> {formatDay(`${v.occurs_on}T12:00:00Z`, "UTC")}: {v.reason}</li>)}
                    </ul>
                  )}
                </div></li>
              );
            })}
          </ul>
        ) : <Empty title="No recurring plans yet" icon="event_repeat">Add one for work that repeats, like a cleaning every two weeks or a quarterly service.</Empty>)}
      </LoadState>
      {editing && d && <PlanModal key={editing === "new" ? "new" : editing.id} workspace={workspace} plan={editing === "new" ? null : editing} staff={d.staff} resources={d.resources}
        person={editing !== "new" && editing.customer_id ? d.people[editing.customer_id] : null} busy={busy} onClose={() => setEditing(null)}
        onSave={async (plan) => { if (await run(() => supabase.rpc("zella_recurring_save", { p_business_id: workspace.id, p_id: plan.id ?? null, p_plan: plan }), plan.id ? "Plan saved." : "Plan added. Book its visits when you're ready.")) setEditing(null); }} />}
    </>
  );
}

function PlanModal({ workspace, plan, staff, resources, person: initialPerson, busy, onClose, onSave }) {
  const tz = workspace.timezone;
  const [person, setPerson] = useState(initialPerson ?? null);
  const [f, setF] = useState(() => ({
    id: plan?.id, title: plan?.title ?? "", service: plan?.service ?? "", frequency: plan?.frequency ?? "weekly", interval_count: String(plan?.interval_count ?? 1),
    weekday: String(plan?.weekday ?? 1), month_day: String(plan?.month_day ?? 1), start_at: (plan?.start_at ?? "09:00").slice(0, 5), duration_minutes: String(plan?.duration_minutes ?? 60),
    staff_id: plan?.staff_id ?? "", resource_ids: plan?.resource_ids ?? [], starts_on: plan?.starts_on ?? todayInput(tz), ends_on: plan?.ends_on ?? "", is_active: plan?.is_active ?? true, notes: plan?.notes ?? "",
  }));
  const set = (k) => (e) => setF((x) => ({ ...x, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.value }));
  const toggleRes = (id) => setF((x) => ({ ...x, resource_ids: x.resource_ids.includes(id) ? x.resource_ids.filter((r) => r !== id) : [...x.resource_ids, id] }));
  const preview = describePlan({ ...f, weekday: Number(f.weekday), month_day: Number(f.month_day) });
  const submit = (e) => {
    e.preventDefault();
    if (busy || !f.title.trim()) return;
    onSave({ ...f, customer_id: person?.id ?? null, interval_count: Number(f.interval_count), duration_minutes: Number(f.duration_minutes),
      weekday: f.frequency === "weekly" ? Number(f.weekday) : null, month_day: f.frequency === "monthly" ? Number(f.month_day) : null,
      staff_id: f.staff_id || null, ends_on: f.ends_on || null });
  };
  return (
    <Modal title={plan ? `Edit ${plan.title}` : "Add a recurring plan"} icon="event_repeat" onClose={onClose} busy={busy} wide description={preview}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-plan" className="ba-btn primary" disabled={busy || !f.title.trim()}>{busy ? "Saving…" : "Save plan"}</button></>}>
      <form id="ba-plan" className="ba-modal-body ba-form-grid" onSubmit={submit}>
        <Field label="Title"><input value={f.title} maxLength={120} onChange={set("title")} placeholder="e.g. Fortnightly clean" required /></Field>
        <Field label="Service (optional)" hint="Used to pick resources the service needs."><input value={f.service} maxLength={80} onChange={set("service")} /></Field>
        <PersonPicker businessId={workspace.id} label="Customer (optional)" value={person} onChange={setPerson} />
        <Field label="Repeats">
          <select value={f.frequency} onChange={set("frequency")}><option value="weekly">Weekly</option><option value="monthly">Monthly</option></select>
        </Field>
        <Field label={f.frequency === "weekly" ? "Every how many weeks" : "Every how many months"}><input type="number" min={1} max={12} value={f.interval_count} onChange={set("interval_count")} /></Field>
        {f.frequency === "weekly"
          ? <Field label="On"><select value={f.weekday} onChange={set("weekday")}>{WEEKDAY_OPTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
          : <Field label="On day of the month" hint="1 to 28, so it happens every month."><input type="number" min={1} max={28} value={f.month_day} onChange={set("month_day")} /></Field>}
        <Field label="At"><input type="time" value={f.start_at} onChange={set("start_at")} required /></Field>
        <Field label="Minutes"><input type="number" min={5} max={720} value={f.duration_minutes} onChange={set("duration_minutes")} /></Field>
        <Field label="With (optional)">
          <select value={f.staff_id} onChange={set("staff_id")}><option value="">Anyone (assign later)</option>{staff.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
        </Field>
        <Field label="Starts"><input type="date" value={f.starts_on} onChange={set("starts_on")} required /></Field>
        <Field label="Ends (optional)"><input type="date" value={f.ends_on} min={f.starts_on} onChange={set("ends_on")} /></Field>
        {resources.length > 0 && (
          <fieldset className="ba-prefs"><legend>Uses (optional)</legend>
            {resources.map((r) => <label key={r.id} className="ba-check"><input type="checkbox" checked={f.resource_ids.includes(r.id)} onChange={() => toggleRes(r.id)} /><span>{r.name}</span></label>)}
          </fieldset>
        )}
        <Field label="Notes (optional)" full><input value={f.notes} maxLength={500} onChange={set("notes")} /></Field>
        {plan && <label className="ba-check"><input type="checkbox" checked={f.is_active} onChange={set("is_active")} /><span>Active (untick to pause; booked visits stay)</span></label>}
      </form>
    </Modal>
  );
}
