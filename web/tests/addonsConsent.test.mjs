// Add ons on the Pay pages and the required "I agree" box (owner decisions, 27 Nov 2026), and the round 1 review fixes on
// the page side. Local and pure: the stand ins and a fake Stripe.js, nothing reaches Stripe or a server.
//   cd web && node --test tests/addonsConsent.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { addonKeys, addonName, addonShort, addonStep, addonsTotal, chosen, groupOffer, offerFrom, packConsent, planConsent, selectionKey, toggle } from "../src/billing/addons.js";
import { consentHash, consentMoney, consentText } from "../supabase/functions/_shared/paymentConsent.js";
import { ERROR_KINDS, ERROR_WORDS, reduce } from "../src/billing/checkoutMachine.js";
import { createFakeBillingApi, FAKE_BUSINESS } from "../src/billing/fakeBillingApi.js";
import { createFakeApi } from "../src/onboarding/fakeApi.js";

const DASH = /[—–]|[A-Za-z]-[A-Za-z]/;
const OPEN = "00000000-0000-4000-8000-0000000000e2";
const memory = () => { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }; };
const CATALOG = [{ code: "texts_500", resource: "texts", quantity: 500, price_cents: 1800 }, { code: "minutes_250", resource: "minutes", quantity: 250, price_cents: 8900 },
  { code: "minutes_100", resource: "minutes", quantity: 100, price_cents: 2900 }, { code: "emails_10000", resource: "emails", quantity: 10000, price_cents: 2500 },
  { code: "BAD", resource: "minutes", quantity: 1, price_cents: 1 }, { code: "calls_1", resource: "calls", quantity: 1, price_cents: 100 }, { code: "minutes_9", resource: "minutes", quantity: 9, price_cents: 0 }];

test("the agreement's words: the owner's three wordings, server amounts, add ons one time, no dashes", async () => {
  assert.equal(consentText({ kind: "plan", todayMinor: 27800, autopay: true, renewalMinor: 24900 }),
    "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card $278 today and $249 on each renewal until I cancel.");
  assert.equal(consentText({ kind: "plan", todayMinor: 27800, autopay: false, renewalMinor: 24900 }),
    "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card $278 today. I'll pay future invoices myself.");
  assert.equal(consentText({ kind: "pack", todayMinor: 2900 }), "I agree to the Terms and Privacy Policy and authorize Zella Voice to charge this card $29 today for this add on.");
  assert.match(planConsent({ todayMinor: 27800, autopay: true, renewalMinor: 24900, addons: 1 }), / Add ons are one time and never renew\.$/, "$Y is the plan's price only; add ons never renew");
  assert.equal(planConsent({ todayMinor: 100, autopay: true, renewalMinor: null, addons: 0 }), null, "a missing renewal price: no words, nothing can be agreed");
  assert.equal(packConsent(undefined), null);
  assert.deepEqual([consentMoney(2950), consentMoney(114700), consentMoney(123456789), consentMoney(0), consentMoney(-1), consentMoney(1.5)], ["$29.50", "$1,147", "$1,234,567.89", "$0", null, null]);
  for (const t of [planConsent({ todayMinor: 1, autopay: false, renewalMinor: 1, addons: 2 }), packConsent(1)]) assert.ok(!DASH.test(t), t);
  assert.equal(await consentHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 hex, as the database computes it");
});

test("add ons: the server's catalogue only, grouped minutes, texts, emails; names, totals and toggles", () => {
  const offer = offerFrom(CATALOG);
  assert.deepEqual(offer.map((a) => a.code), ["texts_500", "minutes_250", "minutes_100", "emails_10000"], "anything malformed or unknown is dropped");
  assert.deepEqual(groupOffer(offer).map((g) => [g.title, g.items.map((a) => a.code)]), [["Minutes", ["minutes_100", "minutes_250"]], ["Texts", ["texts_500"]], ["Emails", ["emails_10000"]]]);
  assert.deepEqual([addonName(offer[2]), addonShort(offer[2]), addonName(offer[3])], ["100 AI minutes", "100 minutes", "10,000 emails"]);
  let sel = toggle([], "minutes_100", true); sel = toggle(sel, "texts_500", true); sel = toggle(sel, "minutes_100", true);
  assert.deepEqual(sel, ["minutes_100", "texts_500"]);
  assert.equal(addonsTotal(offer, [...sel, "not_offered"]), 4700, "only packs on offer count, at the server's price");
  assert.deepEqual(chosen(offer, sel).map((a) => a.code), ["texts_500", "minutes_100"]);
  assert.equal(selectionKey(["texts_500", "minutes_100", "texts_500"]), "minutes_100,texts_500");
  assert.deepEqual(toggle(sel, "texts_500", false), ["minutes_100"]);
  assert.equal(offerFrom(null).length, 0);
});

test("add on keys: made when Pay is pressed, kept on retry and reload, a new one only for a newly ticked pack", () => {
  const store = memory();
  const a = addonKeys("zella.addonkeys.x", ["minutes_100"], store);
  const b = addonKeys("zella.addonkeys.x", ["minutes_100", "texts_500"], store);
  assert.equal(b.minutes_100, a.minutes_100, "the same key on retry or reload: the same purchase, never a second charge");
  assert.match(b.texts_500, /^[A-Za-z0-9_-]{8,100}$/);
  assert.notEqual(b.texts_500, b.minutes_100);
  assert.deepEqual(addonKeys("zella.addonkeys.y", ["minutes_100"], null).minutes_100.length > 8, true, "no storage: keys for this page only");
  assert.deepEqual([addonStep({}), addonStep({ purchase_id: "p", status: "pending" }), addonStep({ purchase_id: "p", status: "granted" }), addonStep({ purchase_id: "p", status: "failed" })],
    ["todo", "adding", "added", "failed"]);
});

test("the checkout machine: a changed selection with the form open goes back to Pay; an answer without a status changes nothing (review)", () => {
  assert.deepEqual(reduce({ state: "ready" }, { type: "RESET" }), { state: "idle" });
  assert.deepEqual(reduce({ state: "loading" }, { type: "RESET" }), { state: "idle" });
  const confirming = { state: "confirming", attempt: 2 };
  assert.equal(reduce(confirming, { type: "RESET" }), confirming, "never while Stripe is confirming a payment");
  for (const p of [undefined, null, {}, { status: 5 }]) assert.equal(reduce(confirming, { type: "SERVER", payment: p }), confirming, JSON.stringify(p));
  const ready = { state: "ready" };
  assert.equal(reduce(ready, { type: "SERVER", payment: {} }), ready, "never turned into off");
  assert.ok(ERROR_KINDS.includes("not_taken"));
  assert.deepEqual(reduce({ state: "confirming", attempt: 1 }, { type: "STOPPED", kind: "not_taken" }), { state: "error", kind: "not_taken" }, "a payable invoice with nothing taken: the owner can pay again (review)");
  assert.deepEqual(reduce({ state: "error", kind: "not_taken" }, { type: "RETRY" }), { state: "idle" });
  assert.ok(!DASH.test(Object.values(ERROR_WORDS.not_taken).join(" ")));
});

test("CRM stand in, Pay now with add ons: refused without the agreement; the plan payment first, each add on after with its key", async () => {
  globalThis.sessionStorage = memory();
  const api = createFakeBillingApi({ scenario: "addonfail", delay: 0 });
  const offer = offerFrom(await api.addonCatalog(FAKE_BUSINESS));
  assert.ok(offer.length >= 3);
  const addons = [{ code: "minutes_100", key: "pay-now-key-a1" }, { code: "texts_500", key: "pay-now-key-b1" }];
  const words = planConsent({ todayMinor: 24900 + 2900 + 1800, autopay: true, renewalMinor: 24900, addons: 2 });
  await assert.rejects(api.invoiceStart(OPEN, { addons }), (e) => e.code === "CONSENT_REQUIRED");
  await assert.rejects(api.invoiceStart(OPEN, { addons, consentHash: await consentHash(planConsent({ todayMinor: 24900, autopay: true, renewalMinor: 24900, addons: 0 })) }),
    (e) => e.code === "CONSENT_MISMATCH", "the words without the add ons");
  const hash = await consentHash(words);
  const open = await api.invoiceStart(OPEN, { addons, consentHash: hash, autopay: true });
  assert.equal(open.amount_minor, 24900, "Stripe takes the invoice's own amount; the add ons are separate charges");
  await assert.rejects(api.packBuy(FAKE_BUSINESS, "minutes_100", "pay-now-key-a1", { invoiceId: OPEN, consentHash: hash }), (e) => e.code === "INVOICE_NOT_PAID",
    "never before the plan payment is confirmed");
  // the plan payment: Stripe's form completes, the server confirms on a later look
  const doc = { createElement: () => ({ setAttribute() {}, classList: { remove() {} }, textContent: "" }) };
  const slot = () => ({ ownerDocument: doc, replaceChildren() {} });
  const h = await api.mountPayment({ number: slot(), expiry: slot(), cvc: slot() }, { clientSecret: open.client_secret, invoiceId: OPEN, onEvent: () => {}, onComplete: () => {} });
  await h.demo(); await h.submit();
  await api.invoiceReturn(OPEN);
  assert.equal((await api.invoiceReturn(OPEN)).invoice.status, "paid");
  await assert.rejects(api.packBuy(FAKE_BUSINESS, "minutes_100", "another-key-1", { invoiceId: OPEN, consentHash: hash }), (e) => e.code === "CONSENT_MISMATCH", "a key the agreement didn't name");
  const p1 = await api.packBuy(FAKE_BUSINESS, "minutes_100", "pay-now-key-a1", { invoiceId: OPEN, consentHash: hash });
  const p1again = await api.packBuy(FAKE_BUSINESS, "minutes_100", "pay-now-key-a1", { invoiceId: OPEN, consentHash: hash });
  assert.equal(p1again.purchase_id, p1.purchase_id, "a double click or a retry with the same key: the same purchase");
  // a reload mid way: a new stand in (the page) finds the agreed add ons and their state from the "server"
  const reloaded = createFakeBillingApi({ scenario: "addonfail", delay: 0 });
  const st = await reloaded.invoiceStatus(OPEN);
  assert.equal(st.addons_consent, hash);
  assert.deepEqual(st.addons.map((a) => [a.code, a.key, Boolean(a.purchase_id)]), [["minutes_100", "pay-now-key-a1", true], ["texts_500", "pay-now-key-b1", false]]);
  const p2 = await reloaded.packBuy(FAKE_BUSINESS, "texts_500", "pay-now-key-b1", { invoiceId: OPEN, consentHash: hash });
  await reloaded.packStatus(FAKE_BUSINESS, p2.purchase_id);
  const failed = (await reloaded.packStatus(FAKE_BUSINESS, p2.purchase_id)).purchase;
  assert.deepEqual([failed.status, failed.failure_reason, failed.can_act], ["failed", "card_declined", true], "the texts add on fails after the plan was paid");
  assert.equal((await reloaded.invoiceStatus(OPEN)).status, "paid", "the plan stays paid");
  await assert.rejects(reloaded.invoiceStart(OPEN, { addons, consentHash: hash }), (e) => e.code === "ALREADY_PAID", "the invoice is never charged again");
  assert.equal((await reloaded.packBuy(FAKE_BUSINESS, "texts_500", "pay-now-key-b1", { invoiceId: OPEN, consentHash: hash })).purchase_id, p2.purchase_id, "Try again with the same key: that pack only");
  // the pack page: its own words, at the catalogue's price
  await assert.rejects(reloaded.packBuy(FAKE_BUSINESS, "emails_10000", "pack-page-key-1", { consentHash: await consentHash(packConsent(2900)) }), (e) => e.code === "CONSENT_MISMATCH");
  assert.ok((await reloaded.packBuy(FAKE_BUSINESS, "emails_10000", "pack-page-key-1", { consentHash: await consentHash(packConsent(2500)) })).purchase_id);
  await assert.rejects(reloaded.packActStart(FAKE_BUSINESS, p2.purchase_id, {}), (e) => e.code === "CONSENT_REQUIRED", "finishing a pack needs the agreement too");
  delete globalThis.sessionStorage;
});

test("CRM stand in: a new instance after a reload keeps the completion marker, so the invoice can be confirmed (review)", async () => {
  globalThis.sessionStorage = memory();
  const a = createFakeBillingApi({ scenario: "", delay: 0 });
  const open = await a.invoiceStart(OPEN, { consentHash: await consentHash(planConsent({ todayMinor: 24900, autopay: true, renewalMinor: 24900, addons: 0 })) });
  const doc = { createElement: () => ({ setAttribute() {}, classList: { remove() {} }, textContent: "" }) };
  const slot = () => ({ ownerDocument: doc, replaceChildren() {} });
  const h = await a.mountPayment({ number: slot(), expiry: slot(), cvc: slot() }, { clientSecret: open.client_secret, invoiceId: OPEN, onEvent: () => {}, onComplete: () => {} });
  await h.demo(); await h.submit();
  const b = createFakeBillingApi({ scenario: "", delay: 0 });   // the reload
  assert.equal((await b.invoiceStatus(OPEN)).processing, true);
  await b.invoiceReturn(OPEN);
  assert.equal((await b.invoiceReturn(OPEN)).invoice.status, "paid", "the reloaded page confirms it");
  const c = createFakeBillingApi({ scenario: "", delay: 0 });
  globalThis.sessionStorage = memory();
  const fresh = createFakeBillingApi({ scenario: "", delay: 0 });
  assert.equal((await fresh.invoiceStatus(OPEN)).status, "open", "without the marker an invoice stays unpaid");
  void c;
  delete globalThis.sessionStorage;
});

test("onboarding stand in: the plan and the packs in one checkout; other words refused; a changed selection expires the old session first", async () => {
  const api = createFakeApi({ scenario: "pay", storage: memory(), delay: 0 });
  const id = (await api.listBusinesses()).businesses[0].business_id;
  api.approveIdentity();
  const offer = offerFrom(await api.addonCatalog(id));
  const t1 = planConsent({ todayMinor: 89800 + addonsTotal(offer, ["minutes_100", "texts_500"]), autopay: true, renewalMinor: 24900, addons: 2 });
  await assert.rejects(api.startCheckout(id, "a-good-key-1", { packs: ["minutes_100", "texts_500"], consentHash: await consentHash(planConsent({ todayMinor: 89800, autopay: true, renewalMinor: 24900, addons: 0 })) }),
    (e) => e.code === "CONSENT_MISMATCH");
  const r = await api.startCheckout(id, "a-good-key-1", { packs: ["texts_500", "minutes_100"], consentHash: await consentHash(t1) });
  assert.deepEqual([r.status, r.amount_minor, r.addons], ["open", 94500, ["minutes_100", "texts_500"]], "one payment of $945 for the plan, the setup fee and both packs");
  const t2 = planConsent({ todayMinor: 89800 + 2900, autopay: false, renewalMinor: 24900, addons: 1 });
  const r2 = await api.startCheckout(id, "a-good-key-1", { packs: ["minutes_100"], autopay: false, consentHash: await consentHash(t2) });
  assert.equal(r2.amount_minor, 92700, "the new selection's own amount (the old session expired first)");
});

test("onboarding stand in: a later Auto pay change wins over the checkout's off choice (review)", async () => {
  const api = createFakeApi({ scenario: "pay", storage: memory(), delay: 0 });
  const id = (await api.listBusinesses()).businesses[0].business_id;
  api.approveIdentity();
  await api.startCheckout(id, "a-good-key-1", { autopay: false, consentHash: await consentHash(planConsent({ todayMinor: 89800, autopay: false, renewalMinor: 24900, addons: 0 })) });
  api.confirmPayment();
  assert.equal((await api.autopayStatus(id)).on, false, "the checkout's off choice once paid");
  await api.autopaySet(id, true, "autopay-key-0001");
  assert.equal((await api.autopayStatus(id)).on, true, "the later change wins");
});

test("pay pages keep the workspace: the business goes with the address, the stand in scenario too (review)", async () => {
  const { payPageAddress } = await import("../src/billing/payRedirect.js");
  assert.equal(payPageAddress("/app/settings/billing/pay/x", FAKE_BUSINESS, "?scenario=paid&x=1"), `/app/settings/billing/pay/x?business=${FAKE_BUSINESS}&scenario=paid`);
  assert.equal(payPageAddress("/app/settings/billing/pack/minutes_100", "not-an-id", ""), "/app/settings/billing/pack/minutes_100");
});

test("the emailed Pay now link names the business too (review)", async () => {
  const { renderEmail } = await import("../src/emails/businessEmails.js");
  const inv = "11111111-2222-4333-8444-555555555555", biz = "00000000-0000-4000-8000-0000000000b1";
  assert.ok(renderEmail("D1", { invoiceId: inv, businessId: biz }).html.includes(`/pay/invoice/${inv}?business=${biz}`));
  assert.ok(renderEmail("D1", { invoiceId: inv }).html.includes(`/pay/invoice/${inv}`));
});

test("card fields: every change drops the earlier preview and makes a new one when complete; a stale preview is ignored (review)", async () => {
  const made = [], pms = [];
  let release;
  const element = (type, options) => { const on = {}; const el = { type, options, mount: () => {}, destroy: () => {}, on: (ev, fn) => { on[ev] = fn; }, fire: (ev, e) => on[ev]?.(e) }; made.push(el); return el; };
  globalThis.Stripe = () => ({ elements: () => ({ create: element }),
    createPaymentMethod: async (p) => { pms.push(p); const n = pms.length; if (n === 1) await new Promise((r) => { release = r; }); return { paymentMethod: { id: `pm_${n}`, card: { brand: "visa", last4: n === 1 ? "1111" : "4242", exp_month: 12, exp_year: 2028 } } }; },
    confirmCardPayment: async () => ({ paymentIntent: { status: "succeeded" } }) });
  const { mountCardFields, destroyCurrent } = await import("../src/billing/stripeEmbedded.js");
  const events = [];
  await mountCardFields({ number: {}, expiry: {}, cvc: {} }, { kind: "intent", clientSecret: "pi_1_secret_x", publishableKey: "pk_test_abc", livemode: false, onEvent: (e) => events.push(e), onComplete: () => {} });
  const el = (t) => made.find((m) => m.type === t);
  for (const t of ["cardNumber", "cardExpiry", "cardCvc"]) el(t).fire("change", { complete: true, empty: false, brand: "visa" });
  // a digit changes in a number that stays complete, while the first preview is still on its way
  el("cardNumber").fire("change", { complete: true, empty: false, brand: "visa" });
  await new Promise((r) => setTimeout(r, 0));
  release();
  await new Promise((r) => setTimeout(r, 0));
  const previews = events.filter((e) => e.type === "preview" && e.card).map((e) => e.card.last4);
  assert.deepEqual(previews, ["4242"], "only the latest value's preview reaches the card; the stale one is dropped");
  assert.equal(pms.length, 2, "a new PaymentMethod for the changed value");
  destroyCurrent();
  delete globalThis.Stripe;
});
