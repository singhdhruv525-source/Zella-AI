// store-connect with Supabase and Shopify mocked.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
for (const [k, v] of Object.entries({ SUPABASE_URL: "http://db.test", ZELLA_SERVER_SECRET_KEY: "server-key", SUPABASE_ANON_KEY: "anon-key" })) Deno.env.set(k, v);
const B = "c0000000-0000-0000-0000-000000000006", U = "a0000000-0000-0000-0000-000000000002", TOKEN = "test_store_token_not_real_0001";
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
const realFetch = globalThis.fetch;
// the shared rate limit counter (zella_rate_limit) allows every request unless a test passes its own answer
function mock(route: (c: Call) => Response, fn: (calls: Call[]) => Promise<void>, limiter: (c: Call) => Response = () => j(true)) {
  return async () => {
    const calls: Call[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit = {}) => { const c = { url: String(url), method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: String(init.body ?? "") }; calls.push(c); return c.url.endsWith("/rpc/zella_rate_limit") ? limiter(c) : route(c); }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; }
  };
}
const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s });
const connect = (body: Record<string, unknown> = {}, auth = "Bearer owner-jwt") => handle(new Request("http://fn/store-connect", { method: "POST",
  body: JSON.stringify({ action: "connect", business_id: B, shop_domain: "Demo-Store.myshopify.com", access_token: TOKEN, ...body }), headers: { "content-type": "application/json", authorization: auth } }));
const shopify = (scopes: string[], shopStatus = 200) => (c: Call) =>
  c.url.endsWith("/auth/v1/user") ? j({ id: U }) : c.url.endsWith("zella_store_can_manage") ? j(true)
  : c.url.includes("/shop.json") ? j({ shop: { name: "Demo Store" } }, shopStatus) : c.url.endsWith("access_scopes.json") ? j({ access_scopes: scopes.map((handle) => ({ handle })) })
  : c.url.endsWith("zella_store_connect") ? j("integration-id") : j({}, 500);

Deno.test("an owner connects a store: Shopify checks the token and scopes, the database stores it", mock(shopify(["read_orders", "read_customers", "read_fulfillments"]), async (calls) => {
  const r = await connect();
  assertEquals(r.status, 200);
  const body = await r.json();
  assertEquals([body.ok, body.shop, body.shop_name], [true, "demo-store.myshopify.com", "Demo Store"]);
  assert(!JSON.stringify(body).includes(TOKEN));
  assertEquals(calls.find((c) => c.url.includes("/shop.json"))!.url, "https://demo-store.myshopify.com/admin/api/2026-07/shop.json");
  const saved = calls.find((c) => c.url.endsWith("zella_store_connect"))!;
  assertEquals(saved.headers.Authorization, "Bearer server-key");
  assertEquals(JSON.parse(saved.body).p_actor, U);
}));
Deno.test("a token with write access works, and the owner is told it has more than needed", mock(shopify(["write_orders", "write_customers"]), async () => {
  assertEquals((await (await connect()).json()).more_access_than_needed, ["write_orders", "write_customers"]);
}));
Deno.test("missing scopes: refused with which ones, nothing stored", mock(shopify(["read_products"]), async (calls) => {
  const r = await connect();
  assertEquals([r.status, (await r.json()).missing], [400, ["read_orders", "read_customers"]]);
  assertEquals(calls.some((c) => c.url.endsWith("zella_store_connect")), false);
}));
Deno.test("Shopify refuses the token: refused, nothing stored", mock(shopify([], 401), async (calls) => {
  const r = await connect();
  assertEquals([r.status, (await r.json()).error], [400, "token_refused"]);
  assertEquals(calls.some((c) => c.url.endsWith("zella_store_connect")), false);
}));
Deno.test("staff (database says no) are refused before Shopify is called", mock((c) => c.url.endsWith("/auth/v1/user") ? j({ id: U }) : j(false), async (calls) => {
  assertEquals((await connect()).status, 403);
  assertEquals(calls.some((c) => c.url.includes("myshopify")), false);
}));
Deno.test("only *.myshopify.com addresses (no requests to arbitrary hosts) and token-shaped tokens", mock(() => j({}), async (calls) => {
  for (const shop_domain of ["evil.example.com", "localhost", "169.254.169.254", "x.myshopify.com.evil.test", "a b.myshopify.com"]) assertEquals((await connect({ shop_domain })).status, 400, shop_domain);
  assertEquals((await connect({ access_token: "short" })).status, 400);
  assertEquals(calls.length, 0);
}));
Deno.test("not signed in, or the server key as a user", mock(() => j({}), async (calls) => {
  assertEquals((await connect({}, "")).status, 401);
  assertEquals((await connect({}, "Bearer server-key")).status, 401);
  assertEquals(calls.length, 0);
}));
Deno.test("store unreachable: 502, nothing stored", mock((c) => c.url.includes("myshopify") ? (() => { throw new TypeError("network"); })() : shopify([])(c), async (calls) => {
  assertEquals((await connect()).status, 502);
  assertEquals(calls.some((c) => c.url.endsWith("zella_store_connect")), false);
}));

// a save error whose body cannot be read (stalled, then aborted by the deadline) answers "try again", never throws
const brokenBody = () => new Response(new ReadableStream({ pull(ctl) { ctl.error(new DOMException("The signal has been aborted", "AbortError")); } }), { status: 500 });
Deno.test("the save fails and its error body cannot be read: try again, no crash", mock((c) =>
  c.url.endsWith("zella_store_connect") ? brokenBody() : shopify(["read_orders", "read_customers", "read_fulfillments"])(c), async () => {
  const r = await connect();
  assertEquals(r.status, 400);
  assertEquals((await r.json()).error, "try_again");
}));

// Rate limits (SEC-12, conformance G-6): per person, then per business, before Shopify is asked or anything is stored
const limitKeys = (calls: Call[]) => calls.filter((c) => c.url.endsWith("/rpc/zella_rate_limit")).map((c) => JSON.parse(c.body));
Deno.test("rate limits: counted per person and per business with the server key, before Shopify", mock(shopify(["read_orders", "read_customers"]), async (calls) => {
  assertEquals((await connect()).status, 200);
  assertEquals(limitKeys(calls), [{ p_key: `store-connect:user:${U}`, p_max: 10, p_window_seconds: 60 }, { p_key: `store-connect:business:${B}`, p_max: 20, p_window_seconds: 60 }]);
  const limits = calls.filter((c) => c.url.endsWith("/rpc/zella_rate_limit"));
  assert(limits.every((c) => c.headers.Authorization === "Bearer server-key"));
  assert(calls.lastIndexOf(limits[1]) < calls.findIndex((c) => c.url.includes("myshopify")));
}));
Deno.test("rate limits: a person over the limit gets 429 with the app's wording; nothing else runs", mock(shopify(["read_orders", "read_customers"]), async (calls) => {
  const r = await connect();
  assertEquals([r.status, await r.json()], [429, { ok: false, error: "rate_limited", message: "Too many attempts. Wait a minute and try again." }]);
  assertEquals(calls.some((c) => c.url.endsWith("zella_store_can_manage") || c.url.includes("myshopify") || c.url.endsWith("zella_store_connect")), false);
}, () => j(false)));
Deno.test("rate limits: a business over the limit gets 429; Shopify isn't asked, nothing stored", mock(shopify(["read_orders", "read_customers"]), async (calls) => {
  assertEquals((await connect()).status, 429);
  assertEquals(calls.some((c) => c.url.includes("myshopify") || c.url.endsWith("zella_store_connect")), false);
}, (c) => j(!JSON.parse(c.body).p_key.includes(":business:"))));
Deno.test("rate limits: a counter that can't be checked refuses (fails closed)", mock(shopify(["read_orders", "read_customers"]), async (calls) => {
  const r = await connect();
  assertEquals([r.status, (await r.json()).error], [503, "try_again"]);
  assertEquals(calls.some((c) => c.url.includes("myshopify") || c.url.endsWith("zella_store_connect")), false);
}, () => j({ message: "boom" }, 500)));
Deno.test("rate limits: someone who can't manage the business doesn't use up its allowance", mock((c) => c.url.endsWith("/auth/v1/user") ? j({ id: U }) : j(false), async (calls) => {
  assertEquals((await connect()).status, 403);
  assertEquals(limitKeys(calls).map((k) => k.p_key), [`store-connect:user:${U}`]);
}));
