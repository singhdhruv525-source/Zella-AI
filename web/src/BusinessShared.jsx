import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Icon } from "./BusinessUI";

// Small pieces shared by the business app pages and the person profile.

export const SOURCE_LABELS = {
  manual: "Team", phone: "Phone", walk_in: "Walk-in", website: "Website", google: "Google",
  meta: "Meta", referral: "Referral", call: "Call", voice: "Voice AI", other: "Other",
};
export const APPT_TONE = { scheduled: "warning", confirmed: "success", completed: "info", cancelled: "", no_show: "danger" };
export const APPT_LABEL = { scheduled: "Scheduled", confirmed: "Confirmed", completed: "Completed", cancelled: "Cancelled", no_show: "No-show" };
export const PAGE_SIZE = 25;

export const sourceLabel = (s) => SOURCE_LABELS[s] ?? (s ? s.replace(/_/g, " ") : "Other");
export const plural = (n, word, many) => `${n} ${n === 1 ? word : many ?? `${word}s`}`;
export const clock = (seconds) =>
  seconds || seconds === 0 ? `${Math.floor(seconds / 60)}:${String(Math.round(seconds % 60)).padStart(2, "0")}` : "—";

export function PageHead({ crumb, title, sub, children }) {
  return (
    <div className="ba-page-head">
      <div>
        <div className="ba-crumb">{crumb}</div>
        <h1>{title}</h1>
        {sub && <p>{sub}</p>}
      </div>
      {children && <div className="ba-page-actions">{children}</div>}
    </div>
  );
}

export function Segment({ value, onChange, options, label }) {
  return (
    <div className="ba-segment" role="tablist" aria-label={label}>
      {options.map(([key, text]) => (
        <button key={key} type="button" role="tab" aria-selected={value === key} className={value === key ? "active" : ""} onClick={() => onChange(key)}>
          {text}
        </button>
      ))}
    </div>
  );
}

export function Empty({ title, icon = "inbox", children }) {
  return (
    <div className="ba-empty">
      {icon && <span className="ba-empty-icon"><Icon name={icon} /></span>}
      {title && <strong>{title}</strong>}
      {children}
    </div>
  );
}

export function Notice({ error, onRetry }) {
  if (!error) return null;
  return (
    <div className="ba-banner error">
      <span>Couldn't load this page: {error}</span>
      {onRetry && <button type="button" className="ba-btn sm" onClick={onRetry}>Try again</button>}
    </div>
  );
}

// Runs a loader and keeps rows, loading and error state together.
export function useLoad(loader, deps) {
  const [state, setState] = useState({ data: null, error: "", loading: true });
  const run = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: "" }));
    try {
      const data = await loader();
      setState({ data, error: "", loading: false });
    } catch (err) {
      setState((s) => ({ ...s, error: err.message || String(err), loading: false }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { run(); }, [run]);
  return { ...state, reload: run };
}

export function orThrow(result) {
  if (result.error) throw result.error;
  return result.data ?? [];
}

// Names of the people referenced by other records.
export async function loadPeople(ids) {
  const unique = [...new Set(ids.filter(Boolean))];
  if (!unique.length) return {};
  const rows = orThrow(await supabase.from("customers").select("id, first_name, last_name, company_name, phone, email, address, do_not_contact, do_not_call, do_not_sms, do_not_email").in("id", unique));
  return Object.fromEntries(rows.map((p) => [p.id, p]));
}

export function Pager({ page, pages, total, onPage, noun }) {
  if (total <= PAGE_SIZE) return <div className="ba-table-foot"><span>{plural(total, noun)}</span></div>;
  return (
    <div className="ba-table-foot">
      <span>{plural(total, noun)} · page {page + 1} of {pages}</span>
      <div className="ba-page-actions">
        <button type="button" className="ba-btn sm" disabled={page === 0} onClick={() => onPage(page - 1)}>Previous</button>
        <button type="button" className="ba-btn sm" disabled={page >= pages - 1} onClick={() => onPage(page + 1)}>Next</button>
      </div>
    </div>
  );
}

export function transcriptLines(transcript) {
  if (!transcript) return [];
  if (typeof transcript === "string") return transcript.split("\n").map((t) => t.trim()).filter(Boolean).map((text) => ({ who: "", text }));
  if (Array.isArray(transcript)) {
    return transcript.map((m) => ({ who: m.role ?? m.speaker ?? "", text: m.text ?? m.content ?? m.message ?? "" })).filter((m) => m.text);
  }
  return [{ who: "", text: JSON.stringify(transcript) }];
}


const NEEDS_UPDATE = "Your workspace needs the latest Zella update before this can be saved. Please ask the Zella team.";
// Short codes raised by the database functions, in plain words.
const CODES = {
  NOT_ALLOWED: "You don't have permission to do that in this workspace.",
  NOT_SIGNED_IN: "Your session has ended. Please sign in again.",
  REASON_REQUIRED: "Pick a reason first.",
  BAD_INPUT: "Something in the form isn't valid. Check it and try again.",
  APPROVAL_REQUIRED: "A second owner or admin must approve this first. A request has been sent to them.",
};
export const friendly = (error) => {
  const message = error?.message ?? String(error);
  if (/does not exist|schema cache|Could not find the/i.test(message)) return NEEDS_UPDATE;
  if (/JWT expired|invalid JWT|refresh token/i.test(message)) return CODES.NOT_SIGNED_IN;
  return CODES[message.trim()] ?? message;
};

// Check a person in (they have arrived) or undo it.
export function setCheckIn(appointmentId, checkedIn) {
  return supabase.from("appointments")
    .update({ checked_in_at: checkedIn ? new Date().toISOString() : null, updated_at: new Date().toISOString() })
    .eq("id", appointmentId);
}

/* ---------- Team availability ---------- */
export const DAYS = [["mon", "Monday"], ["tue", "Tuesday"], ["wed", "Wednesday"], ["thu", "Thursday"], ["fri", "Friday"], ["sat", "Saturday"], ["sun", "Sunday"]];
export const DAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

export function defaultHours() {
  const hours = {};
  for (const [key] of DAYS) {
    const weekday = !["sat", "sun"].includes(key);
    hours[key] = { on: weekday, start: "09:00", end: "17:00", break_start: "", break_end: "" };
  }
  return hours;
}

// Minutes since midnight and weekday key for an instant in the business's zone.
function zonedClock(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date);
  const get = (type) => parts.find((p) => p.type === type)?.value;
  return { day: get("weekday").slice(0, 3).toLowerCase(), minutes: Number(get("hour")) * 60 + Number(get("minute")) };
}

const toMinutes = (t) => (t ? Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5)) : null);

// Is this team member available at a moment? Looks at weekly hours, the daily
// break, and any blocked time (time off) for them or for the whole business.
export function availabilityAt(member, blocks, date, timeZone) {
  const hours = member.working_hours && Object.keys(member.working_hours).length ? member.working_hours : null;
  const t = date.getTime();
  const block = (blocks ?? []).find((b) =>
    (!b.staff_id || b.staff_id === member.id) && new Date(b.start_time).getTime() <= t && new Date(b.end_time).getTime() > t);
  if (block) return { state: "off", label: `${block.title}${block.all_day ? "" : ` until ${formatClock(block.end_time, timeZone)}`}`, block };
  if (!hours) return { state: "available", label: "Available" };
  const { day, minutes } = zonedClock(date, timeZone);
  const d = hours[day];
  if (!d?.on) return { state: "off", label: "Not working today" };
  const start = toMinutes(d.start);
  const end = toMinutes(d.end);
  if (start != null && minutes < start) return { state: "off", label: `Starts at ${formatHM(d.start)}` };
  if (end != null && minutes >= end) return { state: "off", label: "Finished for today" };
  const bs = toMinutes(d.break_start);
  const be = toMinutes(d.break_end);
  if (bs != null && be != null && minutes >= bs && minutes < be) return { state: "break", label: `On break until ${formatHM(d.break_end)}` };
  return { state: "available", label: "Available" };
}

function formatHM(value) {
  const h = Number(value.slice(0, 2));
  return `${((h + 11) % 12) + 1}:${value.slice(3, 5)} ${h < 12 ? "AM" : "PM"}`;
}
function formatClock(value, timeZone) {
  return new Date(value).toLocaleTimeString("en-US", { timeZone, hour: "numeric", minute: "2-digit" });
}

// Why a booking can't go ahead, or null if the slot is free for that person.
export function findConflict({ staff, blocks, start, end, staffId, timeZone }) {
  const overlap = (blocks ?? []).find((b) =>
    (!b.staff_id || b.staff_id === staffId) && new Date(b.start_time) < end && new Date(b.end_time) > start);
  if (overlap) {
    const who = overlap.staff_id ? (staff ?? []).find((m) => m.id === overlap.staff_id)?.name ?? "This team member" : "The business";
    return `${who} is unavailable then (${overlap.title}).`;
  }
  const member = (staff ?? []).find((m) => m.id === staffId);
  if (member) {
    for (const probe of [start, new Date(end.getTime() - 60000)]) {
      const a = availabilityAt(member, [], probe, timeZone);
      if (a.state !== "available") return `${member.name}: ${a.label.toLowerCase()}.`;
    }
  }
  return null;
}

// After someone is marked a no-show: say what Zella will do next. The
// follow-up is queued by the database only when the "No-show follow-up"
// automation is live, so this reports what is really going to happen.
export async function noShowNotice(appointmentId, who, timeZone) {
  const base = `${who} marked no-show.`;
  const { data, error } = await supabase
    .from("followup_tasks")
    .select("due_at, channel")
    .eq("appointment_id", appointmentId)
    .eq("kind", "no_show_follow_up")
    .eq("status", "pending")
    .limit(1);
  if (error || !data?.length) return base;
  const due = new Date(data[0].due_at);
  const sameDay = due.toLocaleDateString("en-US", { timeZone }) === new Date().toLocaleDateString("en-US", { timeZone });
  const when = `${sameDay ? "" : `${due.toLocaleDateString("en-US", { timeZone, weekday: "short" })} `}${due.toLocaleTimeString("en-US", { timeZone, hour: "numeric", minute: "2-digit" })}`;
  return `${base} Zella will ${data[0].channel === "sms" ? "text" : "call"} around ${when} to offer a new time.`;
}

// Plain-language messages for the workflow functions' error codes.
const CODE_MESSAGES = {
  NOT_ALLOWED: "You don't have access to do that.",
  SLOT_TAKEN: "That time is no longer free. Pick another time.",
  BAD_TIME: "Times need to start on a 5-minute mark, like 10:00 or 10:05.",
  ALREADY_CLOSED: "This is already closed.",
  ALREADY_RESOLVED: "This was already handled.",
  ALREADY_CONFIRMED: "This booking is already confirmed.",
  REASON_REQUIRED: "Say why it was lost.",
  EMPTY_TITLE: "Give it a short title.",
  NO_CONTACT: "Add a phone number or email.",
  BAD_EMAIL: "That email doesn't look right.",
  NOT_VALID: "This version needs to pass the checks before it can go live.",
  NOT_A_MEMBER: "That person isn't on your team.",
  NOT_RESCHEDULABLE: "This appointment can't be moved.",
  BUSINESS_NOT_AVAILABLE: "This workspace is paused, so this can't be changed right now.",
  NOT_FOUND: "That item is no longer there. Refresh the page and try again.",
};
export function explain(error) {
  const text = error?.message ?? String(error ?? "");
  let m;
  if ((m = text.match(/FIELD_REQUIRED:([^\n]+)/))) return `Add ${m[1].trim().toLowerCase()} to continue.`;
  if ((m = text.match(/BAD_FIELD:([^\n]+)/))) return `Check "${m[1].trim()}". It isn't in the right format.`;
  if (text.includes("DUPLICATE:")) return "This looks like a record you already have.";
  if (text.includes("STATUS_IN_USE")) return "Some records still use a status you removed. Move them first, or keep the status.";
  if ((m = text.match(/FIELD_REMOVED:([^\n]+)/))) return `"${m[1].trim()}" can't be removed because it may hold information. Hide it from the table instead.`;
  if ((m = text.match(/FIELD_LOCKED:([^\n]+)/))) return `The type of "${m[1].trim()}" can't change once it exists.`;
  const code = Object.keys(CODE_MESSAGES).find((c) => text.includes(c));
  return code ? CODE_MESSAGES[code] : friendly(error);
}
