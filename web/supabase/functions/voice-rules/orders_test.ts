// lookup_order with the database and Shopify mocked (synthetic orders only).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { callerAssurance, callerMatches, lookupOrder, MAX_FAILED_PER_CALL, orderSearch, orderSummary, samePhone } from "./orders.ts";
import { planBrainTool } from "../_shared/vapi-brain-tools.js";

const ORDER = { name: "#1001", createdAt: "2026-11-02T15:00:00Z", cancelledAt: null, displayFinancialStatus: "PAID", displayFulfillmentStatus: "FULFILLED",
  phone: null, email: "ana@example.test", customer: { phone: "+1 (512) 555-0101", email: "Ana@Example.test" }, shippingAddress: { phone: null },
  fulfillments: [{ status: "SUCCESS", trackingInfo: [{ company: "UPS", number: "1Z999AA10123456784", url: "https://ups.test/x" }] }] };
const ctx = { ok: true, integration_id: "i1", shop_domain: "demo-store.myshopify.com", access_token: "test_store_token_not_real_0002", caller_number: "+15125550101" };
type Call = { fn: string; args: Record<string, unknown> };
function db(context: unknown = ctx) {
  const calls: Call[] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return Promise.resolve({ data: fn === "zella_store_lookup_context" ? context : null, error: null }); };
  return { rpc, calls };
}
const shop = (status: number, body: unknown, seen: { url?: string; init?: RequestInit }[] = []) =>
  ((url: string, init: RequestInit) => { seen.push({ url, init }); return Promise.resolve(new Response(JSON.stringify(body), { status })); }) as unknown as typeof fetch;

Deno.test("order search by its number, with or without #", () => { assertEquals(orderSearch("1001"), "name:#1001"); assertEquals(orderSearch("#1001"), "name:#1001"); });
Deno.test("the caller matches by the number they call from, or the order's email", () => {
  assert(callerMatches(ORDER, "+15125550101", null));
  assert(callerMatches(ORDER, "+44 20 0000 0000", "ana@example.test"));
  assert(!callerMatches(ORDER, "+15125550199", null));
  assert(!callerMatches(ORDER, null, "someone@else.test"));
  assert(!callerMatches(ORDER, null, "")); // nothing given, nothing matched
});
Deno.test("only status and tracking are said: no address, items or amounts", () => {
  const s = orderSummary(ORDER);
  assertEquals(s.say.startsWith("Order #1001 was placed on November 2. Payment: paid. Shipping: fulfilled. It was shipped with UPS, tracking number ending 6784."), true);
  assertEquals(s.status.tracking_ending, "6784");
  assert(!JSON.stringify(s).includes("1Z999AA10123456784") && !JSON.stringify(s).includes("ana@"));
  assert(orderSummary({ ...ORDER, cancelledAt: "2026-11-03T00:00:00Z" }).say.includes("It was cancelled."));
});
Deno.test("found and the caller matches: the summary; logged as found, without content", async () => {
  const d = db(), seen: { url?: string; init?: RequestInit }[] = [];
  const r = await lookupOrder(d.rpc, "b1", "call-1", { order_number: "1001" }, shop(200, { data: { orders: { nodes: [ORDER] } } }, seen));
  assertEquals([r.status, (r.order as Record<string, unknown>).fulfillment], ["found", "fulfilled"]);
  assertEquals(seen[0].url, "https://demo-store.myshopify.com/admin/api/2026-07/graphql.json");
  assertEquals((seen[0].init!.headers as Record<string, string>)["X-Shopify-Access-Token"], ctx.access_token);
  assert(!JSON.stringify(r).includes(ctx.access_token));
  const log = d.calls.find((c) => c.fn === "zella_store_lookup_log")!;
  assertEquals([log.args.p_result, log.args.p_verified], ["found_caller_id", true]);
  assertEquals(r.verified_by, "caller_id");
  assert(!JSON.stringify(log.args).includes("UPS"));
});
Deno.test("not matching and not found get the same answer (no probing for order numbers)", async () => {
  const a = await lookupOrder(db({ ...ctx, caller_number: "+15125550199" }).rpc, "b1", "c", { order_number: "1001" }, shop(200, { data: { orders: { nodes: [ORDER] } } }));
  const b = await lookupOrder(db().rpc, "b1", "c", { order_number: "9999" }, shop(200, { data: { orders: { nodes: [] } } }));
  assertEquals(a, b); assertEquals(a.status, "unverified");
});
Deno.test("the caller gives the order's email instead: found", async () => {
  const r = await lookupOrder(db({ ...ctx, caller_number: null }).rpc, "b1", "c", { order_number: "#1001", email: "ANA@example.test" }, shop(200, { data: { orders: { nodes: [ORDER] } } }));
  assertEquals(r.status, "found");
});
Deno.test("store refuses the token: logged as unauthorized (the integration is flagged), caller offered a message", async () => {
  const d = db();
  const r = await lookupOrder(d.rpc, "b1", "c", { order_number: "1001" }, shop(401, { errors: "Invalid API key" }));
  assertEquals(r.status, "store_unavailable");
  assertEquals(d.calls.find((c) => c.fn === "zella_store_lookup_log")!.args.p_result, "store_unauthorized");
});
Deno.test("store down or slow: a message is taken, nothing guessed", async () => {
  const slow = (() => Promise.reject(new DOMException("timeout", "TimeoutError"))) as unknown as typeof fetch;
  assertEquals((await lookupOrder(db().rpc, "b1", "c", { order_number: "1001" }, slow)).status, "store_unavailable");
  assertEquals((await lookupOrder(db().rpc, "b1", "c", { order_number: "1001" }, shop(500, {}))).status, "store_unavailable");
});
Deno.test("no store connected, or Orders off: the database says so; Shopify is never called", async () => {
  let called = false; const never = (() => { called = true; return Promise.resolve(new Response("{}")); }) as unknown as typeof fetch;
  assertEquals((await lookupOrder(db({ ok: false, status: "no_store" }).rpc, "b1", "c", { order_number: "1001" }, never)).status, "no_store");
  assertEquals((await lookupOrder(db({ ok: false, status: "not_available" }).rpc, "b1", "c", { order_number: "1001" }, never)).status, "not_available");
  assertEquals((await lookupOrder(db().rpc, "b1", "c", {}, never)).status, "need_info");
  assertEquals(called, false);
});
Deno.test("the shared tool check: lookup_order is known, its order number must look like one", () => {
  const ctxCall = { callId: "c", calledNumber: null, vapiNumberId: null, callerNumber: "+15125550101", fallbackBusinessId: null };
  const ok = planBrainTool({ id: "t1", name: "lookup_order", arguments: { order_number: "#1001" } }, ctxCall);
  assertEquals([ok.known, ok.invalid, ok.record.p_tool], [true, null, "lookup_order"]);
  const bad = planBrainTool({ id: "t2", name: "lookup_order", arguments: { order_number: "1001; drop" } }, ctxCall);
  assert(bad.invalid?.includes("order_number"));
});

Deno.test("assurance: which check let the caller hear it", () => {
  assertEquals(callerAssurance(ORDER, "+15125550101", null), "caller_id");
  assertEquals(callerAssurance(ORDER, "+15125550199", "ana@example.test"), "email");
  assertEquals(callerAssurance(ORDER, "+15125550199", "ana@example.test.evil"), null);
  assertEquals(callerAssurance(ORDER, null, null), null);
});
Deno.test("phone numbers: a number abroad never matches one at home with the same last 10 digits", () => {
  assert(samePhone("+1 (512) 555-0101", "+15125550101"));
  assert(samePhone("(512) 555-0101", "+15125550101"));            // store number saved without +1
  assert(samePhone("+44 7700 900123", "+447700900123"));
  assert(!samePhone("+91 98765 43210", "+19876543210"));           // same last 10, different country
  assert(!samePhone("+44 7700 900123", "+17700900123"));
  assert(!samePhone("555-0101", "+15125550101"));                  // too short to compare
  assert(!samePhone(null, "+15125550101"));
  const abroad = { ...ORDER, customer: { phone: "+91 98765 43210", email: "x@example.test" } };
  assert(!callerMatches(abroad, "+19876543210", null));
});
Deno.test("after 3 lookups that didn't match in a call, no more are tried; the store is not asked", async () => {
  let called = false; const never = (() => { called = true; return Promise.resolve(new Response("{}")); }) as unknown as typeof fetch;
  const d = db({ ...ctx, failed_this_call: MAX_FAILED_PER_CALL });
  const r = await lookupOrder(d.rpc, "b1", "c", { order_number: "1001", email: "ana@example.test" }, never);
  assertEquals([r.status, called], ["unverified", false]);
  const log = d.calls.find((c) => c.fn === "zella_store_lookup_log")!;
  assertEquals([log.args.p_result, log.args.p_integration_id], ["limited", null]);
  // and from one number over a day
  const r2 = await lookupOrder(db({ ...ctx, failed_this_number_day: 6 }).rpc, "b1", "c", { order_number: "1001" }, never);
  assertEquals([r2.status, called], ["unverified", false]);
  // below the limit, or with an older database that gives no counts: looked up as before
  assertEquals((await lookupOrder(db({ ...ctx, failed_this_call: 2 }).rpc, "b1", "c", { order_number: "1001" }, shop(200, { data: { orders: { nodes: [ORDER] } } }))).status, "found");
});
Deno.test("the email check gives found_email", async () => {
  const d = db({ ...ctx, caller_number: null });
  await lookupOrder(d.rpc, "b1", "c", { order_number: "1001", email: "ana@example.test" }, shop(200, { data: { orders: { nodes: [ORDER] } } }));
  assertEquals(d.calls.find((c) => c.fn === "zella_store_lookup_log")!.args.p_result, "found_email");
});
