// billing-webhook end to end with signed fixture events; the database is mocked (no network).
import { assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
Deno.env.set("STRIPE_WEBHOOK_SECRET", "test");
Deno.env.set("ZELLA_SERVER_SECRET_KEY", "test");
Deno.env.set("STRIPE_LIVEMODE", "false");
Deno.env.set("SUPABASE_URL", "http://db.test");
const enc = new TextEncoder();
async function signed(ev: unknown) {
  const raw = JSON.stringify(ev), t = Math.floor(Date.now() / 1000);
  const key = await crypto.subtle.importKey("raw", enc.encode("test"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${raw}`)))].map((x) => x.toString(16).padStart(2, "0")).join("");
  return new Request("http://fn", { method: "POST", headers: { "stripe-signature": `t=${t},v1=${mac}` }, body: raw });
}
async function run(ev: unknown, answer = '"processed"') {
  const sent: Record<string, unknown>[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((_u: string, init: RequestInit) => { sent.push(JSON.parse(String(init.body))); return Promise.resolve(new Response(answer)); }) as typeof fetch;
  try { const r = await handle(await signed(ev)); return { status: r.status, text: await r.text(), sent }; } finally { globalThis.fetch = real; }
}
const PAID = { id: "in_1", status: "paid", paid: true, amount_paid: 4900, amount_due: 4900, amount_remaining: 0, currency: "usd", payment_intent: "pi_1", subscription: "sub_1" };

Deno.test("body limit uses bytes and cancels oversized streams", async () => {
  let cancelled = false;
  const body = new ReadableStream({ pull(c) { c.enqueue(new TextEncoder().encode("é".repeat(250001))); }, cancel() { cancelled = true; } });
  const r = await handle(new Request("http://fn", { method: "POST", body }));
  assertEquals(r.status, 413);
  assertEquals(cancelled, true);
  assertEquals((await handle(new Request("http://fn", { method: "POST", headers: { "content-length": "500001" }, body: "x" }))).status, 413);
});
Deno.test("not configured until the mode is set", async () => {
  Deno.env.delete("STRIPE_LIVEMODE");
  try { assertEquals((await handle(await signed({ id: "e", type: "invoice.paid" }))).status, 503); } finally { Deno.env.set("STRIPE_LIVEMODE", "false"); }
});
Deno.test("a signed paid invoice reaches the database as the grant", async () => {
  const r = await run({ id: "evt_paid", type: "invoice.paid", livemode: false, created: 1_800_000_000, data: { object: PAID } });
  assertEquals([r.status, r.sent[0].p_type, r.sent[0].p_event_id, r.sent[0].p_amount_minor], [200, "payment_succeeded", "evt_paid", 4900]);
});
Deno.test("a signed active status update reaches nothing", async () => {
  const r = await run({ id: "evt_u", type: "customer.subscription.updated", livemode: false, data: { object: { id: "sub_1", status: "active", current_period_end: 2 } } });
  assertEquals([r.status, r.text, r.sent.length], [200, "ignored", 0]);
});
Deno.test("a signed live mode event on the test endpoint is quarantined (stored, never applied) and answered 200, not 422", async () => {
  const r = await run({ id: "evt_live", type: "invoice.paid", livemode: true, data: { object: PAID } }, '"pending"');
  assertEquals([r.status, r.sent[0].p_type, String(r.sent[0].p_reason).includes("livemode")], [200, "quarantined", true]);
  assertEquals(r.sent[0].p_external_subscription_id, undefined);
});
Deno.test("a signed event with missing fields is quarantined, not 422", async () => {
  const r = await run({ id: "evt_bad", type: "charge.refunded", livemode: false, data: { object: {} } }, '"pending"');
  assertEquals([r.status, r.sent[0].p_type], [200, "quarantined"]);
});
Deno.test("unknown event types are 200 and never reach the database", async () => {
  const r = await run({ id: "evt_x", type: "customer.created", livemode: false, data: { object: {} } });
  assertEquals([r.status, r.sent.length], [200, 0]);
});
Deno.test("database answers map to the provider's retry", async () => {
  for (const [answer, status] of [['"processed"', 200], ['"private failure"', 500], ['{}', 500], ['{', 500]] as const) {
    const r = await run({ id: "evt", type: "customer.subscription.deleted", livemode: false, data: { object: { id: "sub" } } }, answer);
    assertEquals([r.status, r.text], [status, status === 200 ? "ok" : "error"]);
  }
});
