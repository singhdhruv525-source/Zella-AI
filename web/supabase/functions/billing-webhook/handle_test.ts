// deno test --no-lock --allow-env web/supabase/functions/billing-webhook/handle_test.ts   (no network: the database call is stubbed)
import { assertEquals } from "jsr:@std/assert@1";
import { handle, httpStatusFor } from "./index.ts";
import { signStripePayload } from "../_shared/stripe.ts";

const SECRET = "whsec_test_only";
const env = { STRIPE_WEBHOOK_SECRET: SECRET, STRIPE_SECRET_KEY: "sk_test_unit", ZELLA_SERVER_SECRET_KEY: "server_unit", SUPABASE_URL: "http://127.0.0.1:9" };
for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
const event = (o: Record<string, unknown> = {}) => JSON.stringify({ id: "evt_1", type: "invoice.paid", livemode: false, created: 1, data: { object: { id: "in_1", object: "invoice" } }, ...o });

let calls: { url: string; body: Record<string, unknown> }[] = [];
let answer = '"stored"';
const real = globalThis.fetch;
globalThis.fetch = ((url: string, init: RequestInit) => { calls.push({ url, body: JSON.parse(String(init.body)) }); return Promise.resolve(new Response(answer)); }) as typeof fetch;
const post = async (raw: string, sig: string | null) => {
  const r = await handle(new Request("http://fn", { method: "POST", headers: sig ? { "stripe-signature": sig } : {}, body: raw }));
  return r.status;
};

Deno.test("off until both secrets are set", async () => {
  Deno.env.delete("STRIPE_WEBHOOK_SECRET");
  assertEquals(await post(event(), await signStripePayload(event(), SECRET)), 503);
  Deno.env.set("STRIPE_WEBHOOK_SECRET", SECRET);
  Deno.env.delete("STRIPE_SECRET_KEY");
  assertEquals(await post(event(), await signStripePayload(event(), SECRET)), 503);
  Deno.env.set("STRIPE_SECRET_KEY", env.STRIPE_SECRET_KEY);
  assertEquals((await handle(new Request("http://fn"))).status, 405);
});

Deno.test("signature: valid stored; tampered, wrong secret, old and missing refused before the database", async () => {
  calls = []; answer = '"stored"';
  const raw = event();
  assertEquals(await post(raw, await signStripePayload(raw, SECRET)), 200);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "http://127.0.0.1:9/rest/v1/rpc/zella_stripe_event_store");
  assertEquals(calls[0].body.p_key_livemode, false);
  calls = [];
  assertEquals(await post(raw.replace("in_1", "in_2"), await signStripePayload(raw, SECRET)), 400);
  assertEquals(await post(raw, await signStripePayload(raw, "whsec_other")), 400);
  assertEquals(await post(raw, await signStripePayload(raw, SECRET, Math.floor(Date.now() / 1000) - 301)), 400);   // a replay of an old delivery
  assertEquals(await post(raw, null), 400);
  assertEquals(calls.length, 0);
});

Deno.test("rotation: the previous secret is accepted only while it is set", async () => {
  const raw = event();
  const old = await signStripePayload(raw, "whsec_previous");
  assertEquals(await post(raw, old), 400);
  Deno.env.set("STRIPE_WEBHOOK_SECRET_PREVIOUS", "whsec_previous");
  assertEquals(await post(raw, old), 200);
  Deno.env.delete("STRIPE_WEBHOOK_SECRET_PREVIOUS");
});

Deno.test("live key: the event is checked against live mode", async () => {
  calls = [];
  Deno.env.set("STRIPE_SECRET_KEY", "rk_live_unit");
  const raw = event({ livemode: true });
  assertEquals(await post(raw, await signStripePayload(raw, SECRET)), 200);
  assertEquals(calls[0].body.p_key_livemode, true);
  Deno.env.set("STRIPE_SECRET_KEY", env.STRIPE_SECRET_KEY);
});

Deno.test("database answers map to Stripe's retries: duplicate and ignored are 200, mode mismatch 400, errors 500", async () => {
  const raw = event();
  for (const [a, s] of [['"duplicate"', 200], ['"ignored"', 200], ['"mode_mismatch"', 400], ['"bad_event"', 400], ['"weird"', 500], ["{", 500]] as const) {
    answer = a;
    assertEquals(await post(raw, await signStripePayload(raw, SECRET)), s, a);
  }
  answer = '"stored"';
  assertEquals([httpStatusFor("stored"), httpStatusFor(null)], [200, 500]);
});

Deno.test("body limit counts bytes and cancels the stream; bad json and bad utf8 refused", async () => {
  let cancelled = false;
  const body = new ReadableStream({ pull(c) { c.enqueue(new TextEncoder().encode("é".repeat(250001))); }, cancel() { cancelled = true; } });
  assertEquals((await handle(new Request("http://fn", { method: "POST", body }))).status, 413);
  assertEquals(cancelled, true);
  assertEquals((await handle(new Request("http://fn", { method: "POST", headers: { "content-length": "500001" }, body: "x" }))).status, 413);
  assertEquals(await post("{bad", await signStripePayload("{bad", SECRET)), 400);
  const bytes = new Uint8Array([0xff, 0xfe]);
  assertEquals((await handle(new Request("http://fn", { method: "POST", body: bytes }))).status, 400);
});

Deno.test("cleanup", () => { globalThis.fetch = real; });
