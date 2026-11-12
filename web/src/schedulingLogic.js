// Release 2: words and rules for resources, dispatch and recurring plans (sql/zella_scheduling.sql). The server decides
// who may do what and refuses double-bookings; this only explains it. Unit tests: web/tests/release2_unit.test.mjs.

export const RESOURCE_KINDS = [
  ["room", "Room"], ["chair", "Chair or station"], ["bay", "Service bay"], ["equipment", "Equipment"],
  ["space", "Shared space (holds several)"], ["vehicle", "Vehicle"], ["other", "Other"],
];
export const KIND_LABEL = Object.fromEntries(RESOURCE_KINDS);

// A blocked time with neither a person nor a resource closes the whole business (a holiday, a training day). A block on
// a resource (a room or bay out for maintenance) doesn't: only bookings that use that resource are refused, by the
// database (zella_resource_guard). Slot search follows the same rule (sql/zella_slots_resource_blocks.sql).
export const blocksEveryone = (b) => !b.staff_id && !b.resource_id;
// does this block apply to this person (theirs, or the whole business's)?
export const blockCovers = (b, staffId) => blocksEveryone(b) || (Boolean(b.staff_id) && b.staff_id === staffId);

// A move onto a room, chair or bay that is blocked then can't be overridden: the database refuses it for a booking that
// holds its time from now on (zella_resource_guard; past visits never clash). Returns the refusal, or null.
export function resourceRefusal({ blocks, start, end, resourceIds }) {
  const uses = new Set(resourceIds ?? []);
  if (!uses.size || end <= new Date()) return null;
  const block = (blocks ?? []).find((b) => b.resource_id && uses.has(b.resource_id) && new Date(b.start_time) < end && new Date(b.end_time) > start);
  return block ? `That room, chair or bay is blocked then (${block.title}). Pick another time.` : null;
}


// a job's state on the board, in words and a tone
export const JOB_STATUS = {
  unassigned: ["Unassigned", "danger"], assigned: ["Assigned", ""], en_route: ["On the way", "info"], on_site: ["On site", "info"],
  paused: ["Paused", "warning"], completed: ["Completed", "success"], needs_return: ["Needs a return visit", "warning"],
};

// the steps the server allows from each state (zella_dispatch_status), with the button words
export const NEXT_STEPS = {
  assigned: [["en_route", "On the way"], ["on_site", "Arrived"]],
  en_route: [["on_site", "Arrived"], ["assigned", "Not going yet"]],
  on_site: [["completed", "Complete"], ["paused", "Pause"], ["needs_return", "Needs a return visit"]],
  paused: [["on_site", "Resume"], ["needs_return", "Needs a return visit"]],
};
export const nextSteps = (status) => NEXT_STEPS[status] ?? [];

const fmt = (date, timeZone, opts) => new Intl.DateTimeFormat("en-US", { timeZone, ...opts }).format(new Date(date));
const timeOf = (date, timeZone) => fmt(date, timeZone, { hour: "numeric", minute: "2-digit" });

// "Arrive 9:00 AM - 11:00 AM" when the business works with arrival windows, else the start time
export function arrivalText(start, windowMinutes, timeZone) {
  if (!start) return "";
  if (!windowMinutes) return timeOf(start, timeZone);
  return `Arrive ${timeOf(start, timeZone)} - ${timeOf(new Date(new Date(start).getTime() + windowMinutes * 60000), timeZone)}`;
}

export function checklistProgress(items) {
  const list = Array.isArray(items) ? items : [];
  const done = list.filter((i) => i.done).length;
  const missing = list.filter((i) => i.required && !i.done).length;
  return { done, total: list.length, missing, text: list.length ? `${done} of ${list.length} done${missing ? ` · ${missing} required left` : ""}` : "" };
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
export const WEEKDAY_OPTIONS = WEEKDAYS.map((d, i) => [i, d]);
const ordinal = (n) => `${n}${["th", "st", "nd", "rd"][(n % 100 >= 11 && n % 100 <= 13) ? 0 : (n % 10 < 4 ? n % 10 : 0)]}`;
function clock(hhmm) {
  const [h, m] = String(hhmm ?? "").split(":").map(Number);
  if (!Number.isFinite(h)) return "";
  return `${((h + 11) % 12) + 1}:${String(m || 0).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`;
}

// "Every 2 weeks on Tuesday at 9:00 AM", "Monthly on the 15th at 1:00 PM"
export function describePlan(plan) {
  if (!plan) return "";
  const n = Number(plan.interval_count) || 1;
  const at = plan.start_at ? ` at ${clock(plan.start_at)}` : "";
  if (plan.frequency === "monthly") {
    return `${n === 1 ? "Monthly" : `Every ${n} months`} on the ${ordinal(Number(plan.month_day))}${at}`;
  }
  return `${n === 1 ? "Every week" : `Every ${n} weeks`} on ${WEEKDAYS[Number(plan.weekday)] ?? "?"}${at}`;
}

const ERRORS = [
  [/SLOT_TAKEN/, (e) => {
    const d = `${e?.details ?? ""}`;
    if (/crew/.test(d)) return "Someone on that crew is already on another job then. Pick other people or another time.";
    if (/resource this service needs/.test(d)) return "No room, chair or other resource this service needs is free then. Pick another time.";
    if (/is booked, full or blocked then/.test(d)) return `${d.replace(" is booked, full or blocked then", "")} is booked, full or blocked then. Pick another time or another one.`;
    return "That person or resource is already booked then. Pick another time or someone else.";
  }],
  [/\bCHANGED\b/, () => "This job changed while you were looking at it, so nothing was done. Check it as it is now and try again."],
  [/BAD_STEP/, () => "That step doesn't follow from where the job is now. The board has been refreshed."],
  [/CHECKLIST_INCOMPLETE/, () => "Tick the required checklist items before completing the job."],
  [/NOT_ASSIGNED/, () => "Assign the job to someone first."],
  [/NOT_OPEN/, () => "This job is already finished or canceled."],
  [/BAD_DATE/, () => "Pick a time that hasn't passed."],
  [/TENANT_MISMATCH/, () => "One of those people or resources isn't part of this business any more. Refresh and pick again."],
  [/resources_one_name/, () => "There's already a resource with that name."],
  [/resource_needs_one/, () => "Each service and kind can be listed once. Remove the repeated row."],
  [/23505|duplicate key/, () => "That already exists. Refresh and try again."],
  [/resources_capacity/, () => "Capacity is how many it holds at once: 1 to 500."],
  [/resources_buffer/, () => "The gap after each booking can be 0 to 240 minutes."],
  [/resources_name_len|recurring_plans_title_len/, () => "Give it a name (up to 80 characters)."],
  [/resource_needs_service_len/, () => "Each service name needs at least 2 characters."],
  [/recurring_plans_day/, () => "Pick the day it happens on."],
  [/recurring_plans_dates/, () => "The end date can't be before the start."],
  [/recurring_plans_duration/, () => "A visit can be 5 to 720 minutes."],
  [/NOT_VALID/, () => "That person, record or resource isn't part of this business. Pick again."],
  [/NOT_FOUND/, () => "That item has changed or was removed. Refresh and try again."],
  [/NOT_ALLOWED|permission denied|42501/, () => "You don't have permission to do that here."],
  [/MFA_REQUIRED/, () => "Enter the code from your authenticator app first: sign out and sign in again."],
  [/failed to fetch|network|load failed/i, () => "Couldn't reach Zella Voice. Nothing was changed; try again."],
  [/zella_dispatch|zella_resource|zella_recurring|schema cache|Could not find the function/, () => "This isn't available on this workspace yet. Ask the Zella Voice team."],
];
export function scheduleError(error) {
  const text = `${error?.message ?? ""} ${error?.code ?? ""}`;
  for (const [re, msg] of ERRORS) if (re.test(text)) return msg(error);
  return "That didn't work. Try again, or contact Zella Voice support if it keeps happening.";
}
