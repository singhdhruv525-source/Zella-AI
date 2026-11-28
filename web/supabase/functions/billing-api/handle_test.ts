// billing-api, checkout_start and checkout_return for Stripe's card fields in our page (owner, 27 Nov 2026), locally: the
// database answers come from a stand in (the owner function's own checks are proven in tests/stripe_checkout), and
// Stripe is the in-memory fake (tests/stripe_fake). Nothing reaches Supabase or Stripe.
// Run: deno test --no-lock --allow-net=127.0.0.1 --allow-env web/supabase/functions/billing-api/handle_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { startFakeStripe } from "../../../../tests/stripe_fake/fake_stripe.ts";
import { stripeClient } from "../_shared/stripe.ts";
import { consentHash, consentText } from "../_shared/paymentConsent.js";
import { fetchEventObject } from "../_shared/billingWorker.ts";

const BACKEND = "http://supabase.test.local";
const BIZ = "11111111-1111-4111-8111-111111111111", CHECKOUT = "22222222-2222-4222-8222-222222222222";
const fake = startFakeStripe();
const stripe = stripeClient({ secretKey: "sk_test_handle", baseUrl: fake.url });
const env = { SUPABASE_URL: BACKEND, SUPABASE_ANON_KEY: "anon-test", ZELLA_SERVER_SECRET_KEY: "server-test", STRIPE_SECRET_KEY: "sk_test_handle",
  STRIPE_API_BASE: fake.url, STRIPE_PUBLISHABLE_KEY: "pk_test_handle0001" };
for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
const { handle, resetApplyThrottle } = await import("./index.ts");

// the database stand in: what the owner functions and the server functions answer
type Answer = Record<string, unknown> | Error | null;
type Db = { checkout: Record<string, unknown> | null; payment: Record<string, unknown>; start?: Record<string, unknown> | Error;
  invoice?: Answer; invoiceStart?: Answer; refs?: Answer; packAct?: Answer; pack?: Answer; prefill?: unknown; autopay?: AutoPay;
  limited?: boolean; noMigration?: boolean; reopened?: Record<string, unknown>[]; checkoutAutopay?: unknown[]; hosted?: string[]; expired?: string[];
  startSeq?: Record<string, unknown>[]; packBuys?: Record<string, unknown>[]; cardChecks?: Record<string, unknown>[];
  // the attempts clear (review round 3): how many agreements the database cleared, and what Pay now's start answers after
  cleared?: number; afterClear?: Answer;
  // stored outbox commands for a checkout (its expiry), claimed and resulted as the database would
  commands?: { id: string; idempotency_key: string; method: "POST"; path: string; body: Record<string, unknown>; attempts: number; status: string; checkout_id: string }[] };
// what the database's start answers by default: the amount it computed and the figures of the agreement's words
const START_FIGURES = { amount_minor: 29900, renewal_minor: 29900, autopay: true, addons: [] as string[], addons_minor: 0, mode: "pay", currency: "usd" };
const CATALOG = [{ code: "minutes_100", resource: "minutes", quantity: 100, price_cents: 2900, currency: "usd" }, { code: "texts_500", resource: "texts", quantity: 500, price_cents: 1800, currency: "usd" }];
const PURCHASE_BUY = "88888888-8888-4888-8888-888888888888";
// Auto pay's database stand in: the owner's choice (versioned), our record of Stripe's value (changed ONLY by an applied
// customer.subscription.updated), the outbox rows, and the Stripe events not yet applied
type AutoPay = { owner: boolean; card: boolean; sub: string; on: boolean; desired: boolean | null; version: number; keys: Set<string>;
  outbox: { id: string; idempotency_key: string; method: "POST"; path: string; body: Record<string, unknown>; attempts: number; status: string }[]; applied: Set<string>; hold?: boolean };
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
  if (fn === "zella_owner_billing_checkout_start") {
    const next = db.startSeq?.shift();
    if (next) return json(next);
    return db.start instanceof Error ? json({ message: db.start.message }, 400) : json(db.start ?? { checkout_id: CHECKOUT, status: db.checkout?.status, ...START_FIGURES });
  }
  if (fn === "zella_owner_addon_catalog") return json(CATALOG);
  if (fn === "zella_owner_pack_buy") { (db.packBuys ??= []).push(args); return json({ purchase_id: PURCHASE_BUY, status: "pending", price_cents: 2900 }); }
  if (fn === "zella_billing_card_checked") { (db.cardChecks ??= []).push(args); return json(true); }
  if (fn === "zella_billing_checkout_session") return db.noMigration ? json({ code: "PGRST202", message: "Could not find the function public.zella_billing_checkout_session" }, 404) : json(db.checkout);
  const answer = (a: Answer | undefined) => a instanceof Error ? json({ message: a.message }, 400) : json(a ?? null);
  if (fn === "zella_owner_invoice_pay_status") return answer(db.invoice);
  if (fn === "zella_owner_invoice_pay_start") return answer(db.invoiceStart);
  if (fn === "zella_billing_stripe_refs") return answer(db.refs);
  if (fn === "zella_rate_limit") return json(!db.limited);
  if (fn === "zella_billing_pack_reopen") { (db.reopened ??= []).push(args); return json({ purchase_id: args.p_purchase_id }); }
  if (fn === "zella_billing_pack_reopen_expire") { (db.expired ??= []).push(args.p_purchase_id); return json("expired"); }
  if (fn === "zella_billing_checkout_autopay") { (db.checkoutAutopay ??= []).push(args); return json(null); }
  if (fn === "zella_billing_checkout_use_hosted") { (db.hosted ??= []).push(args.p_checkout_id); return json(true); }
  if (fn === "zella_billing_address_prefill") return json(db.prefill ?? null);
  if (fn === "zella_owner_billing_access") return json({ business_id: BIZ, payments_live: true, app_base_url: "https://app.example.test" });
  if (fn === "zella_owner_pack_act_start") return answer(db.packAct);
  if (fn === "zella_owner_pack_status") return answer(db.pack);
  if (fn === "zella_owner_onboarding_payment_status") return json(db.payment);
  const ap = db.autopay;
  if (ap && fn === "zella_owner_autopay_status") return ap.owner ? json({ on: ap.on, desired: ap.desired ?? ap.on, pending: ap.desired !== null && ap.desired !== ap.on }) : json({ message: "NOT_ALLOWED" }, 400);
  if (ap && fn === "zella_owner_autopay_set") {
    if (!ap.owner) return json({ message: "NOT_ALLOWED" }, 400);
    if (ap.keys.has(args.p_idempotency_key) || (ap.desired ?? ap.on) === args.p_on) return json({});
    if (args.p_on && !ap.card) return json({ message: "NO_SAVED_CARD" }, 400);
    ap.keys.add(args.p_idempotency_key); ap.desired = args.p_on; ap.version++;
    ap.outbox.push({ id: crypto.randomUUID(), idempotency_key: `autopay:${ap.sub}:${ap.version}:1`, method: "POST", path: `/v1/subscriptions/${ap.sub}`,
      body: args.p_on ? { collection_method: "charge_automatically" } : { collection_method: "send_invoice", days_until_due: 3 }, attempts: 1, status: "pending" });
    return json({});
  }
  if (ap && fn === "zella_billing_autopay_next_command") return json(ap.outbox.find((o) => o.status === "pending")?.id ?? null);
  if (ap && fn === "zella_billing_outbox_claim") { const o = ap.outbox.find((x) => x.id === args.p_id && x.status === "pending"); if (o) o.status = "sending"; return json(o ? [o] : []); }
  if (ap && fn === "zella_billing_outbox_result") { const o = ap.outbox.find((x) => x.id === args.p_id)!; o.status = args.p_ok ? "sent" : "held"; return json(o.status); }
  if (ap && fn === "zella_stripe_claim_events") {
    if (ap.hold) return json([]);
    const rows = fake.events.filter((e) => e.type === "customer.subscription.updated" && e.data.object.id === ap.sub && !ap.applied.has(e.id))
      .map((e) => ({ id: e.id, type: e.type, object_type: "subscription", object_id: e.data.object.id, livemode: false, payload: null }));
    return json(rows);
  }
  if (ap && fn === "zella_stripe_apply_event") { ap.applied.add(args.p_event_id); ap.on = args.p_object.collection_method !== "send_invoice"; return json("applied"); }
  if (fn === "zella_billing_invoice_attempts_clear") { const n = db.cleared ?? 1; if (n > 0 && db.afterClear !== undefined) db.invoiceStart = db.afterClear; return json(n); }
  if (db.commands && fn === "zella_billing_checkout_next_command") return json(db.commands.find((c) => c.checkout_id === args.p_checkout_id && c.status === "pending")?.id ?? null);
  if (db.commands && fn === "zella_billing_outbox_claim") { const c = db.commands.find((x) => x.id === args.p_id && x.status === "pending"); if (c) c.status = "sending"; return json(c ? [c] : []); }
  if (db.commands && fn === "zella_billing_outbox_result") { const c = db.commands.find((x) => x.id === args.p_id)!; c.status = args.p_ok ? "sent" : "retry_wait"; return json(c.status); }
  if (fn === "zella_billing_events_claim" || fn.startsWith("zella_billing_")) return json(null);
  if (fn === "zella_platform_alert") return json(null);
  return json(null);
};

async function newSession(extra: Record<string, unknown> = {}) {
  const cus = await stripe.post("/v1/customers", { metadata: { business_id: BIZ } }, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "Zella Voice plan" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 29900, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  return await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, ui_mode: "custom",
    return_url: "https://app.example.test/welcome/setup?checkout=return&session_id={CHECKOUT_SESSION_ID}",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ, checkout_id: CHECKOUT }, ...extra }, `checkout:${crypto.randomUUID()}`);
}
const openRow = (sid: string, status = "open") => ({ checkout_id: CHECKOUT, status, stripe_session_id: sid, mode: "pay", amount_minor: 29900, currency: "usd", expires_at: "2026-11-28T10:00:00Z" });
// The owner's agreement, as the page sends it: the sha256 of the words for the figures the server will answer (from the
// stand in's own answer). A test that sends its own consent fields (or none: consent: undefined) is not changed.
const NEEDS_CONSENT = new Set(["checkout_start", "invoice_pay_start", "pack_act_start", "pack_buy"]);
const hashOf = async (f: Parameters<typeof consentText>[0]) => { const t = consentText(f); return t ? await consentHash(t) : "0".repeat(64); };
async function withConsent(body: Record<string, unknown>) {
  if (!NEEDS_CONSENT.has(String(body.action)) || "consent" in body) return body;
  let f: Parameters<typeof consentText>[0] | null = null;
  if (body.action === "checkout_start") { const s = db.start instanceof Error ? START_FIGURES : { ...START_FIGURES, ...(db.start ?? {}) } as typeof START_FIGURES;
    f = { kind: "plan", todayMinor: s.amount_minor, autopay: body.autopay !== false, renewalMinor: s.renewal_minor, addonsMinor: s.addons_minor ?? 0 }; }
  if (body.action === "invoice_pay_start" && db.invoiceStart && !(db.invoiceStart instanceof Error)) { const i = db.invoiceStart as Record<string, any>;
    f = { kind: "invoice", todayMinor: i.amount_due_minor, autopay: i.autopay !== false, renewalMinor: i.renewal_minor, addonsMinor: i.addons_minor ?? 0 }; }
  if (body.action === "pack_act_start" && db.packAct && !(db.packAct instanceof Error)) f = { kind: "pack", todayMinor: (db.packAct as Record<string, any>).price_cents };
  if (body.action === "pack_buy") f = { kind: "pack", todayMinor: CATALOG.find((c) => c.code === body.pack_code)?.price_cents };
  return { ...body, consent: true, consent_hash: f ? await hashOf(f) : "0".repeat(64) };
}
const post = async (raw: Record<string, unknown>) => {
  const body = await withConsent(raw);
  const r = await handle(new Request("http://fn", { method: "POST", headers: { Authorization: "Bearer owner-jwt", "Content-Type": "application/json" }, body: JSON.stringify(body) }));
  return { status: r.status, body: await r.json() };
};
const start = () => post({ action: "checkout_start", business_id: BIZ, idempotency_key: "owner-key-0001", amount_minor: 1 });

// every console line during a test, so we can prove the client secret is never logged
const logged: string[] = [];
for (const k of ["log", "error", "warn", "info"] as const) { const orig = console[k]; console[k] = (...a: unknown[]) => { logged.push(a.map(String).join(" ")); void orig; }; }

Deno.test("checkout_start returns the in page (custom) session's client secret, the publishable key and the database's amount", async () => {
  const s = await newSession();
  db = { checkout: openRow(s.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals([r.body.status, r.body.client_secret, r.body.publishable_key, r.body.livemode], ["open", s.client_secret, "pk_test_handle0001", false]);
  assertEquals(r.body.billing_prefill, {}, "no address on file: Stripe's fields start empty (United States)");
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
  // the owner check runs first (review 7), then the key check closes everything: nothing is prepared or sent
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "stripe_key_mode_mismatch"));
  assert(!calls.some((c) => c.fn === "zella_billing_checkout_continue"), "nothing is prepared at Stripe")
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

Deno.test("a hosted session is never passed off as an in page one: Stripe's own page, no client secret", async () => {
  const cus = await stripe.post("/v1/customers", {}, `customer:${crypto.randomUUID()}`);
  const prod = await stripe.post("/v1/products", { name: "x" }, `product:${crypto.randomUUID()}`);
  const price = await stripe.post("/v1/prices", { product: prod.id, currency: "usd", unit_amount: 29900, recurring: { interval: "month" } }, `price:${crypto.randomUUID()}`);
  const h = await stripe.post("/v1/checkout/sessions", { mode: "subscription", customer: cus.id, client_reference_id: CHECKOUT, success_url: "https://app.example.test/ok",
    line_items: [{ price: price.id, quantity: 1 }], metadata: { business_id: BIZ } }, `checkout:${crypto.randomUUID()}`);
  db = { checkout: openRow(h.id), payment: { status: "waiting" } };
  const r = await start();
  assertEquals([r.body.status, "client_secret" in r.body, String(r.body.url).startsWith("https://checkout.stripe.com/")], ["redirect", false, true]);
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
  assertEquals(done.body.card, { brand: "visa", last4: "4242", issuer: "Test Bank" });
  const req = fake.requests.findLast((x) => x.method === "GET" && x.path.endsWith(s.id));
  assertEquals(req?.body.expand, ["subscription.default_payment_method"]);
  assert(!JSON.stringify(done.body).match(/exp_|cvc|number/i), "nothing but brand and last 4");
});

// ---- paying from inside the CRM: Pay now, the saved card, Update card, finishing a pack ----
const INVOICE = "55555555-5555-4555-8555-555555555555", PURCHASE = "66666666-6666-4666-8666-666666666666";
const act = (body: Record<string, unknown>) => { resetApplyThrottle(); return post(body); };
// a business that paid its first invoice through Checkout, then a renewal its saved card couldn't pay: open, past due
async function pastDue() {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sess = fake.objects.get(s.id)!, sub = fake.objects.get(sess.subscription)!;
  fake.setCard(sub.customer, "decline");
  const draft = fake.renew(sub.id);
  const inv = fake.finalizeAndPay(draft.id);
  return { customer: sub.customer as string, sub: sub.id as string, inv };
}
const invRow = (inv: Record<string, any>, extra: Record<string, unknown> = {}) => ({ invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, number: inv.number,
  amount_due_minor: inv.amount_due, currency: "usd", hosted_invoice_url: inv.hosted_invoice_url, livemode: false,
  total_minor: inv.amount_due, renewal_minor: 29900, autopay: true, addons: [], addons_minor: 0, ...extra });

Deno.test("Pay now: the open invoice's own PaymentIntent for Stripe's form; a double start gives the same intent and creates nothing", async () => {
  const { customer, sub, inv } = await pastDue();
  assertEquals(inv.status, "open");
  // the business's own address prefills Stripe's billing address fields; only plain strings pass, any country
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub },
    prefill: { line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA", extra: "<b>x</b>", line2: 5 } };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(r.body.billing_prefill, { line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA" });
  assertEquals([r.body.status, r.body.amount_minor, r.body.publishable_key, r.body.livemode], ["open", inv.amount_due, "pk_test_handle0001", false]);
  const pi = fake.objects.get(String(r.body.client_secret).split("_secret_")[0])!;
  assertEquals(pi.metadata.invoice, inv.id, "the invoice's own intent");
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const again = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(again.body.client_secret, r.body.client_secret, "a double start: the same intent");
  assertEquals(fake.requests.filter((x) => x.method === "POST").length, posts, "nothing was created at Stripe");
  assert(logged.every((l) => !l.includes(String(r.body.client_secret))), "never logged");
  // the customer pays in Stripe's form: Stripe has it, so a later start says processing (our record follows invoice.paid)
  fake.confirmIntent(pi.id);
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body, { status: "processing" });
});

Deno.test("Pay now refusals: another business's invoice, a paid one, a void one, payments off, keys in other modes", async () => {
  for (const code of ["NOT_FOUND", "ALREADY_PAID", "NOT_PAYABLE", "PAYMENTS_NOT_LIVE", "MFA_REQUIRED"]) {
    db = { checkout: null, payment: {}, invoiceStart: new Error(code) };
    const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
    assertEquals([r.status, r.body.code], [400, code], code);
    assert(!("client_secret" in r.body));
  }
  db = { checkout: null, payment: {}, invoice: new Error("NOT_FOUND") };
  assertEquals((await act({ action: "invoice_pay_status", invoice_id: INVOICE })).body.code, "NOT_FOUND");
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: "not-a-uuid" })).body.code, "INVALID_INPUT");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", "pk_live_handle0001");
  db = { checkout: null, payment: {}, invoiceStart: { invoice_id: INVOICE } };
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body.code, "PAYMENTS_MISCONFIGURED");
  Deno.env.set("STRIPE_PUBLISHABLE_KEY", env.STRIPE_PUBLISHABLE_KEY);
});

Deno.test("Pay now binding: another customer's invoice, a mode change, or a different amount never hands out a secret", async () => {
  const a = await pastDue(), other = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(other.inv), refs: { customer: a.customer, subscription: a.sub } };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  assertEquals(r.status, 500);
  assert(!JSON.stringify(r.body).includes("secret"));
  db = { checkout: null, payment: {}, invoiceStart: invRow(a.inv, { livemode: true }), refs: { customer: a.customer, subscription: a.sub } };
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body.code, "NOT_PAYABLE");
  calls.length = 0;
  db = { checkout: null, payment: {}, invoiceStart: invRow(a.inv, { amount_due_minor: 1 }), refs: { customer: a.customer, subscription: a.sub } };
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body.code, "CHECKOUT_NOT_READY");
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "billing_invoice_amount"));
});

Deno.test("Pay now return: paid only from our records after the events are applied", async () => {
  db = { checkout: null, payment: {}, invoice: { invoice_id: INVOICE, status: "open", payable: true } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body, { invoice: { invoice_id: INVOICE, status: "open", payable: true } });
  db = { checkout: null, payment: {}, invoice: { invoice_id: INVOICE, status: "paid", payable: false } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.invoice.status, "paid");
  // paid in Stripe's form: the card it used, brand, last 4 and the issuer as Stripe gives it
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub } };
  const start = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  fake.confirmIntent(String(start.body.client_secret).split("_secret_")[0]);
  db = { ...db, invoice: { invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, status: "paid" } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.card, { brand: "visa", last4: "4242", issuer: "Test Bank" });
  db = { ...db, refs: { customer: "cus_someone_else", subscription: sub } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.card, undefined, "another customer's invoice: no card");
});

Deno.test("the saved card: brand and last 4 from Stripe, or nothing", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id } };
  assertEquals((await act({ action: "card_summary", business_id: BIZ })).body, { card: { brand: "visa", last4: "4242" } }, "brand and last 4 only, no issuer");
  db = { checkout: null, payment: {}, refs: { customer: "cus_someone_else", subscription: sub.id } };
  assertEquals((await act({ action: "card_summary", business_id: BIZ })).body, { card: null }, "another customer's subscription shows nothing");
  db = { checkout: null, payment: {}, refs: { customer: null, subscription: null } };
  assertEquals((await act({ action: "card_summary", business_id: BIZ })).body, { card: null });
  // Stripe's lookup fails: an error, never "no card" (review round 3)
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: "sub_missing0001" } };
  const failedLookup = await act({ action: "card_summary", business_id: BIZ });
  assert(failedLookup.status >= 500 && !("card" in failedLookup.body), JSON.stringify(failedLookup));
});

Deno.test("Update card: Stripe's Customer Portal, card update only, back to the Payments page; none before a first payment", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id } };
  const r = await act({ action: "card_update_start", business_id: BIZ, idempotency_key: "card-key-0001" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assert(String(r.body.url).startsWith("https://"));
  const req = fake.requests.findLast((x) => x.path === "/v1/billing_portal/sessions")!;
  assertEquals([req.key, req.body.customer, req.body.flow_data.type, req.body.return_url], ["portal:" + BIZ + ":card-key-0001", sub.customer, "payment_method_update",
    "https://app.example.test/app/settings/billing/invoices?card=updated"]);
  assertEquals((await act({ action: "card_update_start", business_id: BIZ, idempotency_key: "bad key" })).body.code, "INVALID_INPUT");
  db = { checkout: null, payment: {}, refs: { customer: null, subscription: null } };
  assertEquals((await act({ action: "card_update_start", business_id: BIZ, idempotency_key: "card-key-0002" })).body.code, "NO_CUSTOMER");
});

Deno.test("a pack the bank wants confirmed: the same PaymentIntent for Stripe's form; another purchase's intent is refused", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  fake.setCard(sub.customer, "auth");
  const failed = await stripe.post("/v1/payment_intents", { customer: sub.customer, amount: 2900, currency: "usd", off_session: true, confirm: true, metadata: { purchase_id: PURCHASE } }, `pack:${PURCHASE}`).catch((e) => e);
  const piId = failed.paymentIntent as string;
  assertEquals(fake.objects.get(piId)!.status, "requires_action");
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id }, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 2900 } };
  const r = await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE });
  assertEquals([r.status, r.body.status, r.body.amount_minor, r.body.client_secret], [200, "open", 2900, fake.objects.get(piId)!.client_secret]);
  const again = await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE });
  assertEquals(again.body.client_secret, r.body.client_secret, "the same intent: never a second charge");
  // B1: only after Stripe's checks is the purchase reopened, on THIS intent, in the key's mode (so it gets its link)
  assertEquals(db.reopened?.map((x) => [x.p_purchase_id, x.p_payment_intent, x.p_livemode]), [[PURCHASE, piId, false], [PURCHASE, piId, false]]);
  const reopenedBefore = db.reopened!.length;
  db = { ...db, packAct: { purchase_id: "77777777-7777-4777-8777-777777777777", payment_intent: piId, price_cents: 2900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: "77777777-7777-4777-8777-777777777777" })).status, 500, "another purchase's intent");
  db = { ...db, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 9900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE })).status, 500, "a different amount");
  assertEquals(db.reopened!.length, reopenedBefore, "a binding failure reopens nothing (review 3)");
  fake.confirmIntent(piId);
  db = { ...db, packAct: { purchase_id: PURCHASE, payment_intent: piId, price_cents: 2900 } };
  assertEquals((await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE })).body, { status: "processing" });
  db = { ...db, pack: { purchase_id: PURCHASE, status: "granted", payment_intent: piId } };
  const granted = await act({ action: "pack_status", business_id: BIZ, purchase_id: PURCHASE });
  assertEquals([granted.body.purchase.status, granted.body.card], ["granted", { brand: "visa", last4: "4242", issuer: "Test Bank" }]);
  db = { ...db, pack: { purchase_id: PURCHASE, status: "pending", payment_intent: piId } };
  assertEquals((await act({ action: "pack_status", business_id: BIZ, purchase_id: PURCHASE })).body.card, undefined, "no card before it is granted");
});

// the fake was started at module load, before any test: stopping it is not a leak of this step

// Auto pay (owner decision, 27 Nov 2026: "Auto pay switch, on by default")
async function subscribed() {
  const s0 = await newSession();
  fake.completeCheckout(s0.id);
  const sub = fake.objects.get(fake.objects.get(s0.id)!.subscription)!;
  return sub;
}
const autopayDb = (sub: Record<string, any>, extra: Partial<AutoPay> = {}): Db => ({ checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id },
  autopay: { owner: true, card: true, sub: sub.id, on: true, desired: null, version: 0, keys: new Set(), outbox: [], applied: new Set(fake.events.map((e) => e.id)), ...extra } });

Deno.test("Auto pay off: the database records the choice, Stripe's subscription is updated with the stored body, and our record follows Stripe's event", async () => {
  const sub = await subscribed();
  db = autopayDb(sub);
  const r = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0001" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  const req = fake.requests.findLast((x) => x.path === `/v1/subscriptions/${sub.id}` && x.method === "POST")!;
  assertEquals([req.key, req.body.collection_method, req.body.days_until_due], [`autopay:${sub.id}:1:1`, "send_invoice", "3"]);
  assertEquals([fake.objects.get(sub.id)!.collection_method, fake.objects.get(sub.id)!.days_until_due], ["send_invoice", 3]);
  assertEquals(db.autopay!.on, false, "off only once customer.subscription.updated was applied");
  assertEquals(r.body.autopay, { on: false, desired: false, pending: false });
  // a double submit: the same key changes nothing at Stripe
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const again = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0001" });
  assertEquals([again.status, fake.requests.filter((x) => x.method === "POST").length], [200, posts]);
});

Deno.test("Auto pay: our record never changes from the browser or our own command; until Stripe's event is applied it stays as it was", async () => {
  const sub = await subscribed();
  db = autopayDb(sub, { hold: true });
  const r = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0002" });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(fake.objects.get(sub.id)!.collection_method, "send_invoice", "Stripe has it");
  assertEquals(r.body.autopay, { on: true, desired: false, pending: true }, "still on in our record, the change pending");
});

Deno.test("Auto pay: another business's owner is refused, nothing reaches Stripe", async () => {
  const sub = await subscribed();
  db = autopayDb(sub, { owner: false });
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const r = await act({ action: "autopay_set", business_id: BIZ, on: false, idempotency_key: "autopay-key-0003" });
  assertEquals([r.status, r.body.code], [400, "NOT_ALLOWED"]);
  assertEquals(fake.requests.filter((x) => x.method === "POST").length, posts);
});

Deno.test("Auto pay on: refused with no usable saved card (checked with Stripe), and with bad input", async () => {
  const sub = await subscribed();
  db = autopayDb(sub, { on: false });
  fake.objects.get(sub.id)!.default_payment_method = null;
  const r = await act({ action: "autopay_set", business_id: BIZ, on: true, idempotency_key: "autopay-key-0004" });
  assertEquals([r.status, r.body.code], [409, "NO_SAVED_CARD"]);
  assertEquals(db.autopay!.outbox.length, 0, "nothing queued");
  assertEquals((await act({ action: "autopay_set", business_id: BIZ, on: "yes", idempotency_key: "autopay-key-0005" })).body.code, "INVALID_INPUT");
  assertEquals((await act({ action: "autopay_set", business_id: BIZ, on: true, idempotency_key: "bad key" })).body.code, "INVALID_INPUT");
});

Deno.test("Auto pay: an expired card isn't a usable card", async () => {
  const { usableCard } = await import("./index.ts");
  const now = new Date("2026-11-27T00:00:00Z");
  assertEquals(usableCard({ card: { exp_month: 11, exp_year: 2026 } }, now), true);
  assertEquals(usableCard({ card: { exp_month: 10, exp_year: 2026 } }, now), false);
  assertEquals(usableCard({ id: "pm_1" }, now), false);
  assertEquals(usableCard(null, now), false);
});

// ---- double payment protections (owner priority, 27 Nov 2026) ----
Deno.test("cases 3 and 11: Auto pay charges the invoice while the owner's tab confirms it: one success, one charge; the page then shows processing, never Pay", async () => {
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub }, invoice: invRow(inv, { status: "open", payable: true }) };
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  const piId = String(r.body.client_secret).split("_secret_")[0];
  fake.setCard(customer, "ok");
  await stripe.post(`/v1/invoices/${inv.id}/pay`, {}, `retry:${inv.id}`);   // Stripe's retry with the saved card (Auto pay)
  fake.confirmIntent(piId);                                                // the owner's tab confirms the same intent
  assertEquals(fake.requests.length > 0, true);
  const charges = [...fake.objects.values()].filter((o) => o.object === "charge" && o.payment_intent === piId);
  assertEquals(charges.length, 1, "the invoice's one PaymentIntent succeeds once: one charge");
  const status = await act({ action: "invoice_pay_status", invoice_id: INVOICE });
  assertEquals(status.body.invoice.processing, true, "Stripe has it: the page confirms, no Pay");
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE })).body, { status: "processing" });
});

Deno.test("case 10: two invoices in two tabs: each its own PaymentIntent and its own exact amount", async () => {
  const a = await pastDue(), b = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(a.inv), refs: { customer: a.customer, subscription: a.sub } };
  const ra = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  db = { checkout: null, payment: {}, invoiceStart: invRow(b.inv), refs: { customer: b.customer, subscription: b.sub } };
  const rb = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  const pa = fake.objects.get(String(ra.body.client_secret).split("_secret_")[0])!, pb = fake.objects.get(String(rb.body.client_secret).split("_secret_")[0])!;
  assert(pa.id !== pb.id);
  assertEquals([pa.metadata.invoice, pb.metadata.invoice, ra.body.amount_minor, rb.body.amount_minor], [a.inv.id, b.inv.id, a.inv.amount_due, b.inv.amount_due]);
});

// ---- review fixes (27 Nov 2026) ----
Deno.test("rate limited per person: over the limit answers 429 before anything else", async () => {
  db = { checkout: null, payment: {}, limited: true };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "rate-key-0001" });
  assertEquals([r.status, r.body.code], [429, "TOO_MANY"]);
  assert(!calls.some((c) => c.fn === "zella_owner_billing_checkout_start"), "the owner function never ran");
});

Deno.test("applied in order: without the checkout migration nothing starts, and Zella Voice is told", async () => {
  db = { checkout: null, payment: {}, noMigration: true };
  const posts = fake.requests.filter((x) => x.method === "POST").length;
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "order-key-0001" });
  assertEquals([r.status, r.body.code], [503, "PAYMENTS_MISCONFIGURED"]);
  assertEquals(fake.requests.filter((x) => x.method === "POST").length, posts, "no session at Stripe");
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "billing_migration_missing"));
});

Deno.test("checkout: a session whose amount differs from ours is never shown, and Zella Voice is told", async () => {
  const sess = await newSession();
  db = { checkout: { ...openRow(sess.id), amount_minor: 1000 }, payment: {} };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "amount-key-0001" });
  assertEquals([r.status, r.body.code, "client_secret" in r.body], [502, "CHECKOUT_NOT_READY", false]);
  assert(calls.some((c) => c.fn === "zella_platform_alert" && c.args.p_kind === "billing_checkout_amount"));
});

Deno.test("checkout: the owner's Auto pay choice is kept with the checkout on the server (M2)", async () => {
  const sess = await newSession();
  db = { checkout: openRow(sess.id), payment: {} };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "autopay-ck-0001", autopay: false });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  // the choice goes with the start itself: the database keeps it with the checkout and words the agreement by it
  assertEquals(calls.findLast((c) => c.fn === "zella_owner_billing_checkout_start")?.args.p_autopay, false);
});

Deno.test("hosted fallback: a hosted session answers Stripe's own page; asking for hosted over an open in page session expires it at Stripe first", async () => {
  const hosted = await newSession({ ui_mode: "hosted", return_url: undefined, success_url: "https://app.example.test/welcome/setup?checkout=return&session_id={CHECKOUT_SESSION_ID}", cancel_url: "https://app.example.test/welcome/setup?checkout=cancel" });
  db = { checkout: openRow(hosted.id), payment: {} };
  const h = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "hosted-key-0001" });
  assertEquals([h.status, h.body.status, String(h.body.url).startsWith("https://checkout.stripe.com/"), "client_secret" in h.body], [200, "redirect", true, false]);
  const custom = await newSession();
  db = { checkout: openRow(custom.id), payment: {} };
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "hosted-key-0002", hosted: true });
  assertEquals([r.status, r.body.code], [409, "CHECKOUT_EXPIRED"]);
  assertEquals(fake.objects.get(custom.id)!.status, "expired", "one session at a time: the in page one is expired before a hosted one is made");
  const req = fake.requests.findLast((x) => x.path === `/v1/checkout/sessions/${custom.id}/expire`)!;
  assertEquals(req.key, `expire:${custom.id}`);
});
// ---- the required "I agree" box (owner decision, 27 Nov 2026) and the add ons ----
Deno.test("agreement: every payment start is refused without consent and a sha256, before the database or Stripe is asked", async () => {
  db = { checkout: null, payment: {}, invoiceStart: { invoice_id: INVOICE }, packAct: { purchase_id: PURCHASE, payment_intent: "pi_x", price_cents: 2900 } };
  for (const body of [{ action: "checkout_start", business_id: BIZ, idempotency_key: "consent-key-001" }, { action: "invoice_pay_start", invoice_id: INVOICE },
    { action: "pack_buy", business_id: BIZ, pack_code: "minutes_100", idempotency_key: "consent-key-002" }, { action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE }]) {
    for (const consent of [{ consent: undefined }, { consent: false, consent_hash: "a".repeat(64) }, { consent: true, consent_hash: "not-a-sha" }, { consent: true }]) {
      calls.length = 0;
      const r = await act({ ...body, ...consent });
      assertEquals([r.status, r.body.code], [400, "CONSENT_REQUIRED"], `${body.action} ${JSON.stringify(consent)}`);
      assert(!calls.some((c) => c.as === "owner"), "the database isn't asked");
    }
  }
});

Deno.test("agreement: words that don't match the server's figures are refused, and nothing reaches Stripe or the browser", async () => {
  const sess = await newSession();
  db = { checkout: openRow(sess.id), payment: {}, start: { checkout_id: CHECKOUT, status: "preparing", ...START_FIGURES, amount_minor: 34600, addons: ["minutes_100", "texts_500"], addons_minor: 4700 } };
  calls.length = 0;
  const wrong = await hashOf({ kind: "plan", todayMinor: 29900, autopay: true, renewalMinor: 29900 });   // the page without the add ons
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "consent-key-003", packs: ["minutes_100", "texts_500"], consent: true, consent_hash: wrong });
  assertEquals([r.status, r.body.code, "client_secret" in r.body], [409, "CONSENT_MISMATCH", false]);
  assert(!calls.some((c) => c.fn === "zella_billing_checkout_continue"), "nothing is prepared at Stripe");
  assertEquals(calls.find((c) => c.fn === "zella_owner_billing_checkout_start")?.args.p_packs, ["minutes_100", "texts_500"], "pack codes only reach the database");
  // Pay now: the database answered the invoice plus two add ons; the page's words without them are refused, no secret
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv, { total_minor: inv.amount_due + 4700, addons: [{ code: "minutes_100" }, { code: "texts_500" }], addons_minor: 4700 }), refs: { customer, subscription: sub } };
  const p = await act({ action: "invoice_pay_start", invoice_id: INVOICE, addons: [{ code: "minutes_100", key: "addon-key-001" }, { code: "texts_500", key: "addon-key-002" }],
    consent: true, consent_hash: await hashOf({ kind: "plan", todayMinor: inv.amount_due, autopay: true, renewalMinor: 29900 }) });
  assertEquals([p.status, p.body.code, "client_secret" in p.body], [409, "CONSENT_MISMATCH", false]);
  const ok = await act({ action: "invoice_pay_start", invoice_id: INVOICE, addons: [{ code: "minutes_100", key: "addon-key-001" }, { code: "texts_500", key: "addon-key-002" }] });
  assertEquals([ok.status, ok.body.status, ok.body.amount_minor], [200, "open", inv.amount_due], "the invoice's own amount is what Stripe takes; the add ons follow separately");
  assertEquals(calls.findLast((c) => c.fn === "zella_owner_invoice_pay_start")?.args.p_addons, [{ code: "minutes_100", key: "addon-key-001" }, { code: "texts_500", key: "addon-key-002" }]);
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE, addons: [{ code: "MINUTES", key: "addon-key-001" }] })).body.code, "INVALID_INPUT");
  assertEquals((await act({ action: "invoice_pay_start", invoice_id: INVOICE, addons: [{ code: "minutes_100", key: "x" }] })).body.code, "INVALID_INPUT");
  // finishing a pack: the words for another amount are refused before the purchase is reopened
  db = { checkout: null, payment: {}, refs: { customer, subscription: sub }, packAct: { purchase_id: PURCHASE, payment_intent: "pi_x", price_cents: 2900 } };
  const a = await act({ action: "pack_act_start", business_id: BIZ, purchase_id: PURCHASE, consent: true, consent_hash: await hashOf({ kind: "pack", todayMinor: 1800 }) });
  assertEquals([a.status, a.body.code, db.reopened ?? []], [409, "CONSENT_MISMATCH", []]);
});

Deno.test("add ons: the pack page's words come from the catalogue; an add on agreed with Pay now goes to the database with its invoice", async () => {
  db = { checkout: null, payment: {}, refs: { customer: null, subscription: null } };
  const bad = await act({ action: "pack_buy", business_id: BIZ, pack_code: "minutes_100", idempotency_key: "pack-key-0001", consent: true, consent_hash: await hashOf({ kind: "pack", todayMinor: 1800 }) });
  assertEquals([bad.status, bad.body.code, db.packBuys ?? []], [409, "CONSENT_MISMATCH", []]);
  assertEquals((await act({ action: "pack_buy", business_id: BIZ, pack_code: "minutes_999", idempotency_key: "pack-key-0001", consent: true, consent_hash: "a".repeat(64) })).body.code, "UNKNOWN_PACK");
  const ok = await act({ action: "pack_buy", business_id: BIZ, pack_code: "minutes_100", idempotency_key: "pack-key-0001" });
  assertEquals([ok.status, ok.body.purchase_id], [200, PURCHASE_BUY]);
  assertEquals(db.packBuys?.[0]?.p_invoice_id, null);
  const hash = "b".repeat(64);
  await act({ action: "pack_buy", business_id: BIZ, pack_code: "texts_500", idempotency_key: "pay-now-key-a1", invoice_id: INVOICE, consent: true, consent_hash: hash });
  assertEquals([db.packBuys?.[1]?.p_invoice_id, db.packBuys?.[1]?.p_consent_hash, db.packBuys?.[1]?.p_idempotency_key], [INVOICE, hash, "pay-now-key-a1"],
    "the database checks the Pay now agreement named this pack and this key, and that the invoice is paid");
  assertEquals((await act({ action: "pack_buy", business_id: BIZ, pack_code: "texts_500", idempotency_key: "pay-now-key-a1", invoice_id: "nope", consent: true, consent_hash: hash })).body.code, "INVALID_INPUT");
});

Deno.test("add ons at onboarding: a changed selection expires the open session first (its stored command), then starts again", async () => {
  const old = await newSession(), sess = await newSession();
  const OLD = "99999999-9999-4999-8999-999999999999", CMD = "77777777-7777-4777-8777-777777777777";
  // the old checkout's stored expiry command (review round 3: a real command, sent to the fake Stripe)
  db = { checkout: openRow(sess.id), payment: {}, startSeq: [{ checkout_id: OLD, status: "expiring", amount_minor: 29900, mode: "pay", currency: "usd" }],
    commands: [{ id: CMD, idempotency_key: `checkoutexpire:${OLD}`, method: "POST", path: `/v1/checkout/sessions/${old.id}/expire`, body: {}, attempts: 1, status: "pending", checkout_id: OLD }] };
  calls.length = 0;
  const r = await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "select-key-0001", packs: [] });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  assertEquals(calls.filter((c) => c.fn === "zella_owner_billing_checkout_start").length, 2, "asked again once the old one is being expired");
  assertEquals(calls.find((c) => c.fn === "zella_billing_checkout_next_command")?.args.p_checkout_id, OLD, "the old checkout's expiry is sent");
  assertEquals([fake.objects.get(old.id)!.status, db.commands![0].status], ["expired", "sent"], "Stripe expired the old session, and the command is recorded as sent");
  const order = calls.map((c) => c.fn);
  assert(order.indexOf("zella_billing_outbox_result") < order.lastIndexOf("zella_owner_billing_checkout_start"), "the new checkout is asked for only after the expiry succeeded");
  assertEquals([r.body.status, r.body.client_secret], ["open", sess.client_secret], "then the replacement session opens");
  // Stripe refuses the expiry (the old session is gone): the replacement stays unavailable
  db = { checkout: openRow(sess.id), payment: {}, startSeq: [{ checkout_id: OLD, status: "expiring" }, { checkout_id: OLD, status: "expiring" }],
    commands: [{ id: CMD, idempotency_key: `checkoutexpire:${OLD}`, method: "POST", path: "/v1/checkout/sessions/cs_missing/expire", body: {}, attempts: 1, status: "pending", checkout_id: OLD }] };
  assertEquals((await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "select-key-0004" })).body.code, "CHECKOUT_NOT_READY", "no expiry, no replacement");
  db = { checkout: openRow(sess.id), payment: {}, startSeq: [{ checkout_id: CHECKOUT, status: "expiring" }, { checkout_id: CHECKOUT, status: "expiring" }] };
  assertEquals((await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "select-key-0002" })).body.code, "CHECKOUT_NOT_READY", "never two open sessions");
  assertEquals((await act({ action: "checkout_start", business_id: BIZ, idempotency_key: "select-key-0003", packs: ["Minutes 100"] })).body.code, "INVALID_INPUT");
});

Deno.test("review: Pay now turning Auto pay on runs the same usable card check first; a refusal never blocks paying", async () => {
  const { customer, sub, inv } = await pastDue();
  fake.objects.get(sub)!.default_payment_method = null;   // no usable saved card at Stripe
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv, { autopay: true }), refs: { customer, subscription: sub },
    autopay: { owner: true, card: true, sub, on: false, desired: null, version: 0, keys: new Set(), outbox: [], applied: new Set() } };
  calls.length = 0;
  const r = await act({ action: "invoice_pay_start", invoice_id: INVOICE, autopay: true, autopay_key: "autopay-pay-key-1" });
  assertEquals([r.status, r.body.status, r.body.autopay_error], [200, "open", "NO_SAVED_CARD"]);
  assert(!calls.some((c) => c.fn === "zella_owner_autopay_set"), "the Auto pay change isn't attempted without a usable card");
});

Deno.test("review: turning Auto pay on records the card billing-api checked with Stripe (the database needs it)", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  db = { checkout: null, payment: {}, refs: { customer: sub.customer, subscription: sub.id },
    autopay: { owner: true, card: true, sub: sub.id, on: false, desired: null, version: 0, keys: new Set(), outbox: [], applied: new Set(), hold: true } };
  await act({ action: "autopay_set", business_id: BIZ, on: true, idempotency_key: "autopay-card-0001" });
  const pm = typeof sub.default_payment_method === "string" ? sub.default_payment_method : sub.default_payment_method?.id;
  assertEquals(db.cardChecks?.map((c) => [c.p_business_id, c.p_payment_method]), [[BIZ, pm]]);
});

Deno.test("review: Pay now's return asks Stripe for the invoice's payments (includable), so the card that paid is found", async () => {
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub } };
  const start = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  fake.confirmIntent(String(start.body.client_secret).split("_secret_")[0]);
  db = { ...db, invoice: { invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, status: "paid" } };
  const r = await act({ action: "invoice_pay_return", invoice_id: INVOICE });
  assertEquals(r.body.card?.last4, "4242");
  assertEquals(fake.requests.findLast((x) => x.method === "GET" && x.path === `/v1/invoices/${inv.id}`)?.body.expand, ["payments"]);
  assertEquals((await stripe.get(`/v1/invoices/${inv.id}`) as Record<string, unknown>).payments, undefined, "the fake, like Stripe, leaves payments out unless expanded");
});

Deno.test("review: while our record is still open, Pay now's return says whether Stripe has the payment (so the page can offer Pay again)", async () => {
  const { customer, sub, inv } = await pastDue();
  db = { checkout: null, payment: {}, invoiceStart: invRow(inv), refs: { customer, subscription: sub }, invoice: { invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, status: "open", payable: true } };
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.invoice.processing, undefined, "Stripe has nothing for it: not processing");
  const start = await act({ action: "invoice_pay_start", invoice_id: INVOICE });
  fake.confirmIntent(String(start.body.client_secret).split("_secret_")[0]);
  assertEquals((await act({ action: "invoice_pay_return", invoice_id: INVOICE })).body.invoice.processing, true, "Stripe has it: confirming, never Pay again");
});

Deno.test("review rounds 2 and 3: Pay in a second tab with other add ons waits while the first tab's payment may be in flight; a clear is bound to the failed attempt", async () => {
  const { customer, sub, inv } = await pastDue();
  const si = await stripe.get(`/v1/invoices/${inv.id}`, { expand: ["payments"] }) as Record<string, any>;
  const piId = String(si.payments.data[0].payment.payment_intent);
  const pi = fake.objects.get(piId)!;
  const busy = () => ({ checkout: null, payment: {}, invoiceStart: new Error("ADDONS_IN_PROGRESS"), refs: { customer, subscription: sub },
    invoice: { invoice_id: INVOICE, business_id: BIZ, stripe_invoice_id: inv.id, status: "open", payable: true } }) as Db;
  const hash = await hashOf({ kind: "invoice", todayMinor: inv.amount_due, autopay: true, renewalMinor: 29900, addonsMinor: 0 });
  const pay = () => act({ action: "invoice_pay_start", invoice_id: INVOICE, submit: true, consent: true, consent_hash: hash });
  const clears = () => calls.filter((c) => c.fn === "zella_billing_invoice_attempts_clear");
  // the first tab's confirm may be on its way: the intent shows no failed attempt
  db = busy(); pi.status = "requires_confirmation"; pi.last_payment_error = null; pi.latest_charge = null;
  calls.length = 0;
  const r = await pay();
  assertEquals([r.status, r.body.code], [409, "ADDONS_IN_PROGRESS"]);
  assertEquals(clears().length, 0, "nothing is cleared while it may be paying");
  assertEquals(calls.find((c) => c.fn === "zella_owner_invoice_pay_start")?.args.p_submit, true, "the Pay press is marked as such");
  // a payment error with no failed charge to date it: not known when it failed, so nothing is cleared
  db = busy(); pi.status = "requires_payment_method"; pi.last_payment_error = { code: "card_declined" }; pi.latest_charge = null;
  calls.length = 0;
  assertEquals((await pay()).body.code, "ADDONS_IN_PROGRESS");
  assertEquals(clears().length, 0, "no failure time from Stripe: nothing cleared");
  // the first attempt failed at Stripe (a declined charge on the invoice's own intent): cleared up to that moment, then
  // the second tab's Pay goes through with the payment form
  pi.status = "requires_confirmation";
  const failed = fake.confirmIntent(piId, "decline") as Record<string, any>;
  const ch = fake.objects.get(String(failed.latest_charge))!;
  db = { ...busy(), afterClear: invRow(inv) };
  calls.length = 0;
  const ok = await pay();
  assertEquals([ok.status, ok.body.status, String(ok.body.client_secret).split("_secret_")[0]], [200, "open", piId], JSON.stringify(ok.body));
  assertEquals(clears().map((c) => [c.args.p_invoice_id, c.args.p_payment_intent, c.args.p_failed_at]), [[INVOICE, piId, new Date(ch.created * 1000).toISOString()]],
    "the clear names this intent and when its attempt failed");
  assertEquals(calls.filter((c) => c.fn === "zella_owner_invoice_pay_start").length, 2, "asked again once Stripe says the earlier attempt failed");
  // the database cleared nothing (a Pay pressed after that failure, or the invoice is paid): still refused
  db = { ...busy(), cleared: 0, afterClear: invRow(inv) };
  calls.length = 0;
  assertEquals((await pay()).body.code, "ADDONS_IN_PROGRESS");
  assertEquals(calls.filter((c) => c.fn === "zella_owner_invoice_pay_start").length, 1, "not asked again when nothing was cleared");
});

Deno.test("review: the fake Stripe models a 3D Secure challenge, and refuses a redirect method without return_url", async () => {
  const s = await newSession();
  fake.completeCheckout(s.id);
  const sub = fake.objects.get(fake.objects.get(s.id)!.subscription)!;
  const pi = await stripe.post("/v1/payment_intents", { customer: sub.customer, amount: 2900, currency: "usd", off_session: true, confirm: true, metadata: {} }, `pack:${crypto.randomUUID()}`) as Record<string, any>;
  const challenged = fake.confirmIntent(pi.id, "auth") as Record<string, any>;
  assertEquals([challenged.status, challenged.last_payment_error?.code], pi.status === "succeeded" ? ["succeeded", undefined] : ["requires_action", "authentication_required"]);
  const p2 = fake.objects.get((await stripe.post("/v1/payment_intents", { customer: sub.customer, amount: 2900, currency: "usd", metadata: {} }, `pack:${crypto.randomUUID()}`) as Record<string, any>).id)!;
  p2.status = "requires_payment_method";
  assertEquals((fake.confirmIntent(p2.id, "auth") as Record<string, any>).status, "requires_action", "auth is a challenge, not a decline");
  assertEquals((fake.confirmIntent(p2.id, "decline") as Record<string, any>).last_payment_error?.code, "card_declined", "other cards still decline");
  assertEquals((fake.confirmIntent(p2.id) as Record<string, any>).status, "succeeded");
  const price = await stripe.post("/v1/prices", { product: (await stripe.post("/v1/products", { name: "x" }, `product:${crypto.randomUUID()}`)).id, currency: "usd", unit_amount: 100 }, `price:${crypto.randomUUID()}`);
  const refused = await stripe.post("/v1/checkout/sessions", { mode: "payment", ui_mode: "custom", payment_method_types: ["card", "ideal"], line_items: [{ price: price.id, quantity: 1 }] }, `checkout:${crypto.randomUUID()}`).catch((e) => e);
  assert(refused instanceof Error, "iDEAL without return_url is refused");
  const cardOnly = await stripe.post("/v1/checkout/sessions", { mode: "payment", ui_mode: "custom", payment_method_types: ["card"], line_items: [{ price: price.id, quantity: 1 }] }, `checkout:${crypto.randomUUID()}`);
  assertEquals(cardOnly.status, "open", "a card only session needs no return_url");
});

Deno.test("review: customer.updated is fetched from Stripe (a card set on Stripe's card page)", async () => {
  const cus = await stripe.post("/v1/customers", { metadata: { business_id: BIZ } }, `customer:${crypto.randomUUID()}`) as Record<string, any>;
  const got = await fetchEventObject(stripe, { id: "e1", type: "customer.updated", object_type: "customer", object_id: cus.id, livemode: false, payload: null } as never) as Record<string, any>;
  assertEquals([got.id, got.object], [cus.id, "customer"]);
});

Deno.test({ name: "cleanup", sanitizeResources: false, sanitizeOps: false, fn: async () => { globalThis.fetch = realFetch; await fake.stop(); } });
