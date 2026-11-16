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
