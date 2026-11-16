import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { endSessionsAfterChange, endsSessions, SESSIONS_NOT_ENDED } from "./access.ts";

const owner = { role: "zella_owner", is_active: true };
const support = { role: "support_admin", is_active: true };
const fake = (reply: { data: unknown; error: unknown }) => {
  const calls: unknown[] = [];
  const admin = { rpc: async (name: string, args: unknown) => { calls.push([name, args]); return reply; } } as unknown as SupabaseClient;
  return { admin, calls };
};

Deno.test("sessions end on removal and on a role change, never otherwise", () => {
  assertEquals(endsSessions(support, { ...support, is_active: false }), true);    // removed
  assertEquals(endsSessions(owner, support), true);                                // role changed
  assertEquals(endsSessions(support, support), false);                             // nothing changed
  assertEquals(endsSessions({ ...support, is_active: false }, support), false);    // reactivated: nothing to end
  assertEquals(endsSessions({ ...support, is_active: false }, { ...owner, is_active: false }), false); // inactive stays inactive
});

Deno.test("a removal or role change ends the target's sessions through the server only function", async () => {
  const { admin, calls } = fake({ data: 2, error: null });
  assertEquals(await endSessionsAfterChange(admin, "target", owner, support), { sessionsEnded: 2 });
  assertEquals(calls, [["zella_end_user_sessions", { p_user_id: "target" }]]);
});

Deno.test("no change, no call", async () => {
  const { admin, calls } = fake({ data: 2, error: null });
  assertEquals(await endSessionsAfterChange(admin, "target", support, support), { sessionsEnded: 0 });
  assertEquals(calls, []);
});

Deno.test("a database failure keeps the change and says the devices weren't signed out", async () => {
  for (const reply of [{ data: null, error: { message: "function does not exist" } }, { data: "x", error: null }]) {
    const { admin } = fake(reply);
    assertEquals(await endSessionsAfterChange(admin, "target", support, { ...support, is_active: false }), { sessionsEnded: null, sessionsWarning: SESSIONS_NOT_ENDED });
  }
});

import { accessHandlers, ACCESS_PERMISSIONS, passwordProblem, SELF_ACTIONS } from "./access.ts";
class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { InputError, requireId: (v: unknown) => { if (typeof v !== "string" || !/^[0-9a-f-]{36}$/.test(v)) throw new InputError("bad id"); return v; } };
const F1 = "11111111-1111-1111-1111-111111111111", F2 = "22222222-2222-2222-2222-222222222222", F3 = "33333333-3333-3333-3333-333333333333";
// a fake server client: the factors of each user, and every admin call made
function authFake(factors: Record<string, { id: string; status: string; friendly_name?: string }[]>, opts: { updateError?: string } = {}) {
  const calls: unknown[] = [];
  const admin = { auth: { admin: {
    mfa: {
      listFactors: async ({ userId }: { userId: string }) => { calls.push(["list", userId]); return { data: { factors: factors[userId] ?? [] }, error: null }; },
      deleteFactor: async (a: { userId: string; id: string }) => { calls.push(["delete", a.userId, a.id]); return { data: { id: a.id }, error: null }; },
    },
    updateUserById: async (id: string, attrs: unknown) => { calls.push(["update", id, attrs]); return { data: {}, error: opts.updateError ? { message: opts.updateError } : null }; },
  } } } as unknown as SupabaseClient;
  return { admin, calls };
}

Deno.test("the self service actions are for every active admin and only their own account", () => {
  assertEquals(SELF_ACTIONS, ["me_mfa_added", "me_mfa_remove", "me_password_change"]);
  for (const a of SELF_ACTIONS) assertEquals(ACCESS_PERMISSIONS[a], "self");
});

Deno.test("me_mfa_added records only a verified authenticator that is really the caller's", async () => {
  const { admin, calls } = authFake({ me: [{ id: F1, status: "verified", friendly_name: "Phone" }, { id: F2, status: "unverified" }], other: [{ id: F3, status: "verified" }] });
  const h = (fields: Record<string, unknown>) => accessHandlers(admin, fields, "me", kit);
  assertEquals(await h({ factorId: F1 }).handlers.me_mfa_added(), { factorId: F1, friendlyName: "Phone" });
  for (const id of [F2, F3]) {                                   // not verified yet; someone else's
    const e = await h({ factorId: id }).handlers.me_mfa_added().catch((x) => x);
    assertEquals([e instanceof InputError, (e as InputError).status], [true, 404]);
  }
  // the user is always the caller: a userId in the request is ignored
  await h({ factorId: F1, userId: "other" }).handlers.me_mfa_added();
  assertEquals(calls.every((c) => (c as unknown[])[1] === "me"), true);
  assertEquals(h({}).audited.me_mfa_added({ factorId: F1, friendlyName: "Phone" }), { action: "admin.mfa_added", entity_type: "mfa_factor", entity_id: F1, new_data: { friendly_name: "Phone" } });
});

Deno.test("me_mfa_remove refuses the last authenticator and someone else's, on the server", async () => {
  const one = authFake({ me: [{ id: F1, status: "verified" }, { id: F2, status: "unverified" }] });
  const e = await accessHandlers(one.admin, { factorId: F1 }, "me", kit).handlers.me_mfa_remove().catch((x) => x);
  assertEquals((e as InputError).status, 409);
  assertEquals(one.calls.some((c) => (c as unknown[])[0] === "delete"), false);
  const two = authFake({ me: [{ id: F1, status: "verified" }, { id: F2, status: "verified", friendly_name: "Old phone" }], other: [{ id: F3, status: "verified" }] });
  const other = await accessHandlers(two.admin, { factorId: F3 }, "me", kit).handlers.me_mfa_remove().catch((x) => x);
  assertEquals((other as InputError).status, 404);
  assertEquals(await accessHandlers(two.admin, { factorId: F2 }, "me", kit).handlers.me_mfa_remove(), { factorId: F2, friendlyName: "Old phone", left: 1 });
  assertEquals(two.calls.filter((c) => (c as unknown[])[0] === "delete"), [["delete", "me", F2]]);
  assertEquals(accessHandlers(two.admin, {}, "me", kit).audited.me_mfa_remove({ factorId: F2, friendlyName: "Old phone", left: 1 }),
    { action: "admin.mfa_removed", entity_type: "mfa_factor", entity_id: F2, old_data: { friendly_name: "Old phone" }, new_data: { left: 1 } });
});

Deno.test("me_password_change checks the rule, changes only the caller's password and never audits it", async () => {
  assertEquals(passwordProblem("Abcdefg1"), null);
  for (const bad of ["", "Abc1", "abcdefgh1", "ABCDEFGH1", "Abcdefghi", "A1" + "a".repeat(63), 12345678, null]) assertEquals(typeof passwordProblem(bad), "string", String(bad));
  const ok = authFake({});
  assertEquals(await accessHandlers(ok.admin, { password: "Newpass123", userId: "other" }, "me", kit).handlers.me_password_change(), { changed: true });
  assertEquals(ok.calls, [["update", "me", { password: "Newpass123" }]]);
  const entry = accessHandlers(ok.admin, {}, "me", kit).audited.me_password_change({ changed: true });
  assertEquals(entry, { action: "admin.password_changed", entity_type: "user", entity_id: "me" });
  assertEquals(JSON.stringify(entry).includes("Newpass123"), false);
  const weak = authFake({}, { updateError: "Password is known to be weak and easy to guess" });
  const e = await accessHandlers(weak.admin, { password: "Newpass123" }, "me", kit).handlers.me_password_change().catch((x) => x);
  assertEquals((e as InputError).status, 422);
  const none = authFake({});
  await accessHandlers(none.admin, { password: "short" }, "me", kit).handlers.me_password_change().catch(() => {});
  assertEquals(none.calls, []);
});

import { recordRefusal, REFUSAL_LIMIT } from "./access.ts";
function refusalFake(opts: { allowed?: unknown; rpcError?: boolean; insertError?: boolean; throws?: boolean } = {}) {
  const rpcs: unknown[] = [], inserts: unknown[] = [];
  const admin = {
    rpc: async (name: string, args: unknown) => { if (opts.throws) throw new Error("network down"); rpcs.push([name, args]); return { data: opts.allowed ?? true, error: opts.rpcError ? { message: "x" } : null }; },
    from: (table: string) => ({ insert: async (row: unknown) => { inserts.push([table, row]); return { error: opts.insertError ? { message: "x" } : null }; } }),
  } as unknown as SupabaseClient;
  return { admin, rpcs, inserts };
}
const ctx = { userId: "u1", ip: "203.0.113.9", userAgent: "Test browser" };

Deno.test("a refused admin call is recorded with ip and user agent, under the rate limit", async () => {
  const f = refusalFake();
  assertEquals(await recordRefusal(f.admin, ctx, { code: "NOT_PERMITTED", action: "admin_invite", permission: "admins.manage" }), true);
  assertEquals(f.rpcs, [["zella_rate_limit", { p_key: "refusal:u1:NOT_PERMITTED", p_max: 5, p_window_seconds: 600 }]]);
  assertEquals(REFUSAL_LIMIT, { max: 5, windowSeconds: 600 });
  assertEquals(f.inserts, [["audit_logs", { user_id: "u1", action: "security.admin_refused", entity_type: "admin_request", ip_address: "203.0.113.9", user_agent: "Test browser",
    new_data: { code: "NOT_PERMITTED", action: "admin_invite", permission: "admins.manage" } }]]);
});

Deno.test("over the limit nothing more is written", async () => {
  const f = refusalFake({ allowed: false });
  assertEquals(await recordRefusal(f.admin, ctx, { code: "MFA_REQUIRED", action: "dashboard_data" }), false);
  assertEquals(f.inserts, []);
});

Deno.test("an action name from the request is kept only when it looks like one", async () => {
  const f = refusalFake();
  await recordRefusal(f.admin, ctx, { code: "NOT_ADMIN", action: "<script>alert(1)</script>" });
  await recordRefusal(f.admin, ctx, { code: "NOT_ADMIN" });
  assertEquals(f.inserts.map((i) => ((i as [string, { new_data: { action: unknown } }])[1]).new_data.action), [null, null]);
});

Deno.test("recording never throws, whatever fails", async () => {
  for (const opts of [{ rpcError: true }, { insertError: true }, { throws: true }, { allowed: "yes" }]) {
    assertEquals(await recordRefusal(refusalFake(opts).admin, ctx, { code: "NOT_ADMIN" }), false, JSON.stringify(opts));
  }
});

import { actionText, applyAuditFilters, AUDIT_EXPORT_MAX_ROWS, auditCursor, auditFilters, csvCell, nextAuditCursor } from "./access.ts";
const B = "b3000000-0000-0000-0000-0000000000a1", U = "30000000-0000-0000-0000-0000000000a1";

Deno.test("audit filters: checked, a malformed one refused, the end date covers that whole day", () => {
  assertEquals(auditFilters({ businessId: B, actorId: U, auditAction: "admin.updated", action: "audit_logs", entityType: "platform_admin", entityId: U, from: "2026-11-01", to: "2026-11-16" }, InputError), {
    businessId: B, actorId: U, auditAction: "admin.updated", entityType: "platform_admin", entityId: U, from: "2026-11-01T00:00:00.000Z", to: "2026-11-17T00:00:00.000Z",
  });
  assertEquals(auditFilters({ action: "audit_export" }, InputError), {});   // the function's own action is never a filter
  assertEquals(auditFilters({}, InputError), {});
  assertEquals(auditFilters({ search: "Admin. Up-dated!" }, InputError), { search: "admin.updated" });
  for (const bad of [{ businessId: "x" }, { actorId: "1; drop" }, { auditAction: "a,b" }, { entityType: "x y" }, { entityId: "nope" }, { from: "2026-13-01" }, { to: "16/11/2026" },
    { from: "2026-11-10", to: "2026-11-01" }, { from: "2026-02-30" }]) {
    let threw = false;
    try { auditFilters(bad, InputError); } catch (e) { threw = e instanceof InputError; }
    assertEquals(threw, true, JSON.stringify(bad));
  }
});

Deno.test("the audit cursor keeps the exact time and id, and refuses anything else", () => {
  const row = { created_at: "2026-11-16T14:00:00.123456+00:00", id: U };
  assertEquals(auditCursor(nextAuditCursor(row)), { at: "2026-11-16T14:00:00.123456+00:00", id: U });
  for (const bad of ["", "2026-11-16T14:00:00Z", `x|${U}`, "2026-11-16T14:00:00Z|nope", `2026-11-16T14:00:00Z|${U}|x`, `2026-11-16T14:00:00Z),id.gt.(|${U}`, null, 5]) assertEquals(auditCursor(bad), null, String(bad));
});

Deno.test("filters and the cursor become the query: newest first, ties ordered by id", () => {
  const calls: unknown[] = [];
  const q: Record<string, (...a: unknown[]) => unknown> = {};
  for (const m of ["order", "eq", "ilike", "gte", "lt", "or"]) q[m] = (...a: unknown[]) => { calls.push([m, ...a]); return q; };
  applyAuditFilters(q, { businessId: B, actorId: U, auditAction: "admin.updated", search: "ignored", from: "2026-11-01T00:00:00.000Z", to: "2026-11-17T00:00:00.000Z", entityType: "platform_admin", entityId: U },
    { at: "2026-11-16T14:00:00.123456+00:00", id: U });
  assertEquals(calls, [
    ["order", "created_at", { ascending: false }], ["order", "id", { ascending: false }],
    ["eq", "business_id", B], ["eq", "user_id", U], ["eq", "action", "admin.updated"], ["eq", "entity_type", "platform_admin"], ["eq", "entity_id", U],
    ["gte", "created_at", "2026-11-01T00:00:00.000Z"], ["lt", "created_at", "2026-11-17T00:00:00.000Z"],
    ["or", `created_at.lt."2026-11-16T14:00:00.123456+00:00",and(created_at.eq."2026-11-16T14:00:00.123456+00:00",id.lt.${U})`],
  ]);
});

Deno.test("CSV cells: formulas are defused, quotes and line breaks are quoted, objects become JSON", () => {
  assertEquals(csvCell("plain"), "plain");
  for (const f of ["=SUM(A1)", "+1", "-2", "@cmd", "\tx", "\rx"]) assertEquals(csvCell(f).replace(/^"|"$/g, "").startsWith("'"), true, f);
  assertEquals(csvCell("=1+1"), "'=1+1");
  assertEquals(csvCell('say "hi", ok'), '"say ""hi"", ok"');
  assertEquals(csvCell("two\nlines"), '"two\nlines"');
  assertEquals(csvCell({ a: "=x" }), '"{""a"":""=x""}"');
  assertEquals(csvCell(null), "");
  assertEquals(csvCell(7), "7");
});

// a fake audit_logs of n rows, newest first, served through the query builder the export uses
function exportFake(n: number) {
  const all = Array.from({ length: n }, (_, i) => ({ id: `00000000-0000-0000-0000-${String(n - i).padStart(12, "0")}`, action: i % 2 ? "admin.updated" : "=evil()",
    business_id: null, user_id: null, entity_type: "x", entity_id: null, old_data: null, new_data: { n: i }, ip_address: "203.0.113.1", user_agent: "UA", created_at: "2026-11-16T10:00:00.000001+00:00" }));
  let reads = 0;
  const admin = {
    from: () => {
      let after: string | null = null, lim = 1000;
      const q: Record<string, unknown> = {};
      for (const m of ["select", "order", "eq", "ilike", "gte", "lt"]) q[m] = () => q;
      q.or = (s: string) => { after = /id\.lt\.([0-9a-f-]{36})/.exec(s)?.[1] ?? null; return q; };
      q.limit = (l: number) => { lim = l; return q; };
      q.then = (res: (v: unknown) => void) => { reads++; const start = after ? all.findIndex((r) => r.id === after) + 1 : 0; res({ data: all.slice(start, start + lim), error: null }); };
      return q;
    },
    auth: { admin: { getUserById: async () => ({ data: { user: null } }) } },
  } as unknown as SupabaseClient;
  return { admin, reads: () => reads };
}

Deno.test("audit export: owner and super admin only, by default", async () => {
  for (const role of ["support_admin", "read_only_admin", "security_admin", null]) {
    const e = await accessHandlers(exportFake(3).admin, {}, "me", kit, role).handlers.audit_export().catch((x) => x);
    assertEquals((e as InputError).status, 403, String(role));
  }
  for (const role of ["zella_owner", "super_admin"]) assertEquals(((await accessHandlers(exportFake(3).admin, {}, "me", kit, role).handlers.audit_export()) as { rows: number }).rows, 3);
});

Deno.test("audit export: every row once, defused, capped at 10,000 and said so, and audited without the file", async () => {
  const small = (await accessHandlers(exportFake(2500).admin, { auditAction: "admin.updated" }, "me", kit, "zella_owner").handlers.audit_export()) as { csv: string; rows: number; truncated: boolean; filters: unknown };
  assertEquals([small.rows, small.truncated], [2500, false]);
  const lines = small.csv.trimEnd().split("\r\n");
  assertEquals(lines.length, 2501);
  assertEquals(new Set(lines.slice(1).map((l) => l.split(",")[2])).size, 2);     // the action names column
  assertEquals(lines.some((l) => /,=evil/.test(l)), false);
  assertEquals(lines.some((l) => l.includes(",'=evil()")), true);
  assertEquals(AUDIT_EXPORT_MAX_ROWS, 10_000);
  const big = (await accessHandlers(exportFake(10_050).admin, {}, "me", kit, "super_admin").handlers.audit_export()) as { rows: number; truncated: boolean };
  assertEquals([big.rows, big.truncated], [10_000, true]);
  const entry = accessHandlers(exportFake(1).admin, {}, "me", kit, "zella_owner").audited.audit_export(small as unknown as Record<string, unknown>);
  assertEquals(entry, { action: "audit.exported", entity_type: "audit_logs", new_data: { filters: { auditAction: "admin.updated" }, rows: 2500, truncated: false } });
  assertEquals(actionText("admin.updated"), "Changed platform admin access");
});
