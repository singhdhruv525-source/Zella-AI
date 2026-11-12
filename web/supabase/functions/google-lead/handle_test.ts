// Unit tests for the Google Ads lead webhook: every answer Google can get, with the database call mocked.
import { assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";

Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key");
const realFetch = globalThis.fetch;
function withDb(reply: { status?: number; body?: unknown }, fn: (calls: { url: string; init: RequestInit }[]) => Promise<void>) {
  return async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    globalThis.fetch = ((url: string, init: RequestInit) => {
      calls.push({ url, init });
      return Promise.resolve(new Response(JSON.stringify(reply.body ?? {}), { status: reply.status ?? 200 }));
    }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; }
  };
}
const post = (body: string) => handle(new Request("http://fn/google-lead", { method: "POST", body, headers: { "content-type": "application/json" } }));
const lead = JSON.stringify({ google_key: "zg_x", lead_id: "L1", user_column_data: [{ column_id: "PHONE_NUMBER", string_value: "+15125550100" }] });

Deno.test("stored lead: 200, the database is called with the whole payload as the service", withDb({ body: { ok: true, customer_id: "c1", submission_id: "s1" } }, async (calls) => {
  const r = await post(lead);
  assertEquals(r.status, 200);
  assertEquals(await r.json(), { ok: true }); // no customer data echoed back
  assertEquals(calls[0].url, "http://db.test/rest/v1/rpc/zella_capture_google_lead");
  assertEquals(JSON.parse(String(calls[0].init.body)).p_payload.lead_id, "L1");
  assertEquals((calls[0].init.headers as Record<string, string>).apikey, "server-key");
}));
Deno.test("Google's retry of the same lead: 200 duplicate", withDb({ body: { ok: true, duplicate: true } }, async () => {
  const r = await post(lead); assertEquals(r.status, 200); assertEquals((await r.json()).duplicate, true);
}));
Deno.test("Google's test data: 200 test", withDb({ body: { ok: true, test: true } }, async () => {
  const r = await post(lead); assertEquals(r.status, 200); assertEquals((await r.json()).test, true);
}));
Deno.test("wrong or revoked key: 401", withDb({ body: { ok: false, error: "bad_key" } }, async () => assertEquals((await post(lead)).status, 401)));
Deno.test("too many: 429", withDb({ body: { ok: false, error: "too_many_requests" } }, async () => assertEquals((await post(lead)).status, 429)));
Deno.test("not a lead: 400", withDb({ body: { ok: false, error: "bad_payload" } }, async () => assertEquals((await post(lead)).status, 400)));
Deno.test("suspended or cancelled business: 410 (Google stops retrying)", withDb({ body: { ok: false, error: "business_unavailable" } }, async () => assertEquals((await post(lead)).status, 410)));
Deno.test("database failure: 503 so Google retries", withDb({ body: { ok: false, error: "try_again" } }, async () => assertEquals((await post(lead)).status, 503)));
Deno.test("database unreachable: 503", withDb({ status: 500, body: {} }, async () => assertEquals((await post(lead)).status, 503)));
Deno.test("not JSON or not an object: 400, database never called", withDb({}, async (calls) => {
  assertEquals((await post("nope")).status, 400); assertEquals((await post("[1]")).status, 400); assertEquals(calls.length, 0);
}));
Deno.test("too large: 413", withDb({}, async (calls) => { assertEquals((await post("x".repeat(50001))).status, 413); assertEquals(calls.length, 0); }));
Deno.test("not a POST: 405", withDb({}, async () => assertEquals((await handle(new Request("http://fn/google-lead"))).status, 405)));
Deno.test("server key missing: 503", withDb({}, async (calls) => {
  Deno.env.delete("ZELLA_SERVER_SECRET_KEY");
  try { assertEquals((await post(lead)).status, 503); assertEquals(calls.length, 0); } finally { Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key"); }
}));
Deno.test("database call times out or throws: 503 so Google retries, and the call carries a time limit (BE-3)", async () => {
  let signal: AbortSignal | undefined;
  globalThis.fetch = ((_url: string, init: RequestInit) => { signal = init.signal ?? undefined; return Promise.reject(new DOMException("timed out", "TimeoutError")); }) as typeof fetch;
  try {
    const r = await post(lead);
    assertEquals(r.status, 503);
    assertEquals(await r.json(), { ok: false, error: "try_again" });
    assertEquals(signal instanceof AbortSignal, true);
  } finally { globalThis.fetch = realFetch; }
});
