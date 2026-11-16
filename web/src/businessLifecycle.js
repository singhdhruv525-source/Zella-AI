// Business lifecycle helpers for the admin pages (Lane B: BIZ-13a, BIZ-13b).

// BIZ-13a default (owner can change): who may delete a never finished draft. The server checks the same list
// (lifecycle.ts DRAFT_DELETE_ROLES) and so does the database.
export const DRAFT_DELETE_ROLES = ["zella_owner", "super_admin"];

// "Today", "Yesterday" or "12 days ago": how long since a draft last changed (BIZ-13b).
export function since(at, now = Date.now()) {
  const t = Date.parse(at ?? "");
  if (!Number.isFinite(t)) return "Not known";
  const days = Math.floor((now - t) / 86_400_000);
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
