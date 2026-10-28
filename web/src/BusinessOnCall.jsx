import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill } from "./BusinessUI";
import { makeTerm } from "./businessWorkspace";
import { formatDay, formatTime, todayInput, zonedDateTime } from "./businessTime";
import { Empty, friendly, useLoad } from "./BusinessShared";

// On call: who the phone assistant puts urgent after-hours calls through to. A weekly rota plus one-off cover;
// cover wins. Read and saved through zella_on_call_* (sql/zella_on_call.sql); phone numbers stay on the server.

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const ORDER = [1, 2, 3, 4, 5, 6, 0];
const CODES = {
  STAFF_NEEDS_PHONE: "This person needs a phone number first. Add it with Edit hours.",
  INVALID_STAFF: "Pick someone who still works here.",
  INVALID_TIMES: "Those times don't work. Check the days and times.",
  TOO_MANY_SHIFTS: "That's the most shifts one rota can hold. Remove some first.",
};
const say = (error) => CODES[error?.message?.trim()] ?? friendly(error);

function ShiftModal({ workspace, staff, onClose, onSaved }) {
  const term = makeTerm(workspace);
  const tz = workspace.timezone;
  const today = todayInput(tz);
  const [form, setForm] = useState({
    kind: "weekly", staffId: staff.find((s) => s.has_phone)?.id ?? "", days: [1, 2, 3, 4, 5], starts: "18:00", ends: "08:00",
    fromDate: today, fromTime: "18:00", toDate: today, toTime: "23:59", note: "",
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (key) => (e) => setForm({ ...form, [key]: e.target.value });
  const toggleDay = (d) => setForm({ ...form, days: form.days.includes(d) ? form.days.filter((x) => x !== d) : [...form.days, d] });

  async function save(event) {
    event.preventDefault();
    if (!form.staffId) return setError(`Pick a ${term("staff").toLowerCase()}.`);
    const shifts = [];
    if (form.kind === "weekly") {
      if (!form.days.length) return setError("Pick at least one day.");
      if (form.starts === form.ends) return setError("The start and end time can't be the same.");
      for (const weekday of form.days) shifts.push({ kind: "weekly", staff_id: form.staffId, weekday, starts: form.starts, ends: form.ends, note: form.note });
    } else {
      const from = zonedDateTime(form.fromDate, form.fromTime, tz);
      const to = zonedDateTime(form.toDate, form.toTime, tz);
      if (to <= from) return setError("The end must be after the start.");
      if (to - from > 31 * 86400000) return setError("Cover can last up to 31 days. Add another one for longer.");
      shifts.push({ kind: "cover", staff_id: form.staffId, starts_at: from.toISOString(), ends_at: to.toISOString(), note: form.note });
    }
    setBusy(true);
    setError("");
    for (const shift of shifts) {
      const { error: saveError } = await supabase.rpc("zella_on_call_save", { p_business_id: workspace.id, p_shift: shift });
      if (saveError) { setBusy(false); return setError(say(saveError)); }
    }
    setBusy(false);
    onSaved(form.kind === "weekly" ? "Added to the weekly rota." : "Cover added. It takes over from the weekly rota for that time.");
  }

  const overnight = form.kind === "weekly" && form.ends < form.starts;
  return (
    <Modal icon="support_agent" title="Add on-call time" busy={busy} onClose={onClose}
      description={`Times are in ${workspace.name}'s time zone (${tz.replace("_", " ")}). Only people with a phone number can be on call.`}>
      <form className="ba-form-grid ba-modal-body" onSubmit={save}>
        {error && <div className="ba-banner error full">{error}</div>}
        <div className="ba-segment full" role="group" aria-label="Kind">
          <button type="button" className={form.kind === "weekly" ? "active" : ""} onClick={() => setForm({ ...form, kind: "weekly" })}>Every week</button>
          <button type="button" className={form.kind === "cover" ? "active" : ""} onClick={() => setForm({ ...form, kind: "cover" })}>One-off cover</button>
        </div>
        <Field label="Who" full>
          <select value={form.staffId} onChange={set("staffId")} required>
            <option value="">Choose…</option>
            {staff.map((s) => <option key={s.id} value={s.id} disabled={!s.has_phone}>{s.name}{s.has_phone ? "" : " (no phone number)"}</option>)}
          </select>
        </Field>
        {form.kind === "weekly" ? (
          <>
            <div className="ba-field full" role="group" aria-label="Days">
              <span>Days it starts on</span>
              <div className="ba-day-picks">
                {ORDER.map((d) => (
                  <button type="button" key={d} className={`ba-btn sm ${form.days.includes(d) ? "primary" : ""}`} aria-pressed={form.days.includes(d)} onClick={() => toggleDay(d)}>
                    {WEEKDAYS[d].slice(0, 3)}
                  </button>
                ))}
              </div>
            </div>
            <Field label="From"><input type="time" value={form.starts} onChange={set("starts")} required /></Field>
            <Field label="Until" hint={overnight ? "Runs past midnight into the next morning." : undefined}><input type="time" value={form.ends} onChange={set("ends")} required /></Field>
          </>
        ) : (
          <>
            <Field label="Starts"><input type="date" value={form.fromDate} onChange={set("fromDate")} required /></Field>
            <Field label="At"><input type="time" value={form.fromTime} onChange={set("fromTime")} required /></Field>
            <Field label="Ends"><input type="date" value={form.toDate} min={form.fromDate} onChange={set("toDate")} required /></Field>
            <Field label="At"><input type="time" value={form.toTime} onChange={set("toTime")} required /></Field>
          </>
        )}
        <Field label="Note (optional)" full><input value={form.note} maxLength={200} onChange={set("note")} placeholder="For example: covering for Sam" /></Field>
        <div className="full ba-form-actions">
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Add"}</button>
        </div>
      </form>
    </Modal>
  );
}

export function OnCallPanel({ workspace, refreshKey, onNotice }) {
  const tz = workspace.timezone;
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState(false);
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: result, error: loadError } = await supabase.rpc("zella_on_call_list", { p_business_id: workspace.id });
    if (loadError) throw new Error(say(loadError));
    return result;
  }, [workspace.id, refreshKey]);

  const settings = data?.settings ?? { enabled: false, scope: "after_hours" };
  const canEdit = Boolean(data?.can_edit);
  const weekly = (data?.shifts ?? []).filter((s) => s.kind === "weekly")
    .sort((a, b) => ORDER.indexOf(a.weekday) - ORDER.indexOf(b.weekday) || a.starts.localeCompare(b.starts));
  const cover = (data?.shifts ?? []).filter((s) => s.kind === "cover");

  async function saveSettings(next) {
    setBusy(true);
    const { error: saveError } = await supabase.rpc("zella_on_call_settings_save", { p_business_id: workspace.id, p_enabled: next.enabled, p_scope: next.scope });
    setBusy(false);
    if (saveError) return onNotice(say(saveError));
    onNotice(next.enabled ? "On-call transfers are on." : "On-call transfers are off. After-hours calls get a message and a callback.");
    reload();
  }
  async function remove(shift) {
    const { error: deleteError } = await supabase.rpc("zella_on_call_delete", { p_business_id: workspace.id, p_shift_id: shift.id });
    if (deleteError) return onNotice(say(deleteError));
    onNotice("Removed from the rota.");
    reload();
  }

  const shiftRow = (s) => (
    <li key={s.id}>
      <span className="ba-thread-icon"><Icon name={s.kind === "weekly" ? "event_repeat" : "swap_horiz"} size="sm" /></span>
      <div>
        <strong>{s.staff_name}</strong>
        <small>
          {s.kind === "weekly"
            ? `${WEEKDAYS[s.weekday]} ${s.starts} to ${s.ends}${s.ends < s.starts ? " (next morning)" : ""}`
            : `${formatDay(s.starts_at, tz)} ${formatTime(s.starts_at, tz)} to ${formatDay(s.ends_at, tz)} ${formatTime(s.ends_at, tz)}`}
          {s.note ? ` · ${s.note}` : ""}
        </small>
      </div>
      <div className="ba-thread-meta">
        {!s.has_phone && <Pill tone="warning">No phone</Pill>}
        {!s.staff_active && <Pill tone="warning">Left</Pill>}
        {canEdit && <button type="button" className="ba-btn sm" onClick={() => remove(s)}>Remove</button>}
      </div>
    </li>
  );

  return (
    <section className="ba-panel ba-gap">
      <div className="ba-panel-head">
        <div className="ba-panel-title">
          <div>
            <h2>On call</h2>
            <p>Who your AI receptionist puts calls through to while you're closed. One-off cover beats the weekly rota.</p>
          </div>
        </div>
        {canEdit && <button type="button" className="ba-btn sm" onClick={() => setAdding(true)} disabled={!data?.staff?.length}><Icon name="add" size="sm" /><span>Add time</span></button>}
      </div>
      <div className="ba-panel-body">
        {error && <div className="ba-banner error"><span>{error}</span><button type="button" className="ba-btn sm" onClick={reload}>Try again</button></div>}
        {data && (
          <div className="ba-oncall-now">
            <span className="ba-oncall-who">
              <Pill tone={settings.enabled && data.now ? "success" : ""} dot={settings.enabled && Boolean(data.now)} pulse>
                {!settings.enabled ? "Off" : data.now ? "On call" : "Nobody"}
              </Pill>
              {settings.enabled && <strong>{data.now ? data.now.name : "No one is on call right now"}</strong>}
            </span>
            {canEdit ? (
              <div className="ba-oncall-controls">
                <label className="ba-check"><input type="checkbox" checked={settings.enabled} disabled={busy} onChange={(e) => saveSettings({ ...settings, enabled: e.target.checked })} /><span>Put after-hours calls through to whoever is on call</span></label>
                <select value={settings.scope} disabled={busy || !settings.enabled} onChange={(e) => saveSettings({ ...settings, scope: e.target.value })} aria-label="Which calls">
                  <option value="after_hours">Anyone who asks for a person</option>
                  <option value="emergencies_only">Emergencies only</option>
                </select>
              </div>
            ) : (
              <small>{settings.enabled ? (settings.scope === "emergencies_only" ? "Emergencies only." : "Anyone who asks for a person.") : "Ask an owner or manager to set it up."}</small>
            )}
          </div>
        )}
        {loading && !data ? <p className="ba-muted">Loading…</p> : !weekly.length && !cover.length ? (
          <Empty title="No on-call rota yet" icon="support_agent">
            Add who covers evenings and weekends. Until then, after-hours callers get a message and a callback.
          </Empty>
        ) : (
          <ul className="ba-threads">{cover.map(shiftRow)}{weekly.map(shiftRow)}</ul>
        )}
      </div>
      {adding && (
        <ShiftModal workspace={workspace} staff={data?.staff ?? []} onClose={() => setAdding(false)}
          onSaved={(message) => { setAdding(false); onNotice(message); reload(); }} />
      )}
    </section>
  );
}
