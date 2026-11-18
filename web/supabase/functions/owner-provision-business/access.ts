// Admin access (lane A): what happens to an admin's sessions when their access changes (ACC-18), and the admins' own
// security actions. index.ts imports this module next to platform.ts; every action listed in ACCESS_PERMISSIONS runs
// after index.ts has checked the caller's sign in, two step sign in, platform role and that permission.

import type { SupabaseClient } from "@supabase/supabase-js";
import catalog from "../_shared/catalog.json" with { type: "json" };

type Json = Record<string, unknown>;
type Access = { role: string; is_active: boolean };

// Every device of an admin who is deactivated or given another role is signed out (ACC-18). Their access token
// already issued keeps working until it expires, but index.ts reads the role again on every call, so the function
// refuses or limits them at once; ending the sessions stops any device from getting a new token.
export function endsSessions(before: Access, after: Access) {
  return (before.is_active && !after.is_active) || (after.is_active && before.role !== after.role);
}

export const SESSIONS_NOT_ENDED =
  "The change is saved, but their devices could not be signed out. They are refused on their next action; use Sign out everywhere to try again.";

// Returns how many sessions ended, or null with a warning when the database couldn't do it (for example before
// sql/zella_admin_sessions.sql is applied). The role change itself is never undone.
export async function endSessionsAfterChange(admin: SupabaseClient, userId: string, before: Access, after: Access) {
  if (!endsSessions(before, after)) return { sessionsEnded: 0 };
  const { data, error } = await admin.rpc("zella_end_user_sessions", { p_user_id: userId });
  if (error || typeof data !== "number") {
    console.error("Ending an admin's sessions failed", error?.message ?? data);
    return { sessionsEnded: null, sessionsWarning: SESSIONS_NOT_ENDED };
  }
  return { sessionsEnded: data };
}

// ACC-30: an admin's own two step sign in and password changes go through the server, so they are audited and the
// "keep at least one authenticator" rule (ACC-01) holds on the server too. Any active admin, for their own account
// only (index.ts lets SELF actions through for every role, like me_admin). me_mfa_remove and me_password_change also
// need a fresh code (mfa_gate.ts FRESH_CODE_ACTIONS).
export const SELF = "self";
export const ACCESS_PERMISSIONS: Record<string, string> = {
  security_refusals: "security.view",
  audit_export: "audit.view",
  me_mfa_added: SELF,
  me_mfa_remove: SELF,
  me_password_change: SELF,
};
export const SELF_ACTIONS = Object.keys(ACCESS_PERMISSIONS).filter((a) => ACCESS_PERMISSIONS[a] === SELF);

// The app's rule (web/src/formValidation.js passwordRules): 8 to 64 characters with a capital, a lower case letter
// and a number. Checked here too, so a direct call to the function meets the same rule as the page.
export function passwordProblem(p: unknown): string | null {
  if (typeof p !== "string" || !p) return "Enter a new password.";
  if (p.length < 8) return "Use at least 8 characters.";
  if (p.length > 64) return "Use no more than 64 characters.";
  if (!/[A-Z]/.test(p) || !/[a-z]/.test(p) || !/[0-9]/.test(p)) return "Use a capital, a lower case letter and a number.";
  return null;
}

// ACC-15: a refused call to the admin function is a security event. Recorded as audit 'security.admin_refused' with
// the ip and user agent, at most REFUSAL_LIMIT times per person and refusal code in each window (zella_rate_limit),
// so a flood can't fill the log. Recording never changes the answer, and a failure only logs. A call without a
// signed in person (401) isn't recorded: there is no one to attribute it to, and Supabase Auth logs those.
export const REFUSAL_LIMIT = { max: 5, windowSeconds: 600 };
export type RefusalContext = { userId: string; ip: string | null; userAgent: string | null };

export async function recordRefusal(admin: SupabaseClient, ctx: RefusalContext, refusal: { code: string; action?: unknown; permission?: string | null }) {
  try {
    const action = typeof refusal.action === "string" && /^[a-z_]{1,60}$/.test(refusal.action) ? refusal.action : null;
    const { data: allowed, error } = await admin.rpc("zella_rate_limit", {
      p_key: `refusal:${ctx.userId}:${refusal.code}`, p_max: REFUSAL_LIMIT.max, p_window_seconds: REFUSAL_LIMIT.windowSeconds,
    });
    if (error || allowed !== true) return false;
    const { error: insertError } = await admin.from("audit_logs").insert({
      user_id: ctx.userId, action: "security.admin_refused", entity_type: "admin_request",
      ip_address: ctx.ip, user_agent: ctx.userAgent,
      new_data: { code: refusal.code, action, permission: refusal.permission ?? null },
    });
    if (insertError) { console.error("Recording a refused admin call failed", insertError.message); return false; }
    return true;
  } catch (e) {
    console.error("Recording a refused admin call failed", e);
    return false;
  }
}

// ACC-12: audit log filters, a (created_at, id) cursor and an audited CSV export.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTION_NAME = /^[a-z][a-z0-9_.]{0,79}$/;
const ENTITY_TYPE = /^[a-z][a-z0-9_]{0,59}$/;
export const AUDIT_PAGE = 50;
// Owner decision taken as the recommended default: exporting needs audit.view AND one of these roles, because the
// file holds every entry's ip address and browser. Each export is audited.
export const AUDIT_EXPORT_ROLES = ["zella_owner", "super_admin"];
export const AUDIT_EXPORT_MAX_ROWS = 10_000;
export const AUDIT_COLUMNS = "id, action, business_id, user_id, entity_type, entity_id, old_data, new_data, ip_address, user_agent, created_at";

export type AuditFilters = {
  businessId?: string; auditAction?: string; search?: string; actorId?: string; from?: string; to?: string;
  entityType?: string; entityId?: string; timeZone?: string;
};

const day = (v: unknown) => {
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return null;
  const d = new Date(`${v}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== v ? null : d;
};

// The filters from a request, checked; anything malformed is refused, never silently widened.
export function auditFilters(fields: Json, InputError: new (m: string, s?: number) => Error): AuditFilters {
  const f: AuditFilters = {};
  // left out (undefined or null) means no filter; anything else that isn't text is refused, never read as "no filter"
  const str = (k: string) => {
    const v = fields[k];
    if (v === undefined || v === null) return "";
    if (typeof v !== "string") throw new InputError("A filter is not valid");
    return v.trim();
  };
  const id = (k: string, label: string) => { const v = str(k); if (!v) return undefined; if (!UUID.test(v)) throw new InputError(`${label} is not valid`); return v; };
  f.businessId = id("businessId", "The business");
  f.actorId = id("actorId", "The person");
  // "auditAction", because "action" is the function's own action (audit_logs, audit_export)
  const auditAction = str("auditAction");
  if (auditAction) { if (!ACTION_NAME.test(auditAction)) throw new InputError("The action is not valid"); f.auditAction = auditAction; }
  const search = str("search").toLowerCase().replace(/[^a-z0-9_.]/g, "").slice(0, 60);
  if (search) f.search = search;
  const entityType = str("entityType");
  if (entityType) { if (!ENTITY_TYPE.test(entityType)) throw new InputError("The record type is not valid"); f.entityType = entityType; }
  f.entityId = id("entityId", "The record id");
  // The dates are days in the admin's own time zone (the page shows times in it), so a day covers the same hours on
  // the page, in the filter and in the export. Without a valid zone, UTC.
  const tzIn = str("timeZone");
  let tz = "UTC";
  if (tzIn) {
    try { new Intl.DateTimeFormat("en-US", { timeZone: tzIn }); tz = tzIn; } catch { throw new InputError("The time zone is not valid"); }
  }
  for (const k of ["from", "to"] as const) {
    const v = str(k);
    if (!v) continue;
    const d = day(v);
    if (!d) throw new InputError(`The ${k === "from" ? "start" : "end"} date is not valid`);
    // the start of that day in the zone; "to" is the whole of that day (up to the start of the next one)
    const y = d.getUTCFullYear(), m = d.getUTCMonth() + 1, dd = d.getUTCDate();
    const next = new Date(Date.UTC(y, m - 1, dd + 1));
    f[k] = new Date(k === "from" ? instant(y, m, dd, "00:00", tz) : instant(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), "00:00", tz)).toISOString();
  }
  if (tzIn && (f.from || f.to)) f.timeZone = tz;
  if (f.from && f.to && f.from >= f.to) throw new InputError("The start date is after the end date");
  for (const k of Object.keys(f) as (keyof AuditFilters)[]) if (f[k] === undefined) delete f[k];
  return f;
}

// "created_at|id" of the last row shown; rows with the same time are told apart by id, so none is skipped. The time
// is kept exactly as the database wrote it (microseconds), never rounded through a JavaScript Date.
const STAMP = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}(:?\d{2})?)$/;
export function auditCursor(v: unknown): { at: string; id: string } | null {
  if (typeof v !== "string" || !v || v.length > 80) return null;
  const [at, id, extra] = v.split("|");
  if (extra !== undefined || !STAMP.test(at ?? "") || Number.isNaN(Date.parse(at)) || !UUID.test(id ?? "")) return null;
  return { at, id };
}
export const nextAuditCursor = (row: { created_at: string; id: string }) => `${row.created_at}|${row.id}`;

// deno-lint-ignore no-explicit-any
export function applyAuditFilters(query: any, f: AuditFilters, cursor: { at: string; id: string } | null) {
  let q = query.order("created_at", { ascending: false }).order("id", { ascending: false });
  if (f.businessId) q = q.eq("business_id", f.businessId);
  if (f.actorId) q = q.eq("user_id", f.actorId);
  if (f.auditAction) q = q.eq("action", f.auditAction);
  else if (f.search) q = q.ilike("action", `%${f.search}%`);
  if (f.entityType) q = q.eq("entity_type", f.entityType);
  if (f.entityId) q = q.eq("entity_id", f.entityId);
  if (f.from) q = q.gte("created_at", f.from);
  if (f.to) q = q.lt("created_at", f.to);
  if (cursor) q = q.or(`created_at.lt."${cursor.at}",and(created_at.eq."${cursor.at}",id.lt.${cursor.id})`);
  return q;
}

// One CSV cell. Text a spreadsheet would run as a formula (starting with = + - @, their full width forms, a tab or a
// return) gets a leading apostrophe, so an export opened in a spreadsheet never runs anything.
export function csvCell(v: unknown): string {
  if (v === null || v === undefined) return "";
  let t = typeof v === "object" ? JSON.stringify(v) : String(v);
  if (/^[=+\-@\t\r\uFF1D\uFF0B\uFF0D\uFF20]/.test(t)) t = `'${t}`;
  return /[",\r\n]/.test(t) || t !== t.trim() ? `"${t.replace(/"/g, '""')}"` : t;
}
export const csvRow = (cells: unknown[]) => cells.map(csvCell).join(",");

const LABELS = (catalog as { audit_actions: Record<string, string> }).audit_actions;
export const actionText = (a: string) => LABELS[a] ?? a.replace(/[._]/g, " ");

type Kit = { InputError: new (message: string, status?: number) => Error; requireId: (v: unknown, label?: string) => string };
type Factor = { id: string; status?: string; factor_type?: string; friendly_name?: string | null };

export function accessHandlers(admin: SupabaseClient, fields: Json, userId: string, kit: Kit, role: string | null = null) {
  const { InputError, requireId } = kit;

  const verifiedFactors = async (): Promise<Factor[]> => {
    const { data, error } = await admin.auth.admin.mfa.listFactors({ userId });
    if (error) throw error;
    return ((data?.factors ?? []) as Factor[]).filter((f) => f.status === "verified");
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    // ACC-15: refused admin calls in the last 24 hours, newest first, with who, what and from where.
    security_refusals: async () => {
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const { data, error, count } = await admin.from("audit_logs")
        .select("user_id, new_data, ip_address, user_agent, created_at", { count: "exact" })
        .eq("action", "security.admin_refused").gte("created_at", since)
        .order("created_at", { ascending: false }).limit(20);
      if (error) throw error;
      const rows = (data ?? []) as { user_id: string | null; new_data: Json | null; ip_address: string | null; user_agent: string | null; created_at: string }[];
      const ids = [...new Set(rows.map((r) => r.user_id).filter(Boolean))] as string[];
      const emails: Record<string, string | null> = {};
      await Promise.all(ids.map(async (id) => { const { data: u } = await admin.auth.admin.getUserById(id); emails[id] = u?.user?.email ?? null; }));
      return {
        count24h: count ?? rows.length,
        recent: rows.map((r) => ({
          email: r.user_id ? emails[r.user_id] ?? null : null, code: r.new_data?.code ?? null, request: r.new_data?.action ?? null,
          permission: r.new_data?.permission ?? null, ip: r.ip_address, userAgent: r.user_agent, at: r.created_at,
        })),
      };
    },
    // ACC-12: the filtered audit log as CSV, newest first, at most AUDIT_EXPORT_MAX_ROWS rows.
    audit_export: async () => {
      if (!role || !AUDIT_EXPORT_ROLES.includes(role)) throw new InputError("Only a Zella Voice owner or a super admin can export the audit log.", 403);
      const filters = auditFilters(fields, InputError);
      // deno-lint-ignore no-explicit-any
      const rows: any[] = [];
      let cursor: { at: string; id: string } | null = null;
      while (rows.length < AUDIT_EXPORT_MAX_ROWS) {
        const size = Math.min(1000, AUDIT_EXPORT_MAX_ROWS - rows.length);
        const { data, error } = await applyAuditFilters(admin.from("audit_logs").select(AUDIT_COLUMNS), filters, cursor).limit(size);
        if (error) throw error;
        rows.push(...(data ?? []));
        if ((data ?? []).length < size) break;
        cursor = { at: rows[rows.length - 1].created_at, id: rows[rows.length - 1].id };
      }
      // one more row tells whether the file was cut at the limit
      let truncated = false;
      if (rows.length >= AUDIT_EXPORT_MAX_ROWS) {
        const last = rows[rows.length - 1];
        const { data, error } = await applyAuditFilters(admin.from("audit_logs").select("id"), filters, { at: last.created_at, id: last.id }).limit(1);
        if (error) throw error;   // never call the file complete when the check didn't run
        truncated = (data ?? []).length > 0;
      }
      const actorIds = [...new Set(rows.map((r) => r.user_id).filter(Boolean))].slice(0, 500) as string[];
      const emails: Record<string, string | null> = {};
      await Promise.all(actorIds.map(async (id) => { const { data } = await admin.auth.admin.getUserById(id); emails[id] = data?.user?.email ?? null; }));
      const bizIds = [...new Set(rows.map((r) => r.business_id).filter(Boolean))] as string[];
      const names: Record<string, string> = {};
      for (let i = 0; i < bizIds.length; i += 200) {
        const { data, error } = await admin.from("businesses").select("id, name").in("id", bizIds.slice(i, i + 200));
        if (error) throw error;
        for (const b of data ?? []) names[b.id] = b.name;
      }
      const lines = [csvRow(["When (UTC)", "Action", "Action name", "Business", "Business id", "By", "By id", "Record type", "Record id", "IP address", "Browser", "Before", "After"])];
      for (const r of rows) {
        lines.push(csvRow([r.created_at, actionText(r.action), r.action, r.business_id ? names[r.business_id] ?? "" : "", r.business_id, r.user_id ? emails[r.user_id] ?? "" : "",
          r.user_id, r.entity_type, r.entity_id, r.ip_address, r.user_agent, r.old_data, r.new_data]));
      }
      const stamp = new Date().toISOString().slice(0, 10);
      return { csv: lines.join("\r\n") + "\r\n", rows: rows.length, truncated, filename: `zella-voice-audit-log-${stamp}.csv`, filters };
    },
    // The browser has just verified a new authenticator (Supabase Auth); record it once it is really in the list.
    me_mfa_added: async () => {
      const factorId = requireId(fields.factorId, "authenticator");
      const factor = (await verifiedFactors()).find((f) => f.id === factorId);
      if (!factor) throw new InputError("That authenticator isn't set up on your account", 404);
      return { factorId, friendlyName: factor.friendly_name ?? null };
    },
    // Removing one needs another left: every admin keeps two step sign in (ACC-01).
    me_mfa_remove: async () => {
      const factorId = requireId(fields.factorId, "authenticator");
      const factor = (await verifiedFactors()).find((f) => f.id === factorId);
      if (!factor) throw new InputError("That authenticator isn't set up on your account", 404);
      // Supabase Auth's own delete doesn't keep the last factor, so the removal runs in the database while holding a
      // lock on the person (zella_remove_mfa_factor): the "another verified one is left" check and the delete can't
      // interleave with a second removal (sql/zella_admin_sessions.sql).
      const { data: left, error } = await admin.rpc("zella_remove_mfa_factor", { p_user_id: userId, p_factor_id: factorId });
      if (error) {
        const m = error.message ?? "";
        if (/LAST_FACTOR/.test(m)) throw new InputError("Every Zella Voice admin needs two step sign in. Add another authenticator first, then remove this one.", 409);
        if (/NOT_FOUND/.test(m)) throw new InputError("That authenticator isn't set up on your account", 404);
        if (/zella_remove_mfa_factor|PGRST202|does not exist/i.test(m)) throw new InputError("Removing an authenticator needs the latest database update (sql/zella_admin_sessions.sql).", 503);
        throw error;
      }
      return { factorId, friendlyName: factor.friendly_name ?? null, left: typeof left === "number" ? left : null };
    },
    // Through the server key, which skips Supabase's own reauthentication: the fresh code (entered within 5 minutes)
    // is the reauthentication instead.
    me_password_change: async () => {
      const problem = passwordProblem(fields.password);
      if (problem) throw new InputError(problem);
      const { error } = await admin.auth.admin.updateUserById(userId, { password: fields.password as string });
      if (error) throw new InputError(/weak|pwned|leaked|known/i.test(error.message) ? "That password is too easy to guess or has appeared in a data breach. Choose another." : "The password could not be changed. Try again.", 422);
      return { changed: true };
    },
  };

  // Never the password itself, nor anything about it.
  const audited: Record<string, (r: Json) => Json | null> = {
    me_mfa_added: (r) => ({ action: "admin.mfa_added", entity_type: "mfa_factor", entity_id: r.factorId, new_data: { friendly_name: r.friendlyName } }),
    me_mfa_remove: (r) => ({ action: "admin.mfa_removed", entity_type: "mfa_factor", entity_id: r.factorId, old_data: { friendly_name: r.friendlyName }, new_data: { left: r.left } }),
    me_password_change: () => ({ action: "admin.password_changed", entity_type: "user", entity_id: userId }),
    // what was exported and how much, never the file itself
    audit_export: (r) => ({ action: "audit.exported", entity_type: "audit_logs", new_data: { filters: r.filters, rows: r.rows, truncated: r.truncated } }),
  };
  return { handlers, audited };
}

// OPS-25: support age in business hours (REQ-BIL-47: first response within 4 business hours). The hours are the
// platform setting support_business_hours (sql/zella_support_replies.sql); this default is used until it is set.
export type SupportHours = { days: number[]; start: string; end: string; timezone: string; first_response_hours: number };
export const SUPPORT_HOURS_DEFAULT: SupportHours = { days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00", timezone: "America/New_York", first_response_hours: 4 };

export function supportHours(v: unknown): SupportHours {
  const o = (v && typeof v === "object" ? v : {}) as Record<string, unknown>;
  const hm = (x: unknown, d: string) => (typeof x === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(x) ? x : d);
  let timezone = SUPPORT_HOURS_DEFAULT.timezone;
  try { if (typeof o.timezone === "string") { new Intl.DateTimeFormat("en-US", { timeZone: o.timezone }); timezone = o.timezone; } } catch { /* keep the default */ }
  const days = Array.isArray(o.days) ? [...new Set(o.days.filter((d) => Number.isInteger(d) && (d as number) >= 1 && (d as number) <= 7))] as number[] : [];
  const start = hm(o.start, SUPPORT_HOURS_DEFAULT.start), end = hm(o.end, SUPPORT_HOURS_DEFAULT.end);
  const n = Number(o.first_response_hours);
  return {
    days: days.length ? days.sort() : SUPPORT_HOURS_DEFAULT.days,
    start: start < end ? start : SUPPORT_HOURS_DEFAULT.start, end: start < end ? end : SUPPORT_HOURS_DEFAULT.end,
    timezone, first_response_hours: Number.isFinite(n) && n > 0 && n <= 168 ? n : SUPPORT_HOURS_DEFAULT.first_response_hours,
  };
}

// The local date, weekday (1 Monday to 7 Sunday) and offset from UTC of an instant in a time zone.
function zoned(ms: number, tz: string) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", weekday: "short" }).formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  const local = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  return { y: +p.year, m: +p.month, d: +p.day, weekday: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(p.weekday) + 1, offset: local - Math.floor(ms / 1000) * 1000 };
}
// The instant of a local wall time in a time zone (the offset is found twice, for the days the clocks change).
function instant(y: number, m: number, d: number, hhmm: string, tz: string) {
  const [h, min] = hhmm.split(":").map(Number);
  const guess = Date.UTC(y, m - 1, d, h, min);
  const first = guess - zoned(guess, tz).offset;
  return guess - zoned(first, tz).offset;
}

// Business hours between two instants, in hours (0 when the end is not after the start). The first and last weeks are
// read day by day; whole weeks in between add one week's business hours each (the hours are wall clock times, so a
// week holds the same business hours whatever the clocks do overnight). Exact for any length, in bounded work.
export function businessHoursBetween(fromIso: string, toIso: string, hours: SupportHours): number {
  const from = Date.parse(fromIso), to = Date.parse(toIso);
  if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) return 0;
  const [sh, sm] = hours.start.split(":").map(Number), [eh, em] = hours.end.split(":").map(Number);
  const weekMs = hours.days.length * ((eh * 60 + em) - (sh * 60 + sm)) * 60_000;
  let total = 0;
  let { y, m, d } = zoned(from, hours.timezone);
  for (let i = 0; i < 40; i++) {
    let noon = Date.UTC(y, m - 1, d, 12);
    // after the first day, jump over whole weeks that end at least a week before the end
    const weeks = i > 0 ? Math.floor((to - noon) / (7 * 86_400_000)) - 1 : 0;
    if (weeks > 0) {
      total += weeks * weekMs;
      noon += weeks * 7 * 86_400_000;
      const at = new Date(noon); y = at.getUTCFullYear(); m = at.getUTCMonth() + 1; d = at.getUTCDate();
    }
    const wd = ((new Date(noon).getUTCDay() + 6) % 7) + 1;
    const open = instant(y, m, d, hours.start, hours.timezone), close = instant(y, m, d, hours.end, hours.timezone);
    if (open >= to) break;
    if (hours.days.includes(wd)) total += Math.max(0, Math.min(close, to) - Math.max(open, from));
    const next = new Date(noon + 86_400_000);
    y = next.getUTCFullYear(); m = next.getUTCMonth() + 1; d = next.getUTCDate();
  }
  return Math.round((total / 3_600_000) * 100) / 100;
}

// A ticket's age, its first response time and whether the first response is overdue, all in business hours.
export function ticketTiming(t: { created_at: string; first_response_at?: string | null; status?: string }, hours: SupportHours, nowIso = new Date().toISOString()) {
  const waiting = !t.first_response_at && !["resolved", "closed"].includes(t.status ?? "");
  const firstResponseHours = t.first_response_at ? businessHoursBetween(t.created_at, t.first_response_at, hours) : null;
  const ageHours = businessHoursBetween(t.created_at, nowIso, hours);
  return { ageHours, firstResponseHours, overdue: waiting && ageHours > hours.first_response_hours };
}
