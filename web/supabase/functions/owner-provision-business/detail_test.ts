import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { adminPermissions, businessDetail, type DetailDeps } from "./detail.ts";
import { PERMISSIONS, PERMISSION_CATALOG, RESTRICTED_ROLES, settingsHandlers } from "./settings.ts";

// A stand in for the server's database client: each table answers with its fixture rows, and every query is recorded.
type Rows = Record<string, unknown[]>;
function fakeAdmin(rows: Rows, failing: string[] = [], rpcs: Record<string, unknown> = {}) {
  const queries: { table: string; select?: string; filters: unknown[][] }[] = [];
  const looked: string[] = [];
  const called: string[] = [];
  const inserts: { table: string; row: unknown }[] = [];
  const client = {
    auth: { admin: { getUserById: (id: string) => {
      looked.push(id);
      return Promise.resolve({ data: { user: { id, email: `${id}@people.test`, last_sign_in_at: "2026-11-15T10:00:00Z", factors: id === "u1" ? [{ status: "verified" }] : [] } } });
    } } },
    rpc: (name: string) => {
      called.push(name);
      if (failing.includes(name)) return Promise.resolve({ data: null, error: { code: "PGRST202", message: "missing" } });
      return Promise.resolve({ data: rpcs[name] ?? { from: name }, error: null });
    },
    from(table: string) {
      const q = { table, select: undefined as string | undefined, filters: [] as unknown[][] };
      queries.push(q);
      const result = failing.includes(table)
        ? { data: null, error: { message: "unavailable" }, count: null }
        : { data: rows[table] ?? [], error: null, count: (rows[table] ?? []).length };
      const chain: Record<string, unknown> = {
        select: (cols: string) => ((q.select = cols), chain),
        maybeSingle: () => Promise.resolve({ ...result, data: (result.data ?? [])[0] ?? null }),
        then: (resolve: (v: unknown) => unknown) => resolve(result),
      };
      for (const f of ["eq", "in", "order", "limit", "is", "neq", "gte", "not"]) chain[f] = (...args: unknown[]) => (q.filters.push([f, ...args]), chain);
      chain.insert = (row: unknown) => { inserts.push({ table, row }); return Promise.resolve({ error: failing.includes(`insert:${table}`) ? { message: "insert failed" } : null }); };
      return chain;
    },
  };
  return { client: client as unknown as SupabaseClient, queries, looked, called, inserts };
}

const BIZ = "3e000000-0000-0000-0000-00000000b000";
const deps: DetailDeps = {
  loadSetup: () => Promise.resolve({ business: { id: BIZ, industry_id: "ind", timezone: "America/New_York" }, modules: [], automations: [],
    receptionist: { agentId: "ag1", escalationRules: { transfer_to: { phone: "+15550100101" }, fallback_number: "+15550100102" } } }),
};
const ROWS: Rows = {
  industries: [{ id: "ind", name: "Dental" }],
  business_invitations: [
    { id: "i2", role: "staff", email: "s@people.test", created_at: "2026-11-15" },
    { id: "i1", role: "owner", email: "o@people.test", created_at: "2026-11-01" },
  ],
  business_members: [{ user_id: "u1", role: "owner", status: "active" }],
  integrations: [{ id: "g1", provider: "telnyx", account_email: "ada@example.com", error_message: "Number +15550100123 refused for ada@example.com" }],
  calls: [{ id: "c1", from_number: "+15550100123", to_number: "+15550100100" }, { id: "c2", from_number: null, to_number: "" }],
  audit_logs: [{ id: "a1", action: "business.suspended", user_id: "u9" }],
  support_tickets: [],
  profiles: [{ id: "u1", first_name: "Ola", last_name: "Test" }],
};

Deno.test("business_detail: without audit.view, no activity is read and no actor is looked up", async () => {
  const { client, queries, looked } = fakeAdmin(ROWS);
  const out = await businessDetail(client, BIZ, new Set(["businesses.view"]), deps);
  assertEquals(out.activity, []);
  assertFalse(out.activityAllowed);
  assertFalse(queries.some((q) => q.table === "audit_logs"), "audit_logs must not be read");
  assertFalse(looked.includes("u9"), "the actor of a log row must not be resolved");
  assertEquals(out.permissions, ["businesses.view"]);
});

Deno.test("business_detail: with audit.view, activity and actors are returned", async () => {
  const { client } = fakeAdmin(ROWS);
  const out = await businessDetail(client, BIZ, new Set(["businesses.view", "audit.view"]), deps);
  assert(out.activityAllowed);
  assertEquals(out.activity.map((a: { actor: string }) => a.actor), ["u9@people.test"]);
});

Deno.test("business_detail: no full phone number or connection email anywhere in the response", async () => {
  const { client, queries } = fakeAdmin(ROWS);
  const out = await businessDetail(client, BIZ, new Set(["businesses.view", "audit.view"]), deps);
  const text = JSON.stringify({ calls: out.calls, integrations: out.integrations });
  assertFalse(/\+?\d{7,}/.test(text), text);
  assertFalse(text.includes("ada@example.com"), text);
  assertEquals(out.calls[0].from_number, "…0123");
  assertEquals(out.calls[1].from_number, null);
  assertEquals(out.integrations[0].account_email, "a…@example.com");
  assertEquals(out.integrations[0].error_message, "Number …0123 refused for a…@example.com");
  // The member's own phone is no longer read at all.
  assertFalse(queries.find((q) => q.table === "profiles")?.select?.includes("phone"));
});

Deno.test("business_detail: invitations carry their role, the owner's first", async () => {
  const { client, queries } = fakeAdmin(ROWS);
  const out = await businessDetail(client, BIZ, new Set(["businesses.view"]), deps);
  assert(queries.find((q) => q.table === "business_invitations")?.select?.includes("role"));
  assertEquals(out.invitations.map((i: { id: string }) => i.id), ["i1", "i2"]);
});

Deno.test("business_detail: a failed read refuses instead of returning part of the page", async () => {
  const { client } = fakeAdmin(ROWS, ["calls"]);
  let threw = false;
  try { await businessDetail(client, BIZ, new Set(["businesses.view"]), deps); } catch { threw = true; }
  assert(threw);
});

// The permission set must be the one the web app is told (me_admin) and the one index.ts applies to each action.
const ROLES = ["zella_owner", "super_admin", ...RESTRICTED_ROLES, "not_a_role"];
const GRANTS: Record<string, string[]> = {
  platform_operations: ["businesses.view", "businesses.manage", "audit.view"],
  read_only_admin: ["businesses.view"],
  billing_admin: ["billing.view", "billing.manage"],
  support_admin: [],
  security_admin: ["security.view"],
};
const grantRows = (role: string) => (GRANTS[role] ?? []).map((permission) => ({ role, permission }));

// index.ts's rule for one action, restated: owner everything, super admin all but admins and roles, restricted roles
// their grants, anyone else nothing.
const dispatcherAllows = (role: string, permission: string) =>
  role === "zella_owner" || (role === "super_admin" && !["admins.manage", "roles.manage"].includes(permission)) ||
  (RESTRICTED_ROLES.includes(role) && (GRANTS[role] ?? []).includes(permission));

Deno.test("adminPermissions: same answer as the dispatcher for every action and role", async () => {
  for (const role of ROLES) {
    const can = await adminPermissions(fakeAdmin({ platform_role_permissions: grantRows(role) }).client, role);
    for (const [action, permission] of Object.entries(PERMISSIONS)) {
      if (action === "me_admin") continue;   // every admin may read their own role
      assertEquals(can.has(permission), dispatcherAllows(role, permission), `${role} ${action} (${permission})`);
    }
  }
});

Deno.test("adminPermissions: same list as me_admin gives the web app", async () => {
  const kit = { text: String, bool: Boolean, obj: (v: unknown) => (v ?? {}) as Record<string, unknown>, requireId: String, validTimezone: () => true, InputError: Error, EMAIL_RE: /@/, UUID_RE: /./ };
  for (const role of ROLES.filter((r) => r !== "not_a_role")) {
    const { client } = fakeAdmin({ platform_role_permissions: grantRows(role) });
    const me = await settingsHandlers(client, {}, { userId: "u", role, aal: "aal2", mfa: true }, kit as never).handlers.me_admin() as { permissions: string[] };
    const can = await adminPermissions(client, role);
    assertEquals([...can].sort(), [...me.permissions].sort(), role);
  }
});

Deno.test("adminPermissions: a failed lookup grants nothing", async () => {
  const can = await adminPermissions(fakeAdmin({}, ["platform_role_permissions"]).client, "platform_operations");
  assertEquals(can.size, 0);
  assertEquals((await adminPermissions(fakeAdmin({}).client, "anon")).size, 0);
  assert(PERMISSION_CATALOG.length > 10);
});

// ---- payload v2 (BIZ-11, BIZ-12 phase 1, UI-06, UI-07, UI-08, COM-03, BIZ-30) ----
import { currentPeriod, planView, routingFrom, usageSummary } from "./detail.ts";

const V2_ROWS: Rows = {
  ...ROWS,
  business_plans: [{ id: "p2", version: 2, tier: "base", price_cents: 9900, setup_fee_cents: 500, overage_cents_per_minute: 20, estimate: { cost: 1 }, minutes: 300 }],
  billing_periods: [{ id: "per1", period_start: "2026-11-01T00:00:00Z", period_end: "2099-12-01T00:00:00Z", is_trial: false }],
  allowance_buckets: [
    { resource: "minutes", kind: "plan", granted: 300, used: 120 },
    { resource: "minutes", kind: "pack", granted: 100, used: 0, expires_at: "2026-12-01" },
    { resource: "minutes", kind: "rollover", granted: 20, used: 20 },
    { resource: "texts", kind: "plan", granted: 500, used: 10 },
    { resource: "texts", kind: "buffer", granted: 25, used: 5 },
  ],
  business_phone_numbers: [{ id: "n1", e164: "+15550100100", status: "active" }],
  platform_alerts: [{ id: "al1", status: "open" }],
  assistant_deliveries: [{ id: 1, outcome: "not_ready", problems: ["no hours"] }, { id: 2, outcome: "served" }],
  activation_tests: [{ ok: false, detail: {}, created_at: "2026-11-10" }],
};

Deno.test("payload v2: prices only with billing.view; activation and sign in facts only with businesses.manage", async () => {
  const view = await businessDetail(fakeAdmin(V2_ROWS).client, BIZ, new Set(["businesses.view"]), deps);
  assertEquals(Object.keys(view.plan.plan).some((k) => /price|fee|overage|estimate/.test(k)), false);
  assertEquals(view.plan.plan.minutes, 300);
  assertEquals(view.activation.available, false);
  assertEquals("last_sign_in_at" in view.members[0], false);
  assertEquals("two_step" in view.members[0], false);
  assertFalse(view.signInFactsAllowed);

  const full = await businessDetail(fakeAdmin(V2_ROWS).client, BIZ, new Set(["businesses.view", "businesses.manage", "billing.view", "audit.view"]), deps);
  assertEquals(full.plan.plan.price_cents, 9900);
  assert(full.activation.available);
  assertEquals(full.activation.lastTest?.ok, false);
  assertEquals(full.members[0].two_step, true);
  assertEquals(full.members[0].last_sign_in_at, "2026-11-15T10:00:00Z");
  assertEquals(full.activityCount, 1);
});

Deno.test("payload v2: usage from the current period's balances, nothing written, no billing overview", async () => {
  const { client, called, queries } = fakeAdmin(V2_ROWS);
  const out = await businessDetail(client, BIZ, new Set(["businesses.view"]), deps);
  assertEquals(out.usage.totals.minutes, { granted: 420, used: 140, remaining: 280, reserve: 0, reserveRemaining: 0 });
  assertEquals([out.usage.totals.texts.remaining, out.usage.totals.texts.reserveRemaining], [490, 20]);
  assertFalse(called.some((n) => /billing_overview|open_period/.test(n)), called.join());
  assert(queries.find((q) => q.table === "allowance_buckets")?.filters.some((f) => f[0] === "eq" && f[1] === "period_id" && f[2] === "per1"));
});

Deno.test("payload v2: numbers, open alerts, routing and deliveries without caller data", async () => {
  const out = await businessDetail(fakeAdmin(V2_ROWS).client, BIZ, new Set(["businesses.view"]), deps);
  assertEquals(out.numbers.rows.length, 1);
  assert(out.connections.available);
  assertEquals(out.alerts.count, 1);
  assertEquals(out.routing.transfer_number, "+15550100101");
  assertEquals(out.routing.fallback_number, "+15550100102");
  assertEquals(out.deliveries.counts, { not_ready: 1, unknown_number: 0 });
  assertFalse(JSON.stringify(out.deliveries).includes("provider_call_id"));
});

Deno.test("payload v2: a missing table or function marks only its card unavailable", async () => {
  const out = await businessDetail(fakeAdmin(V2_ROWS, ["business_plans", "zella_business_readiness", "billing_periods", "zella_business_connections"]).client, BIZ, new Set(["businesses.view"]), deps);
  assertEquals(out.connections.available, false);
  assertEquals(out.plan.available, false);
  assertEquals(out.readiness.available, false);
  assertEquals(out.usage.available, false);
  assert(out.numbers.available);
});

Deno.test("pure parts: plan prices, current period, usage totals", () => {
  assertEquals(planView({ tier: "pro", price_cents: 1, setup_fee_cents: 2 }, false), { tier: "pro" });
  assertEquals(planView(null, true), null);
  const now = new Date("2026-11-16T00:00:00Z");
  assertEquals(currentPeriod([{ id: "old", period_start: "2026-10-01", period_end: "2026-11-01" }], now), null);
  assertEquals(currentPeriod([{ id: "a", period_start: "2026-11-01", period_end: "2026-12-01" }], now)?.id, "a");
  assertEquals(usageSummary([]), {});
});

// The same output as zella_admin_routing_get on the same rules (fixtures checked against the function on the
// isolated database, as an admin with businesses.view): see tests/admin_detail/run.sh.
Deno.test("routingFrom: defaults and fallbacks as zella_admin_routing_get", () => {
  const base = { timezone: "America/New_York", hasAgent: true, hasHours: false, onCall: null };
  assertEquals(routingFrom({}, base), {
    has_agent: true, timezone: "America/New_York", transfer_enabled: true, transfer_number: null, fallback_number: null,
    transfer_route: "primary", transfer_open_hours_only: true, on_call: null, has_hours: false,
  });
  const r = routingFrom({ transfer_enabled: false, transfer_number: "", transfer_to: { phone: "+1555" }, transfer_route: "on_call", transfer_open_hours_only: "false" }, base);
  assertEquals([r.transfer_enabled, r.transfer_number, r.transfer_route, r.transfer_open_hours_only], [false, "+1555", "on_call", false]);
});
