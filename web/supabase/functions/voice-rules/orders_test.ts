// lookup_order with the database and Shopify mocked (synthetic orders only). Policy: docs/ORDER_LOOKUP_ASSURANCE_2026-11-05.md.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { assess, callerMatches, disclosure, lookupOrder, MAX_FAILED_BUSINESS_HOUR, MAX_FAILED_PER_CALL, MAX_FAILED_PER_ORDER_DAY, ORDER_QUERY, orderRef,
  orderSearch, samePhone } from "./orders.ts";
import { planBrainTool } from "../_shared/vapi-brain-tools.js";

const TRACKING = "1Z999AA10123456784";
// what Shopify could return; the query no longer asks for payment or tracking numbers, but a store (or a mock) sending
// them anyway must not make them reach the caller
const ORDER = { name: "#1001", createdAt: "2026-11-02T15:00:00Z", cancelledAt: null, displayFulfillmentStatus: "FULFILLED", displayFinancialStatus: "PAID",
  phone: null, email: "ana@example.test", customer: { phone: "+1 (512) 555-0101", email: "Ana@Example.test" }, shippingAddress: { phone: "+1 512 555 0177" },
  fulfillments: [{ status: "SUCCESS", trackingInfo: [{ company: "UPS", number: TRACKING, url: "https://ups.test/x" }] }] };
const ctx = { ok: true, reservation_id: "reservation-1", integration_id: "i1", shop_domain: "demo-store.myshopify.com", access_token: "test_store_token_not_real_0002", caller_number: "+15125550101" };
type Call = { fn: string; args: Record<string, unknown> };
function db(context: unknown = ctx) {
  const calls: Call[] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return Promise.resolve({ data: fn === "zella_store_lookup_begin" ? context : null, error: null }); };
  return { rpc, calls };
}
const shop = (status: number, body: unknown, seen: { url?: string; init?: RequestInit }[] = []) =>
  ((url: string, init: RequestInit) => { seen.push({ url, init }); return Promise.resolve(new Response(JSON.stringify(body), { status })); }) as unknown as typeof fetch;
const found = (o: unknown = ORDER) => shop(200, { data: { orders: { nodes: [o] } } });
const never = () => { const s = { called: false }; return { s, f: (() => { s.called = true; return Promise.resolve(new Response("{}")); }) as unknown as typeof fetch }; };
const leaks = (r: unknown) => { const t = JSON.stringify(r); return [TRACKING, TRACKING.slice(-4), "ups.test", "PAID", "paid", "Ana@", "ana@", "0101", "0177"].filter((x) => t.includes(x)); };

Deno.test("order search by its number, with or without #", () => { assertEquals(orderSearch("1001"), "name:#1001"); assertEquals(orderSearch("#1001"), "name:#1001"); });
Deno.test("the store is never asked for payment status, tracking numbers or tracking links", () => {
  assert(!/displayFinancialStatus|number|url/.test(ORDER_QUERY.replace("phone", "")), ORDER_QUERY);
});

Deno.test("levels: none, recipient, one factor, two factors", () => {
  assertEquals(assess(ORDER, "+15125550199", null).level, "none");                         // unauthorized caller
  assertEquals(assess(ORDER, "+15125550199", "someone@else.test").level, "none");
  assertEquals(assess(ORDER, "+15125550177", null).level, "recipient");                    // the shipping phone
  assertEquals(assess(ORDER, "+15125550101", null).level, "one_factor");                   // buyer's phone alone
  assertEquals(assess(ORDER, null, "ANA@example.test ").level, "one_factor");               // email alone
  assertEquals(assess(ORDER, "+15125550177", "ana@example.test").level, "one_factor");      // recipient phone + buyer email: not two buyer factors
  assertEquals(assess(ORDER, "+15125550101", "ana@example.test").level, "two_factor");
  assertEquals(assess(ORDER, "+15125550101", "ana@example.test.evil").level, "one_factor");
});
Deno.test("phone numbers: a number abroad never matches one at home with the same last 10 digits", () => {
  assert(samePhone("+1 (512) 555-0101", "+15125550101"));
  assert(samePhone("(512) 555-0101", "+15125550101"));
  assert(!samePhone("+91 98765 43210", "+19876543210"));
  assert(!samePhone("555-0101", "+15125550101"));
  assert(!callerMatches({ ...ORDER, customer: { phone: "+91 98765 43210" }, shippingAddress: {} }, "+19876543210", null));
});

Deno.test("unauthorized caller: the same answer as for an order that doesn't exist (no probing)", async () => {
  const a = await lookupOrder(db({ ...ctx, caller_number: "+15125550199" }).rpc, "b1", "c", { order_number: "1001", email: "guess@else.test" }, found());
  const b = await lookupOrder(db().rpc, "b1", "c", { order_number: "9999" }, shop(200, { data: { orders: { nodes: [] } } }));
  assertEquals(a, b); assertEquals(a.status, "unverified"); assertEquals(leaks(a), []);
});
Deno.test("shared or spoofed caller ID (the buyer's number, someone else on it): only whether it shipped", async () => {
  const d = db();   // calling from the buyer's number, no email
  const r = await lookupOrder(d.rpc, "b1", "c", { order_number: "1001" }, found());
  assertEquals([r.status, r.level], ["found", "one_factor"]);
  assert(String(r.say).includes("has shipped") && !/November|UPS|placed/.test(String(r.say)), String(r.say));
  assertEquals(Object.keys(r.order as object).sort(), ["order", "state"]);
  assertEquals(leaks(r), []);
  assertEquals(d.calls.find((c) => c.fn === "zella_store_lookup_finish")!.args.p_result, "found_one_factor");
});
Deno.test("email alone (it may be known to others): the same, no more", async () => {
  const r = await lookupOrder(db({ ...ctx, caller_number: null }).rpc, "b1", "c", { order_number: "1001", email: "ana@example.test" }, found());
  assertEquals(r.level, "one_factor"); assertEquals(leaks(r), []);
});
Deno.test("buyer's phone and email: the day it was placed and the carrier; still no tracking number", async () => {
  const d = db();
  const r = await lookupOrder(d.rpc, "b1", "c", { order_number: "#1001", email: "ana@example.test" }, found());
  assertEquals(r.level, "two_factor");
  assert(/November 2/.test(String(r.say)) && /UPS/.test(String(r.say)), String(r.say));
  assertEquals(leaks(r), []);
  assert(/phone number or email on the order/.test(String(r.say)), "trusted channel not offered");
});
Deno.test("the shipping recipient: whether it shipped, nothing else - not even a cancellation or the order number", async () => {
  const r = await lookupOrder(db({ ...ctx, caller_number: "+15125550177" }).rpc, "b1", "c", { order_number: "1001" }, found());
  assertEquals(r.level, "recipient"); assertEquals(r.order, { shipping: "has shipped" }); assertEquals(leaks(r), []);
  const c = await lookupOrder(db({ ...ctx, caller_number: "+15125550177" }).rpc, "b1", "c", { order_number: "1001" }, found({ ...ORDER, cancelledAt: "2026-11-03T00:00:00Z" }));
  assert(!/cancel/i.test(JSON.stringify(c)), JSON.stringify(c));
});
Deno.test("tracking: never said at any level, even if the store returns it", () => {
  for (const level of ["recipient", "one_factor", "two_factor"] as const) {
    const d = disclosure(ORDER, level)!;
    assertEquals(leaks(d), [], level);
  }
  assertEquals(disclosure(ORDER, "none"), null);
});

Deno.test("limits: per call, per caller number, per order number, per business; the store isn't asked", async () => {
  for (const extra of [{ failed_this_call: MAX_FAILED_PER_CALL }, { failed_this_number_day: 6 }, { failed_this_order_day: MAX_FAILED_PER_ORDER_DAY },
                       { failed_business_hour: MAX_FAILED_BUSINESS_HOUR }]) {
    const n = never(); const d = db({ ...ctx, ...extra });
    const r = await lookupOrder(d.rpc, "b1", "c", { order_number: "1001", email: "ana@example.test" }, n.f);
    assertEquals([r.status, n.s.called], ["unverified", false], JSON.stringify(extra));
    const log = d.calls.find((c) => c.fn === "zella_store_lookup_finish")!;
    assertEquals([log.args.p_result, log.args.p_integration_id], ["limited", null]);
  }
  // below the limits, or an older database that gives no counts: looked up as usual
  assertEquals((await lookupOrder(db({ ...ctx, failed_this_order_day: 4 }).rpc, "b1", "c", { order_number: "1001" }, found())).status, "found");
});
Deno.test("the order number is counted by a reference, the same with or without #, never as given", async () => {
  assertEquals(await orderRef("b1", "#1001"), await orderRef("b1", "1001"));
  assert((await orderRef("b1", "1001")) !== (await orderRef("b2", "1001")));
  const d = db();
  await lookupOrder(d.rpc, "b1", "c", { order_number: "1001" }, found());
  const sent = JSON.stringify(d.calls.map((c) => c.args));
  assert(!sent.includes("1001") && !sent.includes(TRACKING), sent);
  assertEquals(d.calls[0].args.p_order_ref, await orderRef("b1", "1001"));
});

Deno.test("store refuses the token: logged as unauthorized, caller offered a message", async () => {
  const d = db();
  const r = await lookupOrder(d.rpc, "b1", "c", { order_number: "1001" }, shop(401, { errors: "Invalid API key" }));
  assertEquals(r.status, "store_unavailable");
  assertEquals(d.calls.find((c) => c.fn === "zella_store_lookup_finish")!.args.p_result, "store_unauthorized");
});
Deno.test("store down or slow: a message is taken, nothing guessed", async () => {
  const slow = (() => Promise.reject(new DOMException("timeout", "TimeoutError"))) as unknown as typeof fetch;
  assertEquals((await lookupOrder(db().rpc, "b1", "c", { order_number: "1001" }, slow)).status, "store_unavailable");
});
Deno.test("no store connected, or Orders off: the database says so; Shopify is never called", async () => {
  const n = never();
  assertEquals((await lookupOrder(db({ ok: false, status: "no_store" }).rpc, "b1", "c", { order_number: "1001" }, n.f)).status, "no_store");
  assertEquals((await lookupOrder(db({ ok: false, status: "not_available" }).rpc, "b1", "c", { order_number: "1001" }, n.f)).status, "not_available");
  assertEquals((await lookupOrder(db().rpc, "b1", "c", {}, n.f)).status, "need_info");
  assertEquals(n.s.called, false);
});
Deno.test("the token goes only to the store's own address and never back", async () => {
  const seen: { url?: string; init?: RequestInit }[] = [];
  const r = await lookupOrder(db().rpc, "b1", "c", { order_number: "1001" }, shop(200, { data: { orders: { nodes: [ORDER] } } }, seen));
  assertEquals(seen[0].url, "https://demo-store.myshopify.com/admin/api/2026-07/graphql.json");
  assert(!JSON.stringify(r).includes(ctx.access_token));
});
Deno.test("the caller can't supply the number that is checked: only the phone network's number reaches the lookup", () => {
  const ctxCall = { callId: "c", calledNumber: null, vapiNumberId: null, callerNumber: "+15125550199", fallbackBusinessId: null };
  const p = planBrainTool({ id: "t1", name: "lookup_order", arguments: { order_number: "#1001", caller_number: "+15125550101", phone: "+15125550101" } }, ctxCall);
  assertEquals((p.record.p_args as Record<string, unknown>).caller_number, "+15125550199");
  const bad = planBrainTool({ id: "t2", name: "lookup_order", arguments: { order_number: "1001; drop" } }, ctxCall);
  assert(bad.invalid?.includes("order_number"));
});

// A failed guess that can't be recorded leaves the counters unchanged; that call must get no more lookups (fail closed).
Deno.test("a failed guess that can't be recorded stops further lookups on that call", async () => {
  let logWrites = 0;
  let pending = false;
  const failingLog = (fn: string, _args: Record<string, unknown>) => {
    if (fn === "zella_store_lookup_begin") {
      const data = pending ? { ok: false, status: "limited" } : ctx;
      pending = true;
      return Promise.resolve({ data, error: null });
    }
    logWrites++;
    return Promise.resolve({ data: null, error: { message: "log down" } });
  };
  const empty = shop(200, { data: { orders: { nodes: [] } } });
  const first = await lookupOrder(failingLog, "b1", "call-x", { order_number: "9999" }, empty);
  assertEquals(first.status, "unverified");
  assert(String(first.say).includes("can't check orders"), String(first.say));   // refused, not "couldn't confirm"
  assertEquals(logWrites, 2);                                                       // one retry, then refuse
  const n = never();
  const second = await lookupOrder(failingLog, "b1", "call-x", { order_number: "1001" }, n.f);
  assertEquals(second.status, "unverified");
  assertEquals(n.s.called, false);                                                  // Shopify is not asked again
  const other = await lookupOrder(db().rpc, "b1", "call-y", { order_number: "1001" }, found());
  assertEquals(other.status, "found");                                              // other calls are unaffected
});
Deno.test("a log write that succeeds on retry does not block the call", async () => {
  let fails = 1;
  const flaky = (fn: string) => {
    if (fn === "zella_store_lookup_begin") return Promise.resolve({ data: ctx, error: null });
    return Promise.resolve(fails-- > 0 ? { data: null, error: { message: "blip" } } : { data: null, error: null });
  };
  const r = await lookupOrder(flaky, "b1", "call-z", { order_number: "9999" }, shop(200, { data: { orders: { nodes: [] } } }));
  assert(String(r.say).includes("couldn't confirm"), String(r.say));
  const again = await lookupOrder(db().rpc, "b1", "call-z", { order_number: "1001" }, found());
  assertEquals(again.status, "found");
});


Deno.test("unknown reservation state fails closed before Shopify", async () => {
  for (const rpc of [
    db({ ...ctx, reservation_id: undefined }).rpc,
    async () => ({ data: null, error: new Error("offline") }),
    async () => { throw new Error("transport failed"); },
  ]) {
    const n = never();
    assertEquals((await lookupOrder(rpc, "b1", "c", { order_number: "1001" }, n.f)).status, "unverified");
    assertEquals(n.s.called, false);
  }
});
