// continue-plan with the database mocked: the rate limits (SEC-12, conformance G-6) run per visitor address and per
// business before the business is read or changed, and a counter that can't be checked refuses.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handler } from "./index.ts";

const SECRET = "local-link-secret-test-only-0123456789abcdef";
for (const [k, v] of Object.entries({ SUPABASE_URL: "http://db.test", ZELLA_SERVER_SECRET_KEY: "server-key", ZELLA_LINK_SECRET: SECRET })) Deno.env.set(k, v);
const B = "c0000000-0000-0000-0000-000000000007", CANCEL_AT = "2026-12-31T00:00:00.000Z";

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
async function link(claims: unknown, secret = SECRET) {
  const payload = b64url(new TextEncoder().encode(JSON.stringify(claims)));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return `${payload}.${b64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload))))}`;
}

type Call = { url: string; method: string; body: string; auth: string };
const realFetch = globalThis.fetch;
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });
async function run(body: unknown, limiter: (key: string) => Response = () => json(true), headers: Record<string, string> = {}) {
  const calls: Call[] = [], keys: string[] = [];
  globalThis.fetch = (async (url: string | URL | Request, init: RequestInit = {}) => {
    const u = String(url instanceof Request ? url.url : url);
    const h = new Headers(init.headers ?? (url instanceof Request ? url.headers : undefined));
    const c = { url: u, method: init.method ?? (url instanceof Request ? url.method : "GET"), body: String(init.body ?? ""), auth: h.get("authorization") ?? "" };
    if (u.endsWith("/rpc/zella_rate_limit")) { const k = JSON.parse(c.body).p_key; keys.push(k); calls.push(c); return limiter(k); }
    calls.push(c);
    if (u.includes("/rest/v1/businesses")) return json(c.method === "PATCH" ? [{ id: B }] : { id: B, name: "Demo Salon", cancel_at: CANCEL_AT, cancelled_at: null });
    if (u.includes("/rest/v1/audit_logs")) return json(null, 201);
    return json({}, 500);
  }) as typeof fetch;
  try {
    const r = await handler(new Request("http://fn/continue-plan", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", ...headers } }));
    return { status: r.status, body: await r.json(), keys, calls, reads: calls.filter((c) => c.url.includes("/rest/v1/businesses")) };
  } finally { globalThis.fetch = realFetch; }
}

Deno.test("a valid link: counted per visitor and per business with the server key, then the plan is shown", async () => {
  const r = await run({ token: await link({ b: B, c: CANCEL_AT }), action: "preview" }, undefined, { "x-forwarded-for": "1.1.1.1, 203.0.113.7" });
  assertEquals([r.status, r.body.status, r.body.businessName], [200, "scheduled", "Demo Salon"]);
  assertEquals(r.keys, ["continue-plan:ip:203.0.113.7", `continue-plan:business:${B}`]);
  const limits = r.calls.filter((c) => c.url.endsWith("/rpc/zella_rate_limit"));
  assert(limits.every((c) => c.auth === "Bearer server-key"));
  assertEquals(limits.map((c) => [JSON.parse(c.body).p_max, JSON.parse(c.body).p_window_seconds]), [[30, 60], [10, 60]]);
  assert(r.calls.indexOf(limits[1]) < r.calls.indexOf(r.reads[0]));
});
Deno.test("continue still works under the limit", async () => {
  const r = await run({ token: await link({ b: B, c: CANCEL_AT }), action: "continue" });
  assertEquals([r.status, r.body.status], [200, "continued"]);
});
Deno.test("a visitor over the limit gets 429 with the app's wording; the link isn't checked and nothing is read", async () => {
  const r = await run({ token: await link({ b: B, c: CANCEL_AT }), action: "continue" }, () => json(false));
  assertEquals([r.status, r.body], [429, { error: "Too many attempts. Wait a minute and try again." }]);
  assertEquals([r.keys.length, r.reads.length], [1, 0]);
});
Deno.test("a business over the limit gets 429; nothing is read or changed", async () => {
  const r = await run({ token: await link({ b: B, c: CANCEL_AT }), action: "continue" }, (k) => json(!k.includes(":business:")));
  assertEquals([r.status, r.body.error, r.reads.length], [429, "Too many attempts. Wait a minute and try again.", 0]);
});
Deno.test("a forged link is counted per visitor only, never against the business it names", async () => {
  const r = await run({ token: await link({ b: B, c: CANCEL_AT }, "another-secret-that-is-not-the-link-secret"), action: "continue" });
  assertEquals([r.status, r.body.status, r.keys, r.reads.length], [200, "invalid", ["continue-plan:ip:unknown"], 0]);
});
Deno.test("a counter that can't be checked refuses (fails closed)", async () => {
  for (const limiter of [() => json({ message: "boom" }, 500), () => { throw new TypeError("network"); }]) {
    const r = await run({ token: await link({ b: B, c: CANCEL_AT }), action: "continue" }, limiter);
    assertEquals([r.status, r.reads.length], [503, 0]);
  }
});
