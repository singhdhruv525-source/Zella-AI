// providers.ts against local fakes of Telnyx and Vapi (a real HTTP server on 127.0.0.1) and a stand in for the
// database functions. Nothing here reaches a real provider: every request is checked to go to the fake.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { PlatformKit } from "./platform.ts";
import { CONFIRM_WORD, NOT_CONNECTED, ORDERS_OFF, PROVIDER_PERMISSIONS, providerBase, providerHandlers } from "./providers.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit: PlatformKit = {
  text: (v, max = 300) => typeof v === "string" ? v.trim().slice(0, max) : "",
  bool: (v, fallback = false) => typeof v === "boolean" ? v : fallback,
  obj: (v) => v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {},
  requireId: (v) => { if (typeof v !== "string" || !v) throw new InputError("Missing id"); return v; }, InputError,
};
type Json = Record<string, unknown>;
const KEY = "a2000000-0000-0000-0000-000000000001";

// The fake providers: what they were asked, and what they answer (set per test).
const seen: { method: string; path: string; auth: string | null; body: Json | null }[] = [];
let answer: (method: string, path: string, body: Json | null) => Response | Promise<Response> = () => Response.json({});
const fake = Deno.serve({ hostname: "127.0.0.1", port: 54478, onListen: () => {} }, async (req) => {
  const u = new URL(req.url);
  const body = req.method === "GET" || req.method === "DELETE" ? null : await req.json();
  seen.push({ method: req.method, path: u.pathname + u.search, auth: req.headers.get("authorization"), body });
  return await answer(req.method, u.pathname + decodeURIComponent(u.search), body);
});
const BASE = "http://127.0.0.1:54478";
// Every request must go to the fake: anything else fails the test before it leaves the machine.
const onlyFake: typeof fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.startsWith(BASE)) throw new Error(`a test tried to reach ${url}`);
  return fetch(input, init);
};
const env = (over: Record<string, string> = {}) => {
  const all: Record<string, string> = { TELNYX_API_KEY: "test-telnyx", VAPI_API_KEY: "test-vapi", TELNYX_API_BASE: `${BASE}/telnyx`, VAPI_API_BASE: `${BASE}/vapi`, VAPI_TELNYX_CREDENTIAL_ID: "cred_test", ...over };
  return { get: (k: string) => all[k] || undefined };
};

// A stand in for the database: the order functions as a small state machine, and the number_orders_enabled setting.
function db(opts: { enabled?: boolean; refuse?: string } = {}) {
  const calls: [string, Json][] = [];
  const orders = new Map<string, Json>();
  const admin = {
    from: (table: string) => ({ select: () => ({ eq: (_c: string, v: string) => ({ maybeSingle: async () => {
      if (table === "platform_settings") return { data: { value: opts.enabled ?? true }, error: null };
      return { data: orders.get(v) ?? null, error: null };
    } }) }) }),
    rpc: async (fn: string, args: Json) => {
      calls.push([fn, args]);
      if (opts.refuse) return { data: null, error: { message: opts.refuse } };
      if (fn === "zella_number_orders_list") return { data: [...orders.values()], error: null };
      if (fn === "zella_number_order_request") {
        const o = { id: `o${orders.size + 1}`, kind: args.p_kind, e164: args.p_e164, status: "requested", vapi_phone_number_id: args.p_vapi_id };
        orders.set(o.id, o); return { data: o, error: null };
      }
      const o = orders.get(String(args.p_id));
      if (!o) return { data: null, error: { message: "NOT_FOUND" } };
      if (fn === "zella_number_order_decide") { if (o.status !== "requested") return { data: null, error: { message: "NOT_PENDING" } }; o.status = args.p_approve ? "approved" : "rejected"; }
      if (fn === "zella_number_order_claim") { if (o.status !== "approved") return { data: null, error: { message: "NOT_APPROVED" } }; o.status = "placing"; }
      if (fn === "zella_number_order_finish") Object.assign(o, { status: args.p_outcome, provider_order_id: args.p_order_id, provider_number_id: args.p_number_id, vapi_phone_number_id: args.p_vapi_id ?? o.vapi_phone_number_id, error: args.p_error });
      if (fn === "zella_number_order_cancel") o.status = "cancelled";
      return { data: { ...o }, error: null };
    },
  } as unknown as SupabaseClient;
  return { admin, calls, orders };
}
const run = (d: ReturnType<typeof db>, action: string, fields: Json, role = "zella_owner", e = env(), timeoutMs = 2000) =>
  providerHandlers(d.admin, fields, kit, "admin-user", role, { env: e, fetch: onlyFake, timeoutMs }).handlers[action]();
const reset = () => { seen.length = 0; answer = () => Response.json({}); };
const request = (d: ReturnType<typeof db>, kind = "purchase", e164 = "+14155550123") =>
  run(d, "number_order_request", { kind, e164, reason: "New front desk line", confirm: CONFIRM_WORD[kind], key: KEY }) as Promise<{ order: Json }>;

Deno.test("every provider action needs a permission index.ts checks", () => {
  assertEquals(Object.keys(PROVIDER_PERMISSIONS).sort(), ["number_order_cancel", "number_order_decide", "number_order_request", "number_search", "provider_errors", "provider_overview"]);
  assertEquals(PROVIDER_PERMISSIONS.number_order_decide, "telephony.manage");
});

Deno.test("only https or this machine is used as a provider address; anything else falls back to the real one", () => {
  assertEquals(providerBase("http://127.0.0.1:54478/telnyx/", "https://x"), "http://127.0.0.1:54478/telnyx");
  assertEquals(providerBase("https://api.telnyx.com/v2", "https://x"), "https://api.telnyx.com/v2");
  assertEquals(providerBase("http://evil.example/v2", "https://x"), "https://x");
  assertEquals(providerBase("not a url", "https://x"), "https://x");
  assertEquals(providerBase(undefined, "https://x"), "https://x");
});

Deno.test("with a key unset, every order and search is refused as Not connected yet, and nothing is sent or recorded", async () => {
  for (const missing of ["TELNYX_API_KEY", "VAPI_API_KEY"]) {
    reset(); const d = db();
    const e = env({ [missing]: "" });
    for (const [action, fields] of [["number_order_request", { kind: "purchase", e164: "+14155550123", reason: "New line", confirm: "BUY", key: KEY }],
      ["number_search", { areaCode: "415" }], ["number_order_decide", { id: "o1", approve: true, reason: "ok", confirm: "+14155550123" }]] as [string, Json][]) {
      const err = await assertRejects(() => run(d, action, fields, "zella_owner", e), InputError);
      assertEquals([err.message, (err as InputError).status], [NOT_CONNECTED, 409]);
    }
    assertEquals(seen, []); assertEquals(d.calls, []);
    const o = await run(d, "provider_overview", {}, "zella_owner", e) as Json;
    assertEquals([o.connected, o.telnyx || o.vapi], [false, true]);
  }
});

Deno.test("with the keys set but number orders switched off, orders are refused and nothing is sent", async () => {
  reset(); const d = db({ enabled: false });
  const err = await assertRejects(() => request(d), InputError);
  assertEquals(err.message, ORDERS_OFF);
  assertEquals(seen, []); assertEquals(d.calls, []);
});

Deno.test("a request needs the typed confirmation and a key, checked on the server", async () => {
  reset(); const d = db();
  await assertRejects(() => run(d, "number_order_request", { kind: "purchase", e164: "+14155550123", reason: "New line", confirm: "buy", key: KEY }), InputError, "Type BUY");
  await assertRejects(() => run(d, "number_order_request", { kind: "release", e164: "+14155550123", reason: "Old line", confirm: "BUY", key: KEY }), InputError, "Type RELEASE");
  await assertRejects(() => run(d, "number_order_request", { kind: "purchase", e164: "+14155550123", reason: "New line", confirm: "BUY", key: "1" }), InputError);
  await assertRejects(() => run(d, "number_order_request", { kind: "steal", e164: "+14155550123", reason: "x", confirm: "BUY", key: KEY }), InputError);
  assertEquals(d.calls, []); assertEquals(seen, []);
  const { order } = await request(d);
  assertEquals(order.status, "requested");
  assertEquals(d.calls[0][1].p_actor, "admin-user");
  assertEquals(seen, [], "asking for a number never calls a provider");
});

Deno.test("only a Zella Voice owner can approve; other roles are refused before the database or a provider", async () => {
  for (const role of ["super_admin", "platform_operations", "read_only_admin", "support_admin", ""]) {
    reset(); const d = db(); await request(d); d.calls.length = 0;
    const err = await assertRejects(() => run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550123" }, role), InputError);
    assertEquals((err as InputError).status, 403);
    assertEquals(d.calls, []); assertEquals(seen, []);
  }
});

Deno.test("database refusals keep their meaning and status (the person who asked can't approve, wrong business)", async () => {
  for (const [code, status] of [["SECOND_PERSON_REQUIRED", 403], ["OWNER_REQUIRED", 403], ["NOT_ALLOWED", 403], ["BUSINESS_NOT_FOUND", 404], ["RELEASE_IN_USE", 409]] as const) {
    reset(); const d = db({ refuse: code });
    d.orders.set("o1", { id: "o1", kind: "purchase", e164: "+14155550123", status: "requested" });
    const err = await assertRejects(() => code === "BUSINESS_NOT_FOUND" || code === "RELEASE_IN_USE" ? request(d) : run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550123" }), InputError);
    assertEquals((err as InputError).status, status);
    assertEquals(seen, []);
  }
});

Deno.test("approval needs the number typed, then buys it once at Telnyx and adds it to Vapi", async () => {
  reset(); const d = db(); await request(d);
  await assertRejects(() => run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+1415" }), InputError, "Type +14155550123");
  assertEquals(seen, []);
  answer = (_m, p) => p === "/telnyx/number_orders" ? Response.json({ data: { id: "ord_1", status: "pending", phone_numbers: [{ id: "pn_1", phone_number: "+14155550123" }] } })
    : p === "/vapi/phone-number" ? Response.json({ id: "vapi_1" }) : new Response("no", { status: 404 });
  const { order } = await run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550123" }) as { order: Json };
  assertEquals([order.status, order.provider_order_id, order.provider_number_id, order.vapi_phone_number_id, order.error], ["completed", "ord_1", "pn_1", "vapi_1", null]);
  assertEquals(seen.map((s) => `${s.method} ${s.path}`), ["POST /telnyx/number_orders", "POST /vapi/phone-number"]);
  assertEquals([seen[0].auth, seen[1].auth], ["Bearer test-telnyx", "Bearer test-vapi"]);
  assertEquals(seen[0].body, { phone_numbers: [{ phone_number: "+14155550123" }], customer_reference: "zella-voice-o1" });
  assertEquals(seen[1].body, { provider: "telnyx", number: "+14155550123", credentialId: "cred_test", name: "Zella Voice +14155550123" });
  assertEquals(d.calls.map(([f]) => f), ["zella_number_order_request", "zella_number_order_decide", "zella_number_order_claim", "zella_number_order_finish"]);
  // a second approval (double click, retried request) never reaches the provider again
  seen.length = 0;
  await assertRejects(() => run(d, "number_order_decide", { id: "o1", approve: true, reason: "Again", confirm: "+14155550123" }), InputError);
  assertEquals(seen.filter((s) => s.method === "POST"), []);
});

Deno.test("Telnyx refusing the order is recorded as failed, and Vapi is never asked", async () => {
  reset(); const d = db(); await request(d);
  answer = () => Response.json({ errors: [{ title: "Number unavailable", detail: "The number is no longer available" }] }, { status: 422 });
  const { order } = await run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550123" }) as { order: Json };
  assertEquals(order.status, "failed");
  assert(String(order.error).includes("no longer available"));
  assertEquals(seen.map((s) => s.path), ["/telnyx/number_orders"]);
});

Deno.test("no answer from Telnyx is needs check, never a retry", async () => {
  reset(); const d = db(); await request(d);
  answer = () => new Promise((r) => setTimeout(() => r(Response.json({})), 400));
  const { order } = await run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550123" }, "zella_owner", env(), 100) as { order: Json };
  assertEquals(order.status, "needs_check");
  assert(String(order.error).includes("check the Telnyx and Vapi dashboards"));
  assertEquals(seen.length, 1);
  await new Promise((r) => setTimeout(r, 450));
});

Deno.test("bought at Telnyx but Vapi refuses: completed, with the Vapi step named", async () => {
  reset(); const d = db(); await request(d);
  answer = (_m, p) => p.startsWith("/telnyx") ? Response.json({ data: { id: "ord_2", status: "success", phone_numbers: [{ id: "pn_2" }] } }) : Response.json({ message: "credential not found" }, { status: 400 });
  const { order } = await run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550123" }) as { order: Json };
  assertEquals(order.status, "completed");
  assert(String(order.error).includes("adding it to Vapi failed"));
});

Deno.test("a release removes the number from Vapi, then releases it at Telnyx", async () => {
  reset(); const d = db();
  await run(d, "number_order_request", { kind: "release", e164: "+14155550199", reason: "Business closed", confirm: "RELEASE", key: KEY, vapiPhoneNumberId: "vapi_9" });
  answer = (m, p) => m === "DELETE" ? new Response(null, { status: 204 })
    : p.startsWith("/telnyx/phone_numbers?") ? Response.json({ data: [{ id: "tn_9", phone_number: "+14155550199" }] }) : new Response("no", { status: 404 });
  const { order } = await run(d, "number_order_decide", { id: "o1", approve: true, reason: "Approved", confirm: "+14155550199" }) as { order: Json };
  assertEquals([order.status, order.provider_number_id], ["completed", "tn_9"]);
  assertEquals(seen.map((s) => `${s.method} ${s.path}`), ["DELETE /vapi/phone-number/vapi_9", "GET /telnyx/phone_numbers?filter%5Bphone_number%5D=%2B14155550199", "DELETE /telnyx/phone_numbers/tn_9"]);
});

Deno.test("rejecting needs no keys and never calls a provider", async () => {
  reset(); const d = db(); await request(d);
  const { order } = await run(d, "number_order_decide", { id: "o1", approve: false, reason: "Not this month" }, "zella_owner", env({ TELNYX_API_KEY: "" })) as { order: Json };
  assertEquals(order.status, "rejected"); assertEquals(seen, []);
});

Deno.test("search lists only well formed US numbers from Telnyx", async () => {
  reset(); const d = db();
  await assertRejects(() => run(d, "number_search", { areaCode: "12" }), InputError);
  answer = () => Response.json({ data: [{ phone_number: "+14155550111", region_information: [{ region_name: "CA" }], cost_information: { monthly_cost: "1.00", currency: "USD" } }, { phone_number: "junk" }] });
  const r = await run(d, "number_search", { areaCode: "415" }) as { rows: Json[] };
  assertEquals(r.rows, [{ e164: "+14155550111", region: "CA", monthly: "1.00", upfront: null, currency: "USD" }]);
  assert(seen[0].path.includes("national_destination_code%5D=415"));
});

Deno.test("provider errors are read only, mask caller numbers and say when a provider isn't connected", async () => {
  reset(); const d = db();
  answer = (_m, p) => p.startsWith("/vapi/call") ? Response.json([{ id: "c1", endedReason: "pipeline-error-openai-llm-failed", endedAt: "2026-11-16T10:00:00Z", customer: { number: "+14155550177" } }, { id: "c2", endedReason: "customer-ended-call" }])
    : Response.json({ data: [{ id: "wd1", finished_at: "2026-11-16T09:00:00Z", webhook: { event_type: "message.finalized" }, errors: [{ title: "Timeout" }] }] });
  const r = await run(d, "provider_errors", {}, "platform_operations") as Record<string, Json>;
  assertEquals(r.vapi.rows, [{ at: "2026-11-16T10:00:00Z", code: "pipeline-error-openai-llm-failed", ref: "c1", number: "…0177" }]);
  assertEquals(r.telnyx.rows, [{ at: "2026-11-16T09:00:00Z", code: "message.finalized", detail: "Timeout", ref: "wd1" }]);
  assert(!JSON.stringify(r).includes("test-vapi") && !JSON.stringify(r).includes("+14155550177"));
  reset();
  const none = await run(d, "provider_errors", {}, "platform_operations", env({ TELNYX_API_KEY: "", VAPI_API_KEY: "" })) as Record<string, Json>;
  assertEquals([none.telnyx.connected, none.vapi.connected, seen.length], [false, false, 0]);
});

Deno.test("the overview never returns a key", async () => {
  reset(); const d = db();
  const o = await run(d, "provider_overview", {}, "read_only_admin");
  const s = JSON.stringify(o);
  assert(!s.includes("test-telnyx") && !s.includes("test-vapi") && !s.includes("cred_test"));
  assertEquals((o as Json).connected, true);
});

Deno.test({ name: "stop the fakes", fn: async () => { await fake.shutdown(); }, sanitizeOps: false, sanitizeResources: false });
