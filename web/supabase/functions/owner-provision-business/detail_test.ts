import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { adminPermissions, businessDetail, type DetailDeps } from "./detail.ts";
import { PERMISSIONS, PERMISSION_CATALOG, RESTRICTED_ROLES, settingsHandlers } from "./settings.ts";

// A stand in for the server's database client: each table answers with its fixture rows, and every query is recorded.
type Rows = Record<string, unknown[]>;
function fakeAdmin(rows: Rows, failing: string[] = []) {
  const queries: { table: string; select?: string; filters: unknown[][] }[] = [];
  const client = {
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
      for (const f of ["eq", "in", "order", "limit", "is", "neq", "gte"]) chain[f] = (...args: unknown[]) => (q.filters.push([f, ...args]), chain);
      return chain;
    },
  };
  return { client: client as unknown as SupabaseClient, queries };
}

const BIZ = "3e000000-0000-0000-0000-00000000b000";
const deps: DetailDeps = {
  loadSetup: () => Promise.resolve({ business: { id: BIZ, industry_id: "ind" }, modules: [], automations: [] }),
  resolveUsers: (_a, ids) => Promise.resolve(Object.fromEntries(ids.filter(Boolean).map((id) => [id as string, `${id}@people.test`]))),
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
  const { client, queries } = fakeAdmin(ROWS);
  let looked: (string | null)[] = [];
  const out = await businessDetail(client, BIZ, new Set(["businesses.view"]), { ...deps, resolveUsers: (a, ids) => ((looked = ids), deps.resolveUsers(a, ids)) });
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
