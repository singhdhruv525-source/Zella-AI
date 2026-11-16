// BIZ-22 part b: audited support access. Every open recorded once per admin and business in the dedupe window, kept
// out of Activity; contacts masked; the reveal needs a reason and records it before anything is read out (fails closed).
import { assert, assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { DETAIL_PERMISSIONS, REVEAL_PERMISSION, VIEW_DEDUPE_MINUTES, businessDetail, detailHandlers } from "./detail.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => String(v), InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";

function fake(rows: Record<string, unknown[]>, opts: { recentView?: boolean; failInsert?: boolean } = {}) {
  const inserts: { table: string; row: Record<string, unknown> }[] = [];
  const filters: { table: string; f: unknown[] }[] = [];
  const client = {
    auth: { admin: { getUserById: (id: string) => Promise.resolve({ data: { user: { id, email: `${id}@people.example`, factors: [] } } }) } },
    rpc: () => Promise.resolve({ data: null, error: null }),
    from(table: string) {
      let isViewCheck = false;
      const chain: Record<string, unknown> = {
        select: () => chain, order: () => chain, limit: () => chain, gte: () => chain, is: () => chain, neq: () => chain,
        not: (...f: unknown[]) => (filters.push({ table, f: ["not", ...f] }), chain),
        in: (...f: unknown[]) => (filters.push({ table, f: ["in", ...f] }), chain),
        eq: (c: string, v: unknown) => { filters.push({ table, f: ["eq", c, v] }); if (c === "action" && v === "business.viewed") isViewCheck = true; return chain; },
        maybeSingle: () => Promise.resolve({ data: (rows[table] ?? [])[0] ?? null, error: null }),
        insert: (row: Record<string, unknown>) => { inserts.push({ table, row }); return Promise.resolve({ error: opts.failInsert ? { message: "down" } : null }); },
        then: (resolve: (v: unknown) => unknown) => resolve({ data: isViewCheck ? (opts.recentView ? [{ id: "v1" }] : []) : rows[table] ?? [], error: null, count: 0 }),
      };
      return chain;
    },
  };
  return { client: client as unknown as SupabaseClient, inserts, filters };
}
const ROWS = {
  businesses: [{ id: BIZ }],
  business_invitations: [{ id: "i1", role: "owner", email: "owner@people.example", last_error: "Mailbox owner@people.example full" }],
  business_members: [{ user_id: "u1", role: "owner", status: "active" }],
  calls: [{ id: "c1", from_number: "+15550100123", to_number: "+15550100100" }],
  integrations: [{ id: "g1", account_email: "acct@people.example", error_message: null }],
};
const deps = { loadSetup: () => Promise.resolve({ business: { id: BIZ, industry_id: "i" }, invitation: { email: "owner@people.example", last_error: null }, receptionist: {} }) };

Deno.test("support access: the defaults", () => {
  assertEquals(VIEW_DEDUPE_MINUTES, 30);
  assertEquals(DETAIL_PERMISSIONS.business_contacts_reveal, REVEAL_PERMISSION);
  assertEquals(REVEAL_PERMISSION, "businesses.manage");
});

Deno.test("an open is recorded once in the window, and never shown in Activity", async () => {
  const first = fake(ROWS);
  await businessDetail(first.client, BIZ, new Set(["businesses.view", "audit.view"]), { ...deps, viewerId: "admin-1" });
  const views = first.inserts.filter((i) => i.row.action === "business.viewed");
  assertEquals(views.length, 1);
  assertEquals([views[0].row.user_id, views[0].row.business_id], ["admin-1", BIZ]);
  assert(first.filters.some((x) => x.table === "audit_logs" && x.f[0] === "not" && String(x.f[3]).includes("business.viewed")), "activity excludes view rows");
  const again = fake(ROWS, { recentView: true });
  await businessDetail(again.client, BIZ, new Set(["businesses.view"]), { ...deps, viewerId: "admin-1" });
  assertEquals(again.inserts.length, 0, "a second open inside the window records nothing");
});

Deno.test("people's emails are masked on the page", async () => {
  const out = await businessDetail(fake(ROWS).client, BIZ, new Set(["businesses.view"]), deps);
  const text = JSON.stringify({ m: out.members, i: out.invitations, inv: out.invitation });
  assertFalse(/[a-z]{2,}@people\.example/.test(text), text);
  assertEquals(out.invitations[0].last_error, "Mailbox o…@people.example full");
  assert(out.contactsMasked);
});

const reveal = (f: ReturnType<typeof fake>, reason: unknown, userId = "admin-1") =>
  detailHandlers(f.client, { businessId: BIZ, reason }, kit, userId).handlers.business_contacts_reveal() as Promise<Record<string, unknown[]>>;

Deno.test("reveal: a reason of 10 to 300 characters is required", async () => {
  await assertRejects(() => reveal(fake(ROWS), "short"), InputError, "at least 10");
  await assertRejects(() => reveal(fake(ROWS), "x".repeat(301)), InputError, "under 300");
});

Deno.test("reveal: one audit row with the reason and field names, no values; then the values", async () => {
  const f = fake(ROWS);
  const out = await reveal(f, "Owner asked us to check the invite address");
  assertEquals(f.inserts.length, 1);
  const row = f.inserts[0].row;
  assertEquals(row.action, "support.contacts_revealed");
  assertEquals((row.new_data as Record<string, unknown>).reason, "Owner asked us to check the invite address");
  assertFalse(/@|\d{7,}/.test(JSON.stringify(row.new_data)), JSON.stringify(row.new_data));
  assertEquals((out.invitations[0] as Record<string, unknown>).email, "owner@people.example");
  assertEquals((out.calls[0] as Record<string, unknown>).from_number, "+15550100123");
  assertEquals(detailHandlers(f.client, {}, kit).audited.business_contacts_reveal({}), null);
});

Deno.test("reveal: when the audit row can't be written, nothing is revealed (fails closed)", async () => {
  const f = fake(ROWS, { failInsert: true });
  const err = await assertRejects(() => reveal(f, "Owner asked us to check the invite address"), InputError) as InputError;
  assertEquals(err.status, 503);
});

Deno.test("reveal: an unknown business is refused", async () => {
  const err = await assertRejects(() => reveal(fake({ ...ROWS, businesses: [] }), "Owner asked us to check the invite address"), InputError) as InputError;
  assertEquals(err.status, 404);
});
