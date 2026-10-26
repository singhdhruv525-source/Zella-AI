import { useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon } from "./BusinessUI";
import { Empty, friendly } from "./BusinessShared";
import { formatDay } from "./businessTime";
import { addLeaveGuard } from "./router";

// Opening hours, split shifts and holidays (sql/zella_business_settings.sql).
// The phone assistant reads these to tell callers whether the business is open.

export const SAY = {
  NAME_REQUIRED: "Enter the business name.",
  BAD_EMAIL: "That email address doesn't look right.",
  BAD_PHONE: "Enter the phone number with its country code, for example +1 555 123 4567.",
  BAD_WEBSITE: "The website must start with https:// (or http://).",
  BAD_COUNTRY: "Choose a country.",
  BAD_TIMEZONE: "Choose a time zone from the list.",
  BAD_HOURS: "Check the opening and closing times.",
  CLOSES_BEFORE_OPENS: "A closing time must be later than the opening time.",
  HOURS_OVERLAP: "Two time ranges on the same day overlap.",
  BAD_DATES: "Check the dates: the last day can't be before the first, and at most a year apart.",
  IN_THE_PAST: "That date has already passed.",
  NO_PHONE: "Add your mobile number under My account first.",
};
export const say = (error) => {
  const code = Object.keys(SAY).find((k) => (error?.message ?? "").includes(k));
  return code ? SAY[code] : friendly(error);
};

// Holiday dates are calendar days (no time), so show them as written, never shifted by a time zone.
const calendarDay = (d) => formatDay(`${d}T12:00:00Z`, "UTC");

const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0];


export function Panel({ title, sub, children, foot }) {
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>{title}</h2>{sub && <p>{sub}</p>}</div></div></div>
      <div className="ba-panel-body">{children}</div>
      {foot && <div className="ba-panel-foot">{foot}</div>}
    </section>
  );
}

export function Status({ text, error }) {
  if (error) return <div className="ba-banner error" role="alert"><span>{error}</span></div>;
  return text ? <p className="ba-muted" role="status">{text}</p> : null;
}

/* ---------- Hours & holidays ---------- */
export function HoursSection({ workspace, settings, onSaved }) {
  const canEdit = settings.can_edit_hours;
  const toRanges = () => Object.fromEntries(WEEK_ORDER.map((d) => [d, settings.hours.filter((h) => h.weekday === d).map((h) => ({ opens: h.opens, closes: h.closes }))]));
  const [days, setDays] = useState(toRanges);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState({ text: "", error: "" });
  const [closure, setClosure] = useState({ starts_on: "", ends_on: "", label: "", special: false, opens: "10:00", closes: "14:00" });

  const update = (day, fn) => setDays((all) => ({ ...all, [day]: fn(all[day]) }));
  // Unsaved hours are protected like other settings forms.
  const saved = useRef(JSON.stringify(toRanges()));
  const dirty = useRef(false);
  dirty.current = JSON.stringify(days) !== saved.current;
  useEffect(() => addLeaveGuard(() => dirty.current), []);
  const notSet = !settings.hours.length;

  async function saveHours() {
    setBusy(true);
    setStatus({ text: "", error: "" });
    const rows = WEEK_ORDER.flatMap((d) => days[d].map((r) => ({ weekday: d, opens: r.opens, closes: r.closes })));
    const { error } = await supabase.rpc("zella_save_business_hours", { p_business_id: workspace.id, p_hours: rows });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    saved.current = JSON.stringify(days);
    setStatus({ text: rows.length ? "Opening hours saved. Your AI receptionist uses them on the next call." : "Hours cleared. Your AI receptionist won't tell callers you're closed.", error: "" });
    onSaved();
  }

  async function addClosure(event) {
    event.preventDefault();
    setBusy(true);
    setStatus({ text: "", error: "" });
    const { error } = await supabase.rpc("zella_add_business_closure", {
      p_business_id: workspace.id, p_starts_on: closure.starts_on, p_ends_on: closure.ends_on || closure.starts_on,
      p_label: closure.label || (closure.special ? "Special hours" : "Closed"),
      p_opens: closure.special ? closure.opens : null, p_closes: closure.special ? closure.closes : null,
    });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setClosure({ starts_on: "", ends_on: "", label: "", special: false, opens: "10:00", closes: "14:00" });
    setStatus({ text: "Added.", error: "" });
    onSaved();
  }

  async function removeClosure(c) {
    if (!window.confirm(`Remove "${c.label}" (${calendarDay(c.starts_on)})?`)) return;
    setBusy(true);
    const { error } = await supabase.rpc("zella_delete_business_closure", { p_closure_id: c.id });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setStatus({ text: "Removed.", error: "" });
    onSaved();
  }

  return (
    <>
      <Panel
        title="Opening hours"
        sub={`In ${(settings.business.timezone || workspace.timezone).replace(/_/g, " ")}. Your AI receptionist uses these to say whether you're open.${canEdit ? "" : " Only an owner, admin or manager can change them."}`}
        foot={canEdit && <><span /><button type="button" className="ba-btn primary" onClick={saveHours} disabled={busy}>{busy ? "Saving…" : "Save hours"}</button></>}
      >
        <Status {...status} />
        {notSet && <p className="ba-muted">Hours aren't set yet. Until they are, callers are never told you're closed.</p>}
        <div className="ba-hours">
          {WEEK_ORDER.map((d) => (
            <div key={d} className="ba-hours-day">
              <strong>{DAY_NAMES[d]}</strong>
              <div>
                {!days[d].length && <span className="ba-muted">Closed</span>}
                {days[d].map((r, i) => (
                  <div key={i} className="ba-hours-range">
                    <input type="time" aria-label={`${DAY_NAMES[d]} opens`} value={r.opens} disabled={!canEdit || busy}
                      onChange={(e) => update(d, (rs) => rs.map((x, j) => (j === i ? { ...x, opens: e.target.value } : x)))} />
                    <span>to</span>
                    <input type="time" aria-label={`${DAY_NAMES[d]} closes`} value={r.closes} disabled={!canEdit || busy}
                      onChange={(e) => update(d, (rs) => rs.map((x, j) => (j === i ? { ...x, closes: e.target.value } : x)))} />
                    {canEdit && <button type="button" className="ba-btn ghost sm" aria-label="Remove these hours" onClick={() => update(d, (rs) => rs.filter((_, j) => j !== i))}><Icon name="close" size="sm" /></button>}
                  </div>
                ))}
                {canEdit && days[d].length < 6 && (
                  <button type="button" className="ba-link" disabled={busy}
                    onClick={() => update(d, (rs) => [...rs, rs.length ? { opens: rs[rs.length - 1].closes, closes: "23:00" } : { opens: "09:00", closes: "17:00" }])}>
                    {days[d].length ? "Add another time" : "Add hours"}
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </Panel>

      <Panel title="Holidays and special days" sub="Days you're closed, or open different hours. Past days drop off the list.">
        {!settings.closures.length ? <Empty title="Nothing planned">Add a holiday so callers hear you're closed that day.</Empty> : (
          <ul className="ba-list">
            {settings.closures.map((c) => (
              <li key={c.id} className="ba-list-row">
                <div>
                  <strong>{c.label}</strong>
                  <small>
                    {calendarDay(c.starts_on)}{c.ends_on !== c.starts_on ? ` – ${calendarDay(c.ends_on)}` : ""}
                    {" · "}{c.opens ? `${c.opens}–${c.closes}` : "Closed all day"}
                  </small>
                </div>
                {canEdit && <button type="button" className="ba-btn sm" onClick={() => removeClosure(c)} disabled={busy}>Remove</button>}
              </li>
            ))}
          </ul>
        )}
        {canEdit && (
          <form className="ba-form-grid" onSubmit={addClosure} style={{ marginTop: 14 }}>
            <Field label="First day"><input type="date" required value={closure.starts_on} onChange={(e) => setClosure({ ...closure, starts_on: e.target.value })} /></Field>
            <Field label="Last day" hint="Leave empty for one day."><input type="date" value={closure.ends_on} min={closure.starts_on || undefined} onChange={(e) => setClosure({ ...closure, ends_on: e.target.value })} /></Field>
            <Field label="Name" hint="For example: Christmas Day"><input value={closure.label} maxLength={80} onChange={(e) => setClosure({ ...closure, label: e.target.value })} /></Field>
            <Field label="That day">
              <select value={closure.special ? "special" : "closed"} onChange={(e) => setClosure({ ...closure, special: e.target.value === "special" })}>
                <option value="closed">Closed all day</option>
                <option value="special">Open special hours</option>
              </select>
            </Field>
            {closure.special && <>
              <Field label="Opens"><input type="time" required value={closure.opens} onChange={(e) => setClosure({ ...closure, opens: e.target.value })} /></Field>
              <Field label="Closes"><input type="time" required value={closure.closes} onChange={(e) => setClosure({ ...closure, closes: e.target.value })} /></Field>
            </>}
            <div className="ba-form-actions full"><button type="submit" className="ba-btn" disabled={busy || !closure.starts_on}>Add day</button></div>
          </form>
        )}
      </Panel>
    </>
  );
}
