import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { businessesList, type ListKit, parseQuery, problemsOf, setupDone, stageOf } from "./businesses.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit: ListKit = {
  text: (v, max = 300) => typeof v === "string" ? v.trim().slice(0, max) : "",
  InputError,
  UUID_RE: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
};
const NOW = Date.parse("2026-11-16T12:00:00Z");
const uuid = (n: number, prefix = "b") => `${prefix === "b" ? "10000000" : "20000000"}-0000-4000-8000-${String(n).padStart(12, "0")}`;
const IND_A = uuid(1, "i"), IND_B = uuid(2, "i");

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
// A stand in for the Supabase client: every range() returns at most 1,000 rows, like the real API (max_rows), so a
// total built from one request would stop at 1,000. Logs each query so tests can see what was asked.
function fake(tables: Record<string, Row[]>, opts: { fail?: string[] } = {}) {
  const log: { table: string; filters: string[] }[] = [];
  const client = {
    from(table: string) {
      const filters: string[] = [];
      let rows = [...(tables[table] ?? [])];
      let ordered = false;
      const entry = { table, filters };
      log.push(entry);
      const result = (data: Row[]) => opts.fail?.includes(table) ? { data: null, error: new Error(`${table} failed`) } : { data, error: null };
      const b = {
        select: () => b,
        eq: (c: string, v: unknown) => { filters.push(`eq ${c}`); rows = rows.filter((r) => r[c] === v); return b; },
        in: (c: string, vs: unknown[]) => { filters.push(`in ${c}`); rows = rows.filter((r) => vs.includes(r[c])); return b; },
        not: (c: string, _op: string, _v: null) => { filters.push(`not ${c}`); rows = rows.filter((r) => r[c] !== null && r[c] !== undefined); return b; },
        order: (c: string, o?: { ascending?: boolean }) => {
          ordered = true;
          rows.sort((x, y) => String(x[c]).localeCompare(String(y[c])) * (o?.ascending === false ? -1 : 1));
          return b;
        },
        range: (from: number, to: number) => {
          assert(ordered, `${table} is paged without an order`);
          return Promise.resolve(result(rows.slice(from, Math.min(to + 1, from + 1000))));
        },
        limit: (n: number) => Promise.resolve(result(rows.slice(0, n))),
      };
      return b;
    },
  };
  return { admin: client as unknown as SupabaseClient, log };
}

// 2,500 businesses: well above the 1,000 row API limit.
function world(n = 2500) {
  const businesses: Row[] = Array.from({ length: n }, (_, i) => ({
    id: uuid(i + 1), name: `Business ${String(i + 1).padStart(4, "0")}`, industry_id: i % 2 ? IND_B : IND_A,
    phone: `+1555010${String(i).padStart(4, "0")}`, timezone: "America/New_York",
    onboarding_status: i % 3 === 0 ? "active" : "owner_setup", is_active: i % 3 === 0,
    created_at: new Date(Date.parse("2026-01-01T00:00:00Z") + i * 60000).toISOString(),
    suspended_at: null, cancel_at: null, cancelled_at: null,
  }));
  return {
    businesses,
    industries: [{ id: IND_A, name: "Plumbing", slug: "plumbing", is_active: true }, { id: IND_B, name: "Dental", slug: "dental", is_active: false },
      { id: uuid(3, "i"), name: "Unused retired", slug: "x", is_active: false }],
    business_invitations: [] as Row[], business_plans: [] as Row[], subscriptions: [] as Row[],
    platform_alerts: [] as Row[], integrations: [] as Row[], calls: [] as Row[],
  };
}

Deno.test("totals and statistics are exact above 1,000 businesses, and the list is paged", async () => {
  const w = world();
  for (let i = 0; i < 1500; i++) {
    w.business_invitations.push({ id: `inv${i}`, business_id: uuid(i + 1), role: "owner", email: `o${i}@example.test`, owner_name: null,
      status: i < 1200 ? "sent" : "failed", expires_at: "2026-12-01T00:00:00Z", created_at: "2026-02-01T00:00:00Z" });
  }
  const { admin } = fake(w);
  const out = await businessesList(admin, {}, kit, NOW);
  assertEquals(out.total, 2500);
  assertEquals(out.stats.totalBusinesses, 2500);
  assertEquals(out.stats.activeWorkspaces, 834);
  assertEquals(out.stats.pendingInvitations, 1200);
  assertEquals(out.stats.withProblems, 300);   // the 300 failed owner invitations
  assertEquals(out.rows.length, 25);
  assertEquals(out.rows[0].name, "Business 2500");   // newest first
  assertEquals(out.page, 0);
  // the last page, and a page past the end clamps to it
  const last = await businessesList(fake(w).admin, { page: 99, size: 100 }, kit, NOW);
  assertEquals([last.page, last.rows.length, last.size], [24, 100, 100]);
  assertEquals(out.industries.map((i) => i.name), ["Dental", "Plumbing"]);   // active, or used by a business
});

Deno.test("the last call is looked up for the page's businesses only", async () => {
  const w = world(60);
  w.calls.push({ id: "c1", business_id: uuid(60), created_at: "2026-11-15T10:00:00Z" }, { id: "c2", business_id: uuid(60), created_at: "2026-11-16T09:00:00Z" });
  const { admin, log } = fake(w);
  const out = await businessesList(admin, { size: 25 }, kit, NOW);
  assertEquals(log.filter((q) => q.table === "calls").length, 25);
  assertEquals(out.rows[0].lastCallAt, "2026-11-16T09:00:00Z");
  assertEquals(out.rows[1].lastCallAt, null);
  assert(!log.some((q) => q.table === "business_members"), "members are never read");
});

Deno.test("an empty result makes no per business lookups", async () => {
  const { admin, log } = fake(world(0));
  const out = await businessesList(admin, {}, kit, NOW);
  assertEquals([out.total, out.rows.length, out.stats.totalBusinesses], [0, 0, 0]);
  assertEquals(log.filter((q) => q.table === "calls").length, 0);
});

Deno.test("plan is the latest saved version; subscription status is separate", async () => {
  const w = world(4);
  w.business_plans.push(
    { id: "p1", business_id: uuid(1), version: 1, tier: "base", billing_interval: "monthly" },
    { id: "p2", business_id: uuid(1), version: 2, tier: "pro", billing_interval: "yearly" },
    { id: "p3", business_id: uuid(2), version: 1, tier: "base", billing_interval: "monthly" },
  );
  w.subscriptions.push({ id: "s1", business_id: uuid(1), status: "past_due" });
  const by = async (f: Row) => (await businessesList(fake(w).admin, f, kit, NOW)).rows.map((r) => r.id);
  const rows = (await businessesList(fake(w).admin, {}, kit, NOW)).rows;
  const one = rows.find((r) => r.id === uuid(1))!;
  assertEquals(one.plan, { tier: "pro", version: 2, billing_interval: "yearly" });
  assertEquals(one.subscription, { status: "past_due" });
  assertEquals(rows.find((r) => r.id === uuid(3))!.plan, null);
  assertEquals(rows.find((r) => r.id === uuid(3))!.subscription, null);
  assertEquals(await by({ plan: "pro" }), [uuid(1)]);
  assertEquals(await by({ plan: "base" }), [uuid(2)]);   // business 1's base plan is an older version
  assertEquals((await by({ plan: "none" })).sort(), [uuid(3), uuid(4)]);
});

Deno.test("filters: search over name, owner and phone; industry; stage", async () => {
  const w = world(6);
  w.businesses[1].suspended_at = "2026-10-01T00:00:00Z"; w.businesses[1].onboarding_status = "active";
  w.businesses[2].cancel_at = "2026-12-01T00:00:00Z";
  w.businesses[4].cancelled_at = "2026-10-01T00:00:00Z";
  w.businesses[5].onboarding_status = "plan_setup";   // an older status: still a draft
  w.business_invitations.push({ id: "i1", business_id: uuid(4), role: "owner", email: "Sam@Example.test", owner_name: "Sam Rivera", status: "accepted", created_at: "2026-02-01" });
  const ids = async (f: Row) => (await businessesList(fake(w).admin, f, kit, NOW)).rows.map((r) => r.id).sort();
  assertEquals(await ids({ q: "sam@example" }), [uuid(4)]);
  assertEquals(await ids({ q: "RIVERA" }), [uuid(4)]);
  assertEquals(await ids({ q: "business 0003" }), [uuid(3)]);
  assertEquals(await ids({ q: "(555) 010 0002" }), [uuid(3)]);   // digits match however the phone is written
  assertEquals(await ids({ industryId: IND_B }), [uuid(2), uuid(4), uuid(6)]);
  assertEquals(await ids({ stage: "suspended" }), [uuid(2)]);
  assertEquals(await ids({ stage: "cancelled" }), [uuid(5)]);
  assertEquals(await ids({ stage: "cancelling" }), [uuid(3)]);
  assertEquals(await ids({ stage: "live" }), [uuid(1), uuid(4)]);
  assertEquals(await ids({ stage: "draft" }), [uuid(3), uuid(6)]);
  assertEquals(await ids({ stage: "nonsense" }), [1, 2, 3, 4, 5, 6].map((n) => uuid(n)));   // unknown values are ignored
  const all = await businessesList(fake(w).admin, {}, kit, NOW);
  assertEquals(all.rows.find((r) => r.id === uuid(2))!.setupDone, true);   // suspended after finishing setup (BIZ-24)
});

Deno.test("problems: warning and urgent open alerts, failed or expired invitations, broken integrations, failed setup", async () => {
  const w = world(6);
  w.platform_alerts.push(
    { id: "a1", business_id: uuid(1), kind: "payment_failed", title: "A payment failed", severity: "urgent", status: "open" },
    { id: "a2", business_id: uuid(2), kind: "business_suspended", title: "Suspended", severity: "info", status: "open" },
    { id: "a3", business_id: uuid(3), kind: "payment_failed", title: "Old", severity: "warning", status: "resolved" },
    { id: "a4", business_id: uuid(4), kind: "integration_disconnected", title: "Calendar disconnected", severity: "warning", status: "acknowledged" },
    { id: "a5", business_id: null, kind: "platform", title: "Platform wide", severity: "urgent", status: "open" },
  );
  w.integrations.push({ id: "x1", business_id: uuid(4), status: "error" }, { id: "x2", business_id: uuid(5), status: "disconnected" }, { id: "x3", business_id: uuid(6), status: "active" });
  w.business_invitations.push(
    { id: "i1", business_id: uuid(6), role: "owner", email: "a@example.test", status: "sent", expires_at: "2026-11-01T00:00:00Z", created_at: "2026-10-01" },
    { id: "i0", business_id: uuid(6), role: "owner", email: "b@example.test", status: "failed", created_at: "2026-09-01" },   // older, replaced
  );
  w.businesses[0].onboarding_status = "failed";
  const out = await businessesList(fake(w).admin, { problem: true, sort: "problems" }, kit, NOW);
  const got = Object.fromEntries(out.rows.map((r) => [r.id, r.problems.items.map((p: Row) => p.title)]));
  assertEquals(out.rows[0].id, uuid(1));   // two problems, one urgent
  assertEquals(got[uuid(1)], ["A payment failed", "Setup failed"]);
  assertEquals(got[uuid(4)], ["Calendar disconnected"]);   // the alert and the broken integration are one problem
  assertEquals(got[uuid(5)], ["An integration isn't working"]);
  assertEquals(got[uuid(6)], ["The owner invitation expired"]);
  assertEquals(Object.keys(got).sort(), [uuid(1), uuid(4), uuid(5), uuid(6)]);   // info and resolved alerts are not problems
  assertEquals(out.stats.withProblems, 4);
  // a canceled business has no open problems
  assertEquals(problemsOf({ cancelled_at: "2026-01-01", onboarding_status: "failed" }, undefined, [{ kind: "x", title: "y", severity: "urgent" }], [{}]), []);
});

Deno.test("a source that fails is reported, and filters that need it are refused", async () => {
  const w = world(3);
  const out = await businessesList(fake(w, { fail: ["platform_alerts"] }).admin, {}, kit, NOW);
  assertEquals(out.unavailable, ["problems"]);
  assertEquals(out.stats.withProblems, null);
  assertEquals(out.rows[0].problems, null);
  const err = await assertRejects(() => businessesList(fake(w, { fail: ["platform_alerts"] }).admin, { problem: true }, kit, NOW), InputError);
  assertEquals((err as InputError).status, 503);
  await assertRejects(() => businessesList(fake(w, { fail: ["business_plans"] }).admin, { plan: "pro" }, kit, NOW), InputError);
  const calls = await businessesList(fake(w, { fail: ["calls"] }).admin, {}, kit, NOW);
  assertEquals([calls.unavailable, calls.rows[0].lastCallAt], [["lastCalls"], undefined]);
  const core = await assertRejects(() => businessesList(fake(w, { fail: ["businesses"] }).admin, {}, kit, NOW), InputError);
  assertEquals((core as InputError).status, 500);
});

Deno.test("sort by name and oldest", async () => {
  const w = world(3);
  w.businesses[0].name = "zebra Cafe"; w.businesses[1].name = "Apple Dental"; w.businesses[2].name = "mango Spa";
  assertEquals((await businessesList(fake(w).admin, { sort: "name" }, kit, NOW)).rows.map((r) => r.name), ["Apple Dental", "mango Spa", "zebra Cafe"]);
  assertEquals((await businessesList(fake(w).admin, { sort: "oldest" }, kit, NOW)).rows.map((r) => r.name), ["zebra Cafe", "Apple Dental", "mango Spa"]);
});

Deno.test("query parsing ignores anything unexpected", () => {
  assertEquals(parseQuery({ q: 5, industryId: "x", stage: "drop", plan: "gold", problem: "true", sort: "sql", page: -3, size: 7 }, kit),
    { q: "", industryId: null, stage: null, plan: null, problem: false, sort: "newest", page: 0, size: 25 });
  assertEquals(parseQuery({ q: "  Bright SMILE ", page: 2.7, size: 50, problem: true }, kit).q, "bright smile");
  assertEquals(parseQuery({ page: 1e9 }, kit).page, 10000);
});

Deno.test("stage and setup done follow onboarding_status, cancellation and suspension", () => {
  assertEquals(stageOf({ onboarding_status: "active", suspended_at: "x" }), "suspended");
  assertEquals(stageOf({ onboarding_status: "active", suspended_at: "x", cancelled_at: "y" }), "cancelled");
  assertEquals(stageOf({ onboarding_status: "ready" }), "complete");
  assertEquals(stageOf({ onboarding_status: "paused" }), "paused");
  assertEquals(stageOf({ onboarding_status: "failed" }), "failed");
  assertEquals(stageOf({ onboarding_status: null }), "draft");
  for (const s of ["testing", "ready", "active", "paused"]) assertEquals(setupDone(s), true);
  for (const s of ["started", "automation_setup", "failed", null]) assertEquals(setupDone(s), false);
});
