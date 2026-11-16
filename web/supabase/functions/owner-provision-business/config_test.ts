import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { allRows, CONFIG_PERMISSIONS, configHandlers, type ConfigKit, connectionCounts, connectionsFor, deliveriesFor, moduleUsage, switchOffCheck, switchOffMessage } from "./config.ts";
import { PERMISSIONS } from "./settings.ts";
import { ONBOARDING_PERMISSIONS } from "./onboarding.ts";
import { PLATFORM_PERMISSIONS } from "./platform.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit: ConfigKit = {
  text: (v, max = 500) => typeof v === "string" ? v.trim().slice(0, max) : "",
  bool: (v, fallback = false) => typeof v === "boolean" ? v : fallback,
  obj: (v) => v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {},
  requireId: (v) => { if (typeof v !== "string" || !v) throw new InputError("Missing id"); return v; },
  InputError,
};

Deno.test("every new action has a permission, and no name clashes with another module", () => {
  assertEquals(CONFIG_PERMISSIONS, { industry_module_usage: "businesses.view", industry_set_active: "platform.configure", agent_deliveries: "businesses.view" });
  for (const action of Object.keys(CONFIG_PERMISSIONS)) {
    assertEquals([PERMISSIONS[action], ONBOARDING_PERMISSIONS[action], PLATFORM_PERMISSIONS[action]], [undefined, undefined, undefined]);
  }
});

Deno.test("allRows keeps reading pages until one comes back empty, so a lower max_rows can't cut a count short", async () => {
  const data = Array.from({ length: 2345 }, (_, i) => i);
  for (const cap of [1000, 300]) {
    const calls: [number, number][] = [];
    const rows = await allRows<number>((from, to) => {
      calls.push([from, to]);
      return Promise.resolve({ data: data.slice(from, Math.min(to + 1, from + cap)), error: null });
    });
    assertEquals(rows.length, 2345);
    assertEquals(calls[0], [0, 999]);
  }
  await assertRejects(() => allRows(() => Promise.resolve({ data: null, error: new Error("boom") })), Error, "boom");
});

Deno.test("moduleUsage counts enabled rows of businesses in the module's industry only", async () => {
  const admin = { from: (table: string) => {
    const q = { select: () => q, eq: () => q, in: () => q, order: () => q,
      range: (from: number) => Promise.resolve({ data: from > 0 ? [] : table === "businesses"
        ? [{ id: "b1" }, { id: "b2" }]
        : [{ business_id: "b1", module_id: "m1" }, { business_id: "b2", module_id: "m1" }, { business_id: "other", module_id: "m1" }, { business_id: "b1", module_id: "m2" }],
      error: null }) };
    return q;
  } } as unknown as SupabaseClient;
  const usage = await moduleUsage(admin, "ind", ["m1", "m2", "m3"]);
  assertEquals(Object.fromEntries(usage), { m1: 2, m2: 1, m3: 0 });
  assertEquals((await moduleUsage(admin, "ind", [])).size, 0);
});

Deno.test("switching a used module off needs it confirmed; unused modules and older apps go through", () => {
  const current = [{ id: "cal", name: "Calendar", is_active: true }, { id: "sms", name: "Text messages", is_active: true }, { id: "off", name: "Old", is_active: false }];
  const usage = new Map([["cal", 12], ["sms", 0], ["off", 3]]);
  const off = [{ id: "cal", isActive: false }, { id: "sms", isActive: false }, { id: "off", isActive: false }];
  const refused = switchOffCheck(current, off, usage, []);
  assertEquals(refused.unconfirmed, [{ id: "cal", name: "Calendar", businesses: 12 }]);
  assertEquals(refused.switchedOff.map((m) => m.id), ["cal", "sms"]);   // "off" was already off
  assertEquals(switchOffMessage(refused.unconfirmed), "Switching this off removes it from businesses that use it now: 12 businesses lose Calendar. Confirm to continue.");
  assertEquals(switchOffCheck(current, off, usage, ["sms"]).unconfirmed.length, 1);
  assertEquals(switchOffCheck(current, off, usage, ["cal"]).unconfirmed, []);
  assertEquals(switchOffCheck(current, off, usage, "cal").unconfirmed.length, 1);   // not a list: nothing confirmed
  // An older app sends no confirmOff at all: allowed while LEGACY_SWITCH_OFF_ALLOWED, refused once it is switched off.
  assertEquals(switchOffCheck(current, off, usage, undefined).unconfirmed, []);
  assertEquals(switchOffCheck(current, off, usage, undefined).legacy, true);
  assertEquals(switchOffCheck(current, off, usage, undefined, false).unconfirmed.length, 1);
  // Switching on, or leaving as is, never needs a confirmation.
  assertEquals(switchOffCheck(current, [{ id: "cal", isActive: true }, { id: "off", isActive: true }], usage, []).switchedOff, []);
  assertEquals(switchOffMessage([{ id: "a", name: "Calls", businesses: 1 }]), "Switching this off removes it from businesses that use it now: 1 business loses Calls. Confirm to continue.");
});

function fakeIndustry(active: boolean) {
  const writes: unknown[] = [];
  const admin = { from: (table: string) => {
    const q = {
      select: (_c: string, opts?: { head?: boolean }) => { if (opts?.head) return { eq: () => Promise.resolve({ count: 7, error: null }) }; return q; },
      eq: () => q,
      maybeSingle: () => Promise.resolve({ data: table === "industries" ? { id: "ind", name: "Dental", is_active: active } : null, error: null }),
      update: (v: unknown) => { writes.push(v); return { eq: () => Promise.resolve({ error: null }) }; },
    };
    return q;
  } } as unknown as SupabaseClient;
  return { admin, writes };
}

Deno.test("industry_set_active validates, writes once and is audited only when it changed something", async () => {
  for (const [fields, message] of [
    [{ industryId: "ind", active: "false", reason: "retired" }, "Say whether"],
    [{ industryId: "ind", active: false, reason: " x " }, "Give a short reason"],
    [{ active: false, reason: "retired" }, "Missing id"],
  ] as const) {
    const { admin, writes } = fakeIndustry(true);
    await assertRejects(() => configHandlers(admin, { ...fields }, kit).handlers.industry_set_active(), InputError, message);
    assertEquals(writes, []);
  }
  const { admin, writes } = fakeIndustry(true);
  const run = configHandlers(admin, { industryId: "ind", active: false, reason: "  No longer sold " }, kit);
  const result = await run.handlers.industry_set_active() as Record<string, unknown>;
  assertEquals(writes, [{ is_active: false }]);
  assertEquals(run.audited.industry_set_active(result), {
    action: "industry.deactivated", entity_type: "industry", entity_id: "ind",
    old_data: { name: "Dental", is_active: true },
    new_data: { name: "Dental", is_active: false, reason: "No longer sold", businesses_in_industry: 7 },
  });
  const same = fakeIndustry(false);
  const repeat = configHandlers(same.admin, { industryId: "ind", active: false, reason: "No longer sold" }, kit);
  const again = await repeat.handlers.industry_set_active() as Record<string, unknown>;
  assertEquals(same.writes, []);
  assertEquals(repeat.audited.industry_set_active(again), null);
  const back = fakeIndustry(false);
  const re = configHandlers(back.admin, { industryId: "ind", active: true, reason: "Selling again" }, kit);
  assertEquals((re.audited.industry_set_active(await re.handlers.industry_set_active() as Record<string, unknown>) as Record<string, unknown>).action, "industry.reactivated");
});

Deno.test("connectionsFor asks the shared definition in chunks of 1000 ids and says when it isn't applied", async () => {
  const calls: { fn: string; n: number }[] = [];
  const admin = { rpc: (fn: string, args: { p_business_ids: string[] }) => {
    calls.push({ fn, n: args.p_business_ids.length });
    return Promise.resolve({ data: args.p_business_ids.map((id) => ({ business_id: id, live: id === "b7" })), error: null });
  } } as unknown as SupabaseClient;
  const ids = Array.from({ length: 2500 }, (_, i) => `b${i}`);
  const map = await connectionsFor(admin, [...ids, "b1", "b2"]);   // duplicates asked once
  assertEquals(calls, [{ fn: "zella_business_connections", n: 1000 }, { fn: "zella_business_connections", n: 1000 }, { fn: "zella_business_connections", n: 500 }]);
  assertEquals(map?.size, 2500);
  assertEquals(map?.get("b7")?.live, true);
  for (const code of ["PGRST202", "42883"]) {
    const missing = { rpc: () => Promise.resolve({ data: null, error: { code, message: "function does not exist" } }) } as unknown as SupabaseClient;
    assertEquals(await connectionsFor(missing, ["b1"]), null);
    assertEquals(await connectionCounts(missing), null);
  }
  const denied = { rpc: () => Promise.resolve({ data: null, error: { code: "42501", message: "NOT_ALLOWED" } }) } as unknown as SupabaseClient;
  await assertRejects(() => connectionsFor(denied, ["b1"]));   // any other error is never hidden
  await assertRejects(() => connectionCounts(denied));
});

Deno.test("agent_deliveries passes a clean limit, says when it isn't applied and turns an unknown business into 404", async () => {
  const seen: unknown[] = [];
  const answer = (error: { code?: string; message?: string } | null) => ({ rpc: (fn: string, args: unknown) => {
    seen.push([fn, args]);
    return Promise.resolve({ data: error ? null : { deliveries: [{ outcome: "not_ready" }], limit: 5 }, error });
  } }) as unknown as SupabaseClient;
  const run = (admin: SupabaseClient, fields: Record<string, unknown>) => configHandlers(admin, fields, kit).handlers.agent_deliveries();
  assertEquals(await run(answer(null), { businessId: "b1", limit: 5 }), { available: true, businessId: "b1", deliveries: [{ outcome: "not_ready" }], limit: 5 });
  await run(answer(null), { businessId: "b1", limit: "lots" });
  assertEquals(seen[1], ["zella_admin_agent_deliveries", { p_business_id: "b1", p_limit: 25 }]);
  assertEquals(await run(answer({ code: "PGRST202" }), { businessId: "b1" }), { available: false, businessId: "b1", deliveries: [] });
  const err = await assertRejects(() => run(answer({ code: "P0002", message: "BUSINESS_NOT_FOUND" }), { businessId: "b1" }), InputError);
  assertEquals((err as InputError).status, 404);
  await assertRejects(() => run(answer({ code: "42501", message: "NOT_ALLOWED" }), { businessId: "b1" }));
  await assertRejects(() => run(answer(null), {}), InputError, "Missing id");
  const summary = { rpc: (_fn: string, args: { p_business_ids: string[] }) => Promise.resolve({ data: args.p_business_ids.map((id) => ({ business_id: id, not_ready_7d: 2 })), error: null }) } as unknown as SupabaseClient;
  assertEquals((await deliveriesFor(summary, ["a", "b", "a"]))?.size, 2);
  assertEquals(await deliveriesFor({ rpc: () => Promise.resolve({ data: null, error: { code: "42883" } }) } as unknown as SupabaseClient, ["a"]), null);
});
