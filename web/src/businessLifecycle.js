// Business lifecycle helpers for the admin pages (Lane B: BIZ-13a, BIZ-13b).

// BIZ-13a default (owner can change): who may delete a never finished draft. The server checks the same list
// (lifecycle.ts DRAFT_DELETE_ROLES) and so does the database.
export const DRAFT_DELETE_ROLES = ["zella_owner", "super_admin"];

// "Today", "Yesterday" or "12 days ago": how long since a draft last changed (BIZ-13b), by calendar day in the
// viewer's time zone (a change at 23:30 is "Yesterday" at 00:30), never by 24 hour blocks.
export function since(at, now = Date.now()) {
  const t = Date.parse(at ?? "");
  if (!Number.isFinite(t)) return "Not known";
  const day = (ms) => { const d = new Date(ms); return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 86_400_000; };
  const days = day(now) - day(t);
  return days <= 0 ? "Today" : days === 1 ? "Yesterday" : `${days} days ago`;
}

// BIZ-13c: where a cancelled business stands against its retention date: [label, pill tone].
export function retentionState(b, now = Date.now()) {
  const t = Date.parse(b?.retention_until ?? "");
  if (!Number.isFinite(t)) return ["No retention date", "warning"];
  if (b?.past_retention || t < now) return ["Past retention", "danger"];
  return ["Kept", "neutral"];
}

// UI-11: hours left before documents can be requested again (0 when they can be now).
export function requestWaitHours(lastRequestedAt, cooldownHours = 24, now = Date.now()) {
  const t = Date.parse(lastRequestedAt ?? "");
  if (!Number.isFinite(t)) return 0;
  return Math.max(0, Math.ceil(cooldownHours - (now - t) / 3_600_000));
}

// UI-11: what happened to a documents request, in words, from the server's answer.
export function documentRequestNotice(r) {
  const name = r?.name ?? "The business";
  if (r?.email === "queued") return `Request saved for ${name}. The email to ${r.to} is queued and goes out once email sending is live.`;
  if (r?.email === "not_installed") return `Request saved for ${name} in the audit log. Email isn't live yet, so tell the owner yourself.`;
  return `Request saved for ${name} in the audit log. There's no owner email address, so tell the owner yourself.`;
}

// SET-ONB-RETRY: what a person can do about a failed setup step. "retry" for internal steps (Retry step), "resend" for
// the owner invitation email, "setup" (Continue setup) for anything else. The server has the same list.
export const RETRYABLE_STEPS = ["modules", "receptionist", "automations"];
export function retryAction(step) {
  if (RETRYABLE_STEPS.includes(step)) return "retry";
  return step === "owner_invitation" ? "resend" : "setup";
}

// SET-DL-EXPORT: an export's state in words, with its pill tone.
const EXPORT_STATES = { requested: ["Waiting for approval", "warning"], approved: ["Approved, waiting to run", "accent"], running: ["Being prepared", "accent"],
  ready: ["Ready to download", "success"], failed: ["Failed", "danger"], rejected: ["Rejected", ""], expired: ["Expired", ""] };
export function exportState(j) {
  return EXPORT_STATES[j?.status] ?? ["Unknown", ""];
}

// UI-11: how long until the earliest request wait on the list ends (ms, at most an hour), or null when none is waiting.
// The list redraws then, so a button comes back on its own; the clock is also read again whenever the list loads.
export function nextRedrawMs(rows, cooldownHours = 24, now = Date.now()) {
  const ends = (rows ?? []).map((b) => Date.parse(b?.last_requested_at ?? "") + cooldownHours * 3_600_000).filter((t) => Number.isFinite(t) && t > now);
  return ends.length ? Math.min(Math.min(...ends) - now + 1000, 3_600_000) : null;
}
