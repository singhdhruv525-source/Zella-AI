// billing-api, checkout_start and checkout_return for Stripe Embedded Checkout (owner, 27 Nov 2026), locally: the
// database answers come from a stand in (the owner function's own checks are proven in tests/stripe_checkout), and
// Stripe is the in-memory fake (tests/stripe_fake). Nothing reaches Supabase or Stripe.
// Run: deno test --no-lock --allow-net=127.0.0.1 --allow-env web/supabase/functions/billing-api/handle_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../../../../tests/stripe_fake/fake_stripe.ts";
import { stripeClient } from "../_shared/stripe.ts";

const BACKEND = "http://supabase.test.local";
const BIZ = "11111111-1111-4111-8111-111111111111", CHECKOUT = "22222222-2222-4222-8222-222222222222";
const fake = startFakeStripe();
const stripe = stripeClient({ secretKey: "sk_test_handle", baseUrl: fake.url });
const env = { SUPABASE_URL: BACKEND, SUPABASE_ANON_KEY: "anon-test", ZELLA_SERVER_SECRET_KEY: "server-test", STRIPE_SECRET_KEY: "sk_test_handle",
  STRIPE_API_BASE: fake.url, STRIPE_PUBLISHABLE_KEY: "pk_test_handle0001" };
for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
const { handle } = await import("./index.ts");

// the database stand in: what the owner functions and the server functions answer
type Db = { checkout: Record<string, unknown> | null; payment: Record<string, unknown>; start?: Record<string, unknown> | Error };
let db: Db;
const calls: { fn: string; args: Record<string, unknown>; as: string }[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: Request | URL | string, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.startsWith(BACKEND)) return realFetch(input, init);
  const fn = url.split("/rpc/")[1];
  const args = JSON.parse(String(init?.body ?? "{}"));
  const auth = new Headers(init?.headers).get("authorization") ?? "";
  calls.push({ fn, args, as: auth.endsWith("server-test") ? "server" : "owner" });
  const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { "Content-Type": "application/json" } });
  if (fn === "zella_owner_billing_checkout_start") return db.start instanceof Error ? json({ message: db.start.message }, 400) : json(db.start ?? { checkout_id: CHECKOUT, status: db.checkout?.status });
  if (fn === "zella_billing_checkout_session") return json(db.checkout);
  if (fn === "zella_owner_onboarding_payment_status") return json(db.payment);
  if (fn === "zella_billing_events_claim" || fn.startsWith("zella_billing_")) return json(null);
  if (fn === "zella_platform_alert") return json(null);
  return json(null);
};

async function newSession(extra: Record<string, unknown> = {}) {
  const cus = await stripe.post("/v1/customers", { metadata: { business_id: BIZ } }, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "Zella Voice plan" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 29900, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  return await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, ui_mode: "embedded",
    return_url: "https://app.example.test/welcome/setup?checkout=return&session_id={CHECKOUT_SESSION_ID}", redirect_on_completion: "if_required",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ, checkout_id: CHECKOUT }, ...extra }, `checkout:${crypto.randomUUID()}`);
}
const openRow = (sid: string, status = "open") => ({ checkout_id: CHECKOUT, status, stripe_session_id: sid, mode: "pay", amount_minor: 29900, currency: "usd", expires_at: "2026-11-28T10:00:00Z" });
const post = async (body: Record<string, unknown>) => {
  const r = await handle(new Request("http://fn", { method: "POST", headers: { Authorization: "Bearer owner-jwt", "Content-Type": "application/json" }, body: JSON.stringify(body) }));
  return { status: r.status, body: await r.json() };
};
const start = () => post({ action: "checkout_start", business_id: BIZ, idempotency_key: "owner-key-0001", amount_minor: 1 });

// every console line during a test, so we can prove the client secret is never logged
const logged: string[] = [];
for (const k of ["log", "error", "warn", "info"] as const) { const orig = console[k]; console[k] = (...a: unknown[]) => { logged.push(a.map(String).join(" ")); void orig; }; }

Deno.test("checkout_start returns the embedded session's client secret, the publishable key and the database's amount", async () => {
  const s = await newSession();
  db = { checkout: openRow(s.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals([r.body.status, r.body.client_secret, r.body.publishable_key, r.body.livemode], ["open", s.client_secret, "pk_test_handle0001", false]);
  assertEquals([r.body.amount_minor, r.body.currency, r.body.mode], [29900, "usd", "pay"]);   // never the 1 the browser sent
  assert(!("url" in r.body), "no hosted page link");
  assert(logged.every((l) => !l.includes(String(s.client_secret))), "the client secret is never logged");
});

Deno.test("no publishable key: payments stay closed; a key in the other mode alerts and never starts a checkout", async () => {
  db = { checkout: null, payment: { status: "waiting" } };
  Deno.env.delete("STRIPE_PUBLISHABLE_KEY");
  assertEquals((await start()).body.code, "PAYMENTS_NOT_LIVE");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", "pk_live_handle0001");
  calls.length = 0;
  const r = await start();
  assertEquals([r.status, r.body.code], [503, "PAYMENTS_MISCONFIGURED"]);
  assertEquals(calls.map((c) => c.fn), ["zella_platform_alert"]);   // the owner's start was never called
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", "not-a-key");
  assertEquals((await start()).body.code, "PAYMENTS_NOT_LIVE");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", env.STRIPE_PUBLISHABLE_KEY);
});

Deno.test("a session that isn't ours (another checkout or business) never hands out its secret", async () => {
  const other = await newSession({ client_reference_id: "33333333-3333-4333-8333-333333333333" });
  db = { checkout: openRow(other.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals(r.status, 500);
  assert(!JSON.stringify(r.body).includes("secret"));
  const foreign = await newSession({ metadata: { business_id: "44444444-4444-4444-8444-444444444444", checkout_id: CHECKOUT } });
  db = { checkout: openRow(foreign.id), payment: { status: "waiting" } };
  assertEquals((await start()).status, 500);
});

Deno.test("paid at Stripe: processing, no form; expired at Stripe: start again; not ready yet: try again", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  db = { checkout: openRow(s.id), payment: { status: "waiting" } };
  assertEquals((await start()).body, { status: "processing" });
  db = { checkout: openRow(s.id, "completed"), payment: { status: "waiting" } };
  assertEquals((await start()).body, { status: "processing" });
  const e = await newSession();
  await stripe.post(`/v1/checkout/sessions/${e.id}/expire`, {}, `expire:${e.id}`);
  db = { checkout: openRow(e.id), payment: { status: "waiting" } };
  const x = await start();
  assertEquals([x.status, x.body.code], [409, "CHECKOUT_EXPIRED"]);
  db = { checkout: { ...openRow(""), stripe_session_id: null, status: "preparing" }, payment: { status: "waiting" } };
  assertEquals((await start()).body.code, "CHECKOUT_NOT_READY");
});

Deno.test("a hosted session (made before this change) is not passed off as an embedded one", async () => {
  const cus = await stripe.post("/v1/customers", {}, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "x" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 100, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  const h = await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, success_url: "https://app.example.test/ok",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ } }, `checkout:${crypto.randomUUID()}`);
  db = { checkout: openRow(h.id), payment: { status: "waiting" } };
  assertEquals((await start()).body.code, "CHECKOUT_NOT_READY");
});

Deno.test("the owner's own refusals pass through in words (the database decides who may pay)", async () => {
  db = { checkout: null, payment: { status: "waiting" }, start: new Error("NOT_ALLOWED") };
  const r = await start();
  assertEquals([r.status, r.body.code], [400, "NOT_ALLOWED"]);
});

Deno.test("checkout_return: card brand and last 4 only once the server confirmed the payment, and only as Stripe returns them", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  db = { checkout: openRow(s.id, "completed"), payment: { status: "waiting", reason: "processing" } };
  const waiting = await post({ action: "checkout_return", business_id: BIZ });
  assertEquals(waiting.body, { payment: { status: "waiting", reason: "processing" } });   // no card before it is confirmed
  db = { checkout: openRow(s.id, "paid"), payment: { status: "confirmed" } };
  const done = await post({ action: "checkout_return", business_id: BIZ });
  assertEquals(done.body.card, { brand: "visa", last4: "4242" });
  const req = fake.requests.findLast((x) => x.method === "GET" && x.path.endsWith(s.id));
  assertEquals(req?.body.expand, ["subscription.default_payment_method"]);
  assert(!JSON.stringify(done.body).match(/exp_|cvc|number/i), "nothing but brand and last 4");
});

// the fake was started at module load, before any test: stopping it is not a leak of this step
Deno.test({ name: "cleanup", sanitizeResources: false, sanitizeOps: false, fn: async () => { globalThis.fetch = realFetch; await fake.stop(); } });
