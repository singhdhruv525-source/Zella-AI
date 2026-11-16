// Users & access: what the page says after an admin's access changes (ACC-18).

// After a removal or role change, owner-provision-business signs the person out on every device and returns how many
// sessions ended (sessionsEnded), or null with sessionsWarning when that failed.
export function signedOutText(result) {
  const n = result?.sessionsEnded;
  if (n === null || n === undefined) return result?.sessionsWarning ?? "";
  if (n === 0) return "They had no signed in devices.";
  return `They were signed out on ${n === 1 ? "1 device" : `${n} devices`}.`;
}

export const SIGNED_OUT_EVERYWHERE = "They will be signed out on every device.";

// ACC-19: granting or changing admin access needs an authenticator code entered in the last 5 minutes. The server
// answers FRESH_CODE_REQUIRED; Users & access asks for a new code (verifyMfaCode in mfa.js issues a session with a
// new code time) and runs the same change again.
export const needsFreshCode = (err) => err?.code === "FRESH_CODE_REQUIRED";

// ACC-15: why the server refused an admin request, in words.
const REFUSAL_REASONS = {
  NOT_ADMIN: "Not a Zella Voice admin",
  MFA_REQUIRED: "Two step sign in code not entered",
  MFA_SETUP_REQUIRED: "Two step sign in not set up",
  NOT_PERMITTED: "Their role doesn't allow it",
};
export function refusalReason(r) {
  const base = REFUSAL_REASONS[r?.code] ?? "Refused";
  return r?.code === "NOT_PERMITTED" && r.permission ? `${base} (${r.permission})` : base;
}

// ACC-12: the Action filter lists every audit action in the shared list (web/supabase/functions/_shared/catalog.json),
// by label; the page's labels come from the same list, falling back to ownerFormat.js.
export function auditActionOptions(catalog) {
  return Object.entries(catalog?.audit_actions ?? {}).map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label));
}

// The filters to send: empty ones are left out.
export function auditQuery(f) {
  return Object.fromEntries(Object.entries(f ?? {}).map(([k, v]) => [k, typeof v === "string" ? v.trim() : v]).filter(([, v]) => v));
}

// OPS-25: business hours in words ("3.5 business hours", "Under an hour").
export function businessHoursText(h) {
  if (h === null || h === undefined || !Number.isFinite(h)) return "";
  if (h < 1) return "under a business hour";
  const n = Math.round(h * 10) / 10;
  return `${n} business ${n === 1 ? "hour" : "hours"}`;
}
