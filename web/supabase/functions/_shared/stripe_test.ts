// deno test --no-lock --allow-net=127.0.0.1 web/supabase/functions/_shared/stripe_test.ts
// Local only: the client runs against tests/stripe_fake (127.0.0.1), and a guard fails the test if anything tries to
// reach a host other than 127.0.0.1.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  formEncode, invoicePaymentIntent, invoiceSubscription, keyIsLive, linePrice, signStripePayload, STRIPE_API_VERSION,
  StripeError, stripeClient, subscriptionPeriod, verifyStripeSignature,
} from "./stripe.ts";
import { startFakeStripe } from "../../../../tests/stripe_fake/fake_stripe.ts";

const realFetch = globalThis.fetch;
globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
  const u = new URL(input instanceof Request ? input.url : String(input));
  if (u.hostname !== "127.0.0.1") throw new Error(`test tried to reach ${u.hostname}`);
  return realFetch(input, init);
}) as typeof fetch;

Deno.test("form encoding matches Stripe's nested style", () => {
  const f = formEncode({ mode: "subscription", line_items: [{ price: "price_1", quantity: 1 }], metadata: { business_id: "b1" }, skip: null, on: true });
  assertEquals(f.toString(), "mode=subscription&line_items%5B0%5D%5Bprice%5D=price_1&line_items%5B0%5D%5Bquantity%5D=1&metadata%5Bbusiness_id%5D=b1&on=true");
});

Deno.test("live mode comes from the key prefix only", () => {
  assertEquals(keyIsLive("sk_live_x"), true);
  assertEquals(keyIsLive("rk_live_x"), true);
  assertEquals(keyIsLive("sk_test_x"), false);
  assertEquals(keyIsLive("rk_test_x"), false);
  assertEquals(keyIsLive("whatever"), false);
});

Deno.test("every POST needs an idempotency key; headers pin the version", async () => {
  let seen: Headers | null = null;
  const c = stripeClient({ secretKey: "sk_test_unit", baseUrl: "http://127.0.0.1:1", fetchImpl: ((_u: string, i: RequestInit) => { seen = new Headers(i.headers); return Promise.resolve(Response.json({ id: "cus_1" })); }) as typeof fetch });
  await assertRejects(() => c.post("/v1/customers", {}, ""), Error, "Idempotency-Key");
  await assertRejects(() => c.post("/v1/customers", {}, "x".repeat(256)), Error, "Idempotency-Key");
  await assertRejects(() => c.get("/customers"), Error, "/v1/");
  await c.post("/v1/customers", {}, "customer:b1");
  assertEquals(seen!.get("stripe-version"), STRIPE_API_VERSION);
  assertEquals(seen!.get("idempotency-key"), "customer:b1");
  assertEquals(seen!.get("authorization"), "Bearer sk_test_unit");
});

Deno.test("errors are classified: retry only 429, 5xx and network; idempotency errors held", async () => {
  const answer = (status: number, body: unknown) => stripeClient({ secretKey: "sk_test_unit", baseUrl: "http://127.0.0.1:1", fetchImpl: (() => Promise.resolve(Response.json(body, { status }))) as unknown as typeof fetch });
  const e429 = await assertRejects(() => answer(429, { error: { type: "rate_limit_error" } }).get("/v1/customers/c"), StripeError);
  assertEquals(e429.retryable, true);
  const e500 = await assertRejects(() => answer(500, { error: { type: "api_error" } }).get("/v1/customers/c"), StripeError);
  assertEquals(e500.retryable, true);
  const e402 = await assertRejects(() => answer(402, { error: { type: "card_error", code: "authentication_required", payment_intent: { id: "pi_9" } } }).post("/v1/payment_intents", {}, "k1"), StripeError);
  assertEquals([e402.retryable, e402.code, e402.paymentIntent], [false, "authentication_required", "pi_9"]);
  const eid = await assertRejects(() => answer(400, { error: { type: "idempotency_error" } }).post("/v1/refunds", {}, "k2"), StripeError);
  assertEquals([eid.retryable, eid.idempotencyConflict], [false, true]);
  // the first request with this key is still running at Stripe: wait and send the same key again, never held
  const inUse = await assertRejects(() => answer(409, { error: { type: "idempotency_error", code: "idempotency_key_in_use" } }).post("/v1/refunds", {}, "k3"), StripeError);
  assertEquals([inUse.retryable, inUse.idempotencyConflict], [true, false]);
  const down = stripeClient({ secretKey: "sk_test_unit", baseUrl: "http://127.0.0.1:1", fetchImpl: (() => Promise.reject(new TypeError("refused"))) as typeof fetch });
  const en = await assertRejects(() => down.get("/v1/customers/c"), StripeError);
  assertEquals([en.status, en.retryable], [0, true]);
  const timeout = stripeClient({ secretKey: "sk_test_unit", baseUrl: "http://127.0.0.1:1", timeoutMs: 20, fetchImpl: ((_u: string, i: RequestInit) => new Promise((_r, rej) => i.signal!.addEventListener("abort", () => rej(i.signal!.reason)))) as typeof fetch });
  const et = await assertRejects(() => timeout.get("/v1/customers/c"), StripeError);
  assertEquals([et.message, et.retryable], ["Stripe timed out", true]);
});

Deno.test("signature: valid, tampered, wrong secret, old, future, replayed header, rotation", async () => {
  const now = 1_800_000_000, raw = '{"id":"evt_1","type":"invoice.paid"}';
  const good = await signStripePayload(raw, "whsec_a", now);
  assertEquals(await verifyStripeSignature(raw, good, ["whsec_a"], now), now);
  assertEquals(await verifyStripeSignature(raw + " ", good, ["whsec_a"], now), null);                  // tampered body
  assertEquals(await verifyStripeSignature(raw.replace("paid", "void"), good, ["whsec_a"], now), null);
  assertEquals(await verifyStripeSignature(raw, good, ["whsec_b"], now), null);                        // wrong secret
  assertEquals(await verifyStripeSignature(raw, good, ["whsec_a"], now + 301), null);                  // old: replayed later
  assertEquals(await verifyStripeSignature(raw, await signStripePayload(raw, "whsec_a", now + 301), ["whsec_a"], now), null);
  assertEquals(await verifyStripeSignature(raw, good, ["whsec_a"], now + 300), now);                   // inside the window
  assertEquals(await verifyStripeSignature(raw, null, ["whsec_a"], now), null);
  assertEquals(await verifyStripeSignature(raw, "v1=" + good.split("v1=")[1], ["whsec_a"], now), null);  // no t
  assertEquals(await verifyStripeSignature(raw, `t=${now},t=${now},v1=${good.split("v1=")[1]}`, ["whsec_a"], now), null);
  assertEquals(await verifyStripeSignature(raw, `t=${now},v0=${good.split("v1=")[1]}`, ["whsec_a"], now), null);   // v0 never trusted
  // several v1 entries, and two secrets during a planned rotation
  assertEquals(await verifyStripeSignature(raw, `t=${now},v1=deadbeef,v1=${good.split("v1=")[1]}`, ["whsec_a"], now), now);
  assertEquals(await verifyStripeSignature(raw, good, ["whsec_old", "whsec_a"], now), now);
  assertEquals(await verifyStripeSignature(raw, good, ["", "whsec_old"], now), null);
});

Deno.test("field access works on the pinned and the older invoice shape", () => {
  assertEquals(invoiceSubscription({ parent: { subscription_details: { subscription: "sub_new" } } }), "sub_new");
  assertEquals(invoiceSubscription({ subscription: { id: "sub_old" } }), "sub_old");
  assertEquals(invoicePaymentIntent({ payments: { data: [{ status: "open", payment: { payment_intent: "pi_a" } }, { status: "paid", payment: { payment_intent: "pi_b" } }] } }), "pi_b");
  assertEquals(invoicePaymentIntent({ payment_intent: "pi_old" }), "pi_old");
  assertEquals(linePrice({ pricing: { price_details: { price: "price_new" } } }), "price_new");
  assertEquals(linePrice({ price: { id: "price_old" } }), "price_old");
  assertEquals(subscriptionPeriod({ items: { data: [{ current_period_start: 1, current_period_end: 2 }] } }), { start: 1, end: 2 });
  assertEquals(subscriptionPeriod({ current_period_start: 3, current_period_end: 4, items: { data: [] } }), { start: 3, end: 4 });
});

Deno.test("against the local fake: idempotent replay, conflict, checkout events, refund cap", async () => {
  const fake = startFakeStripe();
  try {
    const c = stripeClient({ secretKey: "sk_test_fake", baseUrl: fake.url });
    assertEquals(c.livemode, false);
    const cus = await c.post("/v1/customers", { metadata: { business_id: "b1" } }, "customer:b1");
    assertEquals((await c.post("/v1/customers", { metadata: { business_id: "b1" } }, "customer:b1")).id, cus.id);   // same key, same body
    const conflict = await assertRejects(() => c.post("/v1/customers", { metadata: { business_id: "b2" } }, "customer:b1"), StripeError);
    assertEquals(conflict.idempotencyConflict, true);
    const prod = await c.post("/v1/products", { name: "Zella Voice plan" }, "product:b1");
    const price = await c.post("/v1/prices", { product: prod.id, unit_amount: 29900, currency: "usd", recurring: { interval: "month" } }, "price:v1");
    const fee = await c.post("/v1/prices", { product: prod.id, unit_amount: 59900, currency: "usd" }, "price:v1:setup");
    const cs = await c.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, line_items: [{ price: price.id, quantity: 1 }, { price: fee.id, quantity: 1 }], metadata: { outbox_id: "o1" } }, "checkout:o1");
    assertEquals(cs.amount_total, 89800);
    fake.completeCheckout(cs.id);
    const types = fake.events.map((e) => e.type);
    for (const t of ["customer.subscription.created", "invoice.finalized", "invoice.paid", "payment_intent.succeeded", "checkout.session.completed"]) assert(types.includes(t), t);
    const paid = fake.events.find((e) => e.type === "invoice.paid")!.data.object;
    assertEquals([paid.amount_paid, paid.billing_reason, invoiceSubscription(paid) !== null], [89800, "subscription_create", true]);
    const pi = invoicePaymentIntent(paid)!;
    const big = await assertRejects(() => c.post("/v1/refunds", { payment_intent: pi, amount: 89801 }, "refund:r1"), StripeError);
    assertEquals(big.code, "amount_too_large");
    assertEquals((await c.post("/v1/refunds", { payment_intent: pi, amount: 29900 }, "refund:r2")).status, "succeeded");
    assert(fake.requests.every((r) => r.version === STRIPE_API_VERSION));
    const live = stripeClient({ secretKey: "sk_live_never_used_here", baseUrl: fake.url });
    assertEquals((await assertRejects(() => live.get(`/v1/customers/${cus.id}`), StripeError)).status, 401);   // the fake refuses live keys
  } finally { await fake.stop(); }
});
