// The glass checkout (owner, 27 Nov 2026): the state machine's transitions, money and card words, the Stripe.js
// loader (once, js.stripe.com only) and the key mode check. Pure, local: nothing loads Stripe or calls a server.
//   cd web && node --test tests/glassCheckout.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { CONFIRM_DELAYS_MS, ERROR_WORDS, PENDING_EVERY_MS, WORDS, cardWords, failureKind, formatMoney, fromServer, nextDelay, reduce } from "../src/billing/checkoutMachine.js";
import { STRIPE_JS_URL, checkKeyMode, loadStripeJs } from "../src/billing/stripeEmbedded.js";

const DASH = /[—–]|[A-Za-z]-[A-Za-z]/;
const run = (start, ...events) => events.reduce((s, e) => reduce(s, e), start);
const ready = { status: "waiting", reason: "checkout_not_started", checkout_available: true };

test("the server's state is where the machine starts", () => {
  assert.equal(fromServer({ status: "confirmed" }).state, "confirmed");
  assert.equal(fromServer({ status: "locked" }).state, "locked");
  assert.equal(fromServer({ status: "waiting", reason: "processing" }).state, "confirming");
  assert.equal(fromServer(ready).state, "idle");
  assert.equal(fromServer({ status: "waiting", reason: "payments_not_connected", checkout_available: false, required: false }).state, "off");
  assert.equal(fromServer({ status: "waiting", checkout_available: "true" }).state, "off", "only a real true opens the checkout");
  assert.equal(fromServer({ status: "paid" }).state, "off", "an unknown word is never a payment");
  assert.equal(fromServer(null).state, "off");
});

test("the happy path: idle, submitting, loading, ready, confirming, confirmed only from the server", () => {
  let s = fromServer(ready);
  s = reduce(s, { type: "PAY" }); assert.equal(s.state, "submitting");
  assert.equal(reduce(s, { type: "PAY" }), s, "a second press while one is in flight does nothing");
  s = reduce(s, { type: "SECRET" }); assert.equal(s.state, "loading");
  s = reduce(s, { type: "MOUNTED" }); assert.equal(s.state, "ready");
  s = reduce(s, { type: "COMPLETE" }); assert.deepEqual(s, { state: "confirming", attempt: 0 });
  // Stripe saying complete, and the server still saying "open", never confirms and never goes back to idle
  assert.equal(reduce(s, { type: "SERVER", payment: { ...ready, reason: "checkout_open" } }), s);
  s = reduce(s, { type: "SERVER", payment: { status: "confirmed" }, card: { brand: "visa", last4: "4242" } });
  assert.deepEqual(s, { state: "confirmed", card: { brand: "visa", last4: "4242" } });
  assert.equal(reduce(s, { type: "FAIL", kind: "server" }), s, "a failed look never undoes the server's confirmation");
  assert.equal(reduce(s, { type: "SERVER", payment: ready }).state, "idle", "the server's current word is followed both ways: paid only while it says so");
});

test("no event other than the server's answer can reach confirmed", () => {
  const events = ["PAY", "SECRET", "MOUNTED", "COMPLETE", "RETURNED", "STILL_WAITING", "ALREADY_PAID", "PROCESSING", "RETRY"].map((type) => ({ type }));
  for (const start of ["off", "locked", "idle", "submitting", "loading", "ready", "confirming", "pending", "error"]) {
    for (const e of events) assert.notEqual(reduce({ state: start, attempt: 0 }, e)?.state, "confirmed", `${start} + ${e.type}`);
  }
});

test("confirming backs off, then waits calmly; it never fails and never shows success by itself", () => {
  let s = { state: "confirming", attempt: 0 };
  const waits = [];
  while (s.state === "confirming") { waits.push(nextDelay(s)); s = reduce(s, { type: "STILL_WAITING" }); }
  assert.deepEqual(waits, CONFIRM_DELAYS_MS);
  assert.equal(s.state, "pending");
  assert.equal(nextDelay(s), PENDING_EVERY_MS);
  assert.equal(reduce(s, { type: "FAIL", kind: "server" }).state, "pending", "a failed look while pending stays pending");
  assert.equal(reduce({ state: "confirming", attempt: 2 }, { type: "FAIL", kind: "network" }).attempt, 2, "offline while confirming keeps waiting");
  assert.equal(reduce(s, { type: "SERVER", payment: { status: "waiting", reason: "processing" } }), s, "the same answer changes nothing");
  assert.equal(reduce({ state: "confirming", attempt: 3 }, { type: "SERVER", payment: { status: "waiting", reason: "processing" } }).attempt, 3, "a repeated answer never restarts the backoff");
  assert.equal(reduce(s, { type: "SERVER", payment: { status: "confirmed" } }).state, "confirmed");
  assert.equal(nextDelay({ state: "idle" }), null);
});

test("errors have kinds, each with words and a next step; Try again goes back to idle", () => {
  for (const kind of ["expired", "network", "stripe_load", "server", "misconfigured"]) {
    const s = run(fromServer(ready), { type: "PAY" }, { type: "FAIL", kind });
    assert.deepEqual(s, { state: "error", kind });
    assert.ok(ERROR_WORDS[kind].label && ERROR_WORDS[kind].body && ERROR_WORDS[kind].action, kind);
    assert.equal(reduce(s, { type: "RETRY" }).state, "idle");
    assert.equal(reduce(s, { type: "PAY" }).state, "submitting");
  }
  assert.deepEqual(run(fromServer(ready), { type: "PAY" }, { type: "FAIL", kind: "nonsense" }), { state: "error", kind: "server" });
  assert.deepEqual(run(fromServer(ready), { type: "PAY" }, { type: "SECRET" }, { type: "FAIL", kind: "stripe_load" }), { state: "error", kind: "stripe_load" });
});

test("already paid and processing go to confirming (the server then says confirmed); a return confirms through the server", () => {
  assert.equal(run(fromServer(ready), { type: "PAY" }, { type: "ALREADY_PAID" }).state, "confirming");
  assert.equal(run(fromServer(ready), { type: "PAY" }, { type: "PROCESSING" }).state, "confirming");
  assert.equal(reduce({ state: "idle" }, { type: "RETURNED" }).state, "confirming");
  assert.equal(reduce({ state: "confirmed" }, { type: "RETURNED" }).state, "confirmed");
});

test("payments off and locked: the server can switch the screen while no flow is running, never in the middle of one", () => {
  const off = { status: "waiting", reason: "payments_not_connected", checkout_available: false };
  assert.equal(reduce({ state: "idle" }, { type: "SERVER", payment: off }).state, "off");
  assert.equal(reduce({ state: "off" }, { type: "SERVER", payment: ready }).state, "idle");
  assert.equal(reduce({ state: "ready" }, { type: "SERVER", payment: off }).state, "ready");
  assert.equal(reduce({ state: "error", kind: "server" }, { type: "SERVER", payment: ready }).state, "error", "the error stays until the owner acts");
});

test("failures from the server and the network map to kinds", () => {
  assert.equal(failureKind({ code: "CHECKOUT_EXPIRED" }), "expired");
  assert.equal(failureKind({ code: "PAYMENTS_MISCONFIGURED" }), "misconfigured");
  assert.equal(failureKind({ code: "MODE_MISMATCH" }), "misconfigured");
  assert.equal(failureKind({ code: "STRIPE_JS" }), "stripe_load");
  assert.equal(failureKind({ code: "ALREADY_PAID" }), "already_paid");
  assert.equal(failureKind(new TypeError("Failed to fetch")), "network");
  assert.equal(failureKind({ code: "ERROR", message: "boom" }), "server");
});

test("money is shown as the server sent it, in the plan's currency", () => {
  assert.equal(formatMoney(89800, "usd"), "$898");
  assert.equal(formatMoney(89850, "USD"), "$898.50");
  assert.equal(formatMoney(0, "usd"), "$0");
  assert.equal(formatMoney(1000, "eur"), "€10");
  assert.equal(formatMoney(null), "Not set");
  assert.equal(formatMoney("abc"), "Not set");
  assert.equal(formatMoney(500, "not a code"), "$5");
});

test("the card: brand and last 4 only, as Stripe returned them, otherwise nothing", () => {
  assert.deepEqual(cardWords({ brand: "visa", last4: "4242" }), { brand: "Visa", last4: "4242" });
  assert.deepEqual(cardWords({ brand: "amex", last4: "0005" }), { brand: "American Express", last4: "0005" });
  for (const c of [null, {}, { brand: "visa" }, { brand: "visa", last4: "42" }, { brand: "visa", last4: "42424242" }, { brand: "made_up", last4: "4242" }]) assert.equal(cardWords(c), null);
});

test("every word people read: no dashes or hyphens, the brand in full", () => {
  const all = [...Object.values(WORDS), ...Object.values(ERROR_WORDS)].flatMap((w) => [w.label, w.body, w.action].filter(Boolean));
  for (const t of all) {
    assert.ok(!DASH.test(t), t);
    assert.ok(!/\bZella\b(?! Voice)/.test(t), t);
  }
});

test("key mode: a test key with a test server, a live key with a live server; anything else is refused", () => {
  checkKeyMode("pk_test_abc123", false);
  checkKeyMode("pk_live_abc123", true);
  for (const [k, live] of [["pk_live_abc123", false], ["pk_test_abc123", true], ["sk_test_abc123", false], ["", false], ["pk_test_abc123", undefined]]) {
    assert.throws(() => checkKeyMode(k, live), (e) => e.code === "MODE_MISMATCH", `${k} ${live}`);
  }
});

test("Stripe.js: loaded once, from js.stripe.com only (the clover release for our pinned API version)", async () => {
  assert.equal(STRIPE_JS_URL, "https://js.stripe.com/clover/stripe.js");
  const added = [];
  const doc = { head: { appendChild: (el) => { added.push(el); } }, createElement: () => {
    const handlers = {};
    return { addEventListener: (k, f) => { handlers[k] = f; }, remove() {}, fire: (k) => handlers[k]?.() };
  } };
  delete globalThis.Stripe;
  // a blocked or failed load rejects (the screen offers Try again) and leaves nothing behind
  const failed = loadStripeJs(doc);
  assert.equal(added.length, 1);
  assert.equal(added[0].src, STRIPE_JS_URL);
  added[0].fire("error");
  await assert.rejects(failed, (e) => e.code === "STRIPE_JS");
  // Try again loads it afresh, once, however many callers ask at the same time
  const a = loadStripeJs(doc), b = loadStripeJs(doc);
  assert.equal(a, b, "one load at a time");
  assert.equal(added.length, 2);
  assert.equal(added[1].src, STRIPE_JS_URL);
  globalThis.Stripe = () => ({});
  added[1].fire("load");
  assert.equal(await a, globalThis.Stripe);
  assert.equal(await loadStripeJs(doc), globalThis.Stripe, "already there: no second script");
  assert.equal(added.length, 2);
  delete globalThis.Stripe;
});

test("Stripe's PaymentMethod preview: brand, last 4 and expiry only; anything odd is dropped, never guessed", async () => {
  const { previewOf } = await import("../src/billing/stripeEmbedded.js");
  const { brandLabel } = await import("../src/billing/checkoutMachine.js");
  assert.deepEqual(previewOf({ card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2028, fingerprint: "x", funding: "credit" } }), { brand: "visa", last4: "4242", exp: "12/28" });
  assert.deepEqual(previewOf({ card: { brand: "mastercard", last4: "4444", exp_month: 3, exp_year: 2031 } }), { brand: "mastercard", last4: "4444", exp: "03/31" });
  assert.deepEqual(previewOf({ card: { brand: 7, last4: "42424", exp_month: 13, exp_year: 28 } }), { brand: null, last4: null, exp: null });
  assert.deepEqual(previewOf(null), { brand: null, last4: null, exp: null });
  assert.equal(brandLabel("visa"), "Visa");
  assert.equal(brandLabel("unknown"), null, "no mark until Stripe knows the brand");
  assert.equal(brandLabel("<b>"), null);
});

// A fake Stripe.js for mountCardFields: records what our code asks Stripe for. No network, no real card.
function fakeStripeJs() {
  const made = [], pms = [], confirms = [];
  const element = (type, options) => {
    const on = {};
    const el = { type, options, mount: () => {}, destroy: () => {}, on: (ev, fn) => { on[ev] = fn; }, fire: (ev, e) => on[ev]?.(e) };
    made.push(el);
    return el;
  };
  globalThis.Stripe = () => ({
    elements: (o) => ({ appearance: o?.appearance, create: element }),
    initCheckout: async () => ({ loadActions: async () => ({ type: "success", actions: { confirm: async (c) => { confirms.push(c); return { type: "success" }; } } }) }),
    createPaymentMethod: async (p) => { pms.push(p); return { paymentMethod: { id: `pm_${pms.length}`, card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2028 } } }; },
    confirmCardPayment: async (secret, data) => { confirms.push({ secret, ...data }); return { paymentIntent: { status: "succeeded" } }; },
  });
  return { made, pms, confirms, el: (t) => made.find((m) => m.type === t) };
}

test("billing address: Stripe's Address Element in billing mode, any country, the United States first, prefilled from the business", async () => {
  const { addressOptions } = await import("../src/billing/stripeEmbedded.js");
  const o = addressOptions(null);
  assert.equal(o.mode, "billing");
  assert.equal(o.defaultValues.address.country, "US", "the United States by default");
  assert.ok(!("allowedCountries" in o), "no country restriction: cards and addresses from any country");
  assert.equal(o.autocomplete.mode, "automatic");
  const ca = addressOptions({ line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA", extra: "x" });
  assert.deepEqual(ca.defaultValues.address, { country: "CA", line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4" });
  assert.equal(addressOptions({ country: "Canada" }).defaultValues.address.country, "US", "a country that isn't a two letter code isn't guessed");
  const { addressFormat } = await import("../src/billing/standinForm.js");
  assert.deepEqual(addressFormat("US"), { state: "State", postal: "ZIP code" });
  assert.deepEqual(addressFormat("CA"), { state: "Province", postal: "Postal code" });
});

test("the card fields and the billing address: the name reaches the card, the address goes only to Stripe, Pay needs both", async () => {
  const f = fakeStripeJs();
  const { mountCardFields, destroyCurrent } = await import("../src/billing/stripeEmbedded.js");
  const events = [];
  let completed = 0;
  const slots = { number: {}, expiry: {}, cvc: {}, address: {} };
  const h = await mountCardFields(slots, { kind: "intent", clientSecret: "pi_1_secret_x", publishableKey: "pk_test_abc", livemode: false,
    prefill: { country: "CA", city: "Toronto" }, onEvent: (e) => events.push(e), onComplete: () => { completed++; } });
  assert.equal(f.el("address").options.defaultValues.address.country, "CA");
  for (const t of ["cardNumber", "cardExpiry", "cardCvc"]) f.el(t).fire("change", { complete: true, empty: false, brand: "visa" });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(events.find((e) => e.type === "preview").card, { brand: "visa", last4: "4242", exp: "12/28" });
  await assert.rejects(h.submit(), /billing address/, "Pay waits for a complete billing address");
  const addr = { line1: "100 King St W", line2: "", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA" };
  f.el("address").fire("change", { complete: true, value: { name: "Jordan Lee", address: addr } });
  assert.deepEqual(events.at(-1), { type: "address", name: "Jordan Lee", complete: true }, "only the name and whether it's complete reach the page's view");
  await h.submit();
  assert.equal(f.pms.length, 2, "a new PaymentMethod, since the address changed after the preview");
  assert.deepEqual(f.pms[1].billing_details, { name: "Jordan Lee", address: { ...addr, line2: null } });
  assert.equal(f.confirms.at(-1).payment_method, "pm_2");
  assert.equal(completed, 1);
  destroyCurrent();
  delete globalThis.Stripe;
});

test("onboarding (a Checkout Session, ui_mode custom): confirmed with the same PaymentMethod and the billing address", async () => {
  const f = fakeStripeJs();
  const { mountCardFields, destroyCurrent } = await import("../src/billing/stripeEmbedded.js");
  const h = await mountCardFields({ number: {}, expiry: {}, cvc: {}, address: {} }, { kind: "checkout", clientSecret: "cs_test_1_secret_x", publishableKey: "pk_test_abc",
    livemode: false, onEvent: () => {}, onComplete: () => {} });
  f.el("address").fire("change", { complete: true, value: { name: "Jordan Lee", address: { line1: "1 Main St", city: "Austin", state: "TX", postal_code: "78701", country: "US" } } });
  for (const t of ["cardNumber", "cardExpiry", "cardCvc"]) f.el(t).fire("change", { complete: true, empty: false, brand: "visa" });
  await new Promise((r) => setTimeout(r, 0));
  await h.submit();
  assert.equal(f.pms.length, 1, "the preview's PaymentMethod is the one that pays: the address didn't change");
  const c = f.confirms.at(-1);
  assert.equal(c.paymentMethod, "pm_1");
  assert.deepEqual(c.billingAddress, { name: "Jordan Lee", address: { line1: "1 Main St", city: "Austin", state: "TX", postal_code: "78701", country: "US" } });
  destroyCurrent();
  delete globalThis.Stripe;
});
