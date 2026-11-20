// reschedule-appointment with the database mocked: the rate limit counter fails closed (security audit M10) and the
// visitor address is the platform's, not the caller-written first X-Forwarded-For value.
import { assertEquals } from "jsr:@std/assert@1";
import { handler } from "./index.ts";

Deno.env.set("SUPABASE_URL", "http://db.test"); Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
const TOKEN = "a".repeat(64);
const realFetch = globalThis.fetch;
async function run(limit: (key: string) => Response, headers: Record<string, string> = {}) {
  const keys: string[] = []; let lookups = 0;
  globalThis.fetch = (async (url: string | URL | Request, init: RequestInit = {}) => {
    const u = String(url instanceof Request ? url.url : url);
    if (u.endsWith("/rpc/zella_rate_limit")) { const k = JSON.parse(String(init.body)).p_key; keys.push(k); return limit(k); }
    lookups++; return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  try {
    const r = await handler(new Request("http://fn/reschedule-appointment", { method: "POST", body: JSON.stringify({ token: TOKEN, action: "confirm", start: "2026-12-01T15:00:00Z" }), headers: { "content-type": "application/json", origin: "https://app.zellavoice.com", ...headers } }));
    return { status: r.status, keys, lookups };
  } finally { globalThis.fetch = realFetch; }
}
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });

Deno.test("a counter that can't be checked refuses instead of letting the request through", async () => {
  const r = await run(() => json({ message: "boom" }, 500));
  assertEquals([r.status, r.lookups], [503, 0]);
});
Deno.test("an over the limit visitor gets 429 and nothing runs", async () => {
  const r = await run(() => json(false));
  assertEquals([r.status, r.lookups], [429, 0]);
});
Deno.test("the visitor key is the platform address, whatever the caller writes first", async () => {
  const a = await run(() => json(true), { "x-forwarded-for": "1.1.1.1, 203.0.113.7" });
  const b = await run(() => json(true), { "x-forwarded-for": "9.9.9.9, 203.0.113.7" });
  assertEquals([a.status, a.keys[0], b.keys[0]], [200, "resched:ip:203.0.113.7", "resched:ip:203.0.113.7"]);
});
