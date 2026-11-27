// Paying from inside the CRM (owner decision, 27 Nov 2026: "auto charge plus Pay now"): the new state paths of the glass
// checkout, the invoice and pack answers, the card's issuer as plain text, and the billing stand in's rules. Local and
// pure: nothing loads Stripe or calls a server.
//   cd web && node --test tests/crmPayments.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { ERROR_WORDS, cardWords, failureKind, fromServer, reduce } from "../src/billing/checkoutMachine.js";
import { invoiceAsPayment, packAnswer } from "../src/billing/payState.js";
import { createFakeBillingApi, FAKE_BUSINESS } from "../src/billing/fakeBillingApi.js";
import { consentHash, consentText } from "../supabase/functions/_shared/paymentConsent.js";

// the owner's agreement as the page sends it: the sha256 of the words for these figures
const agree = async (f) => ({ consentHash: await consentHash(consentText(f)) });
const PLAN = (today, extra = {}) => agree({ kind: "plan", todayMinor: today, autopay: true, renewalMinor: 24900, ...extra });
const PACK = (price) => agree({ kind: "pack", todayMinor: price });

const DASH = /[—–]|[A-Za-z]-[A-Za-z]/;
const OPEN = "00000000-0000-4000-8000-0000000000e2", PAID = "00000000-0000-4000-8000-0000000000e1";

test("an invoice is paid on screen only when OUR record says paid", () => {
  assert.equal(fromServer(invoiceAsPayment({ status: "paid" })).state, "confirmed");
  assert.equal(fromServer(invoiceAsPayment({ status: "open", payable: true })).state, "idle");
  assert.equal(fromServer(invoiceAsPayment({ status: "open", payable: false })).state, "off", "payments off: no Pay now");
  assert.equal(fromServer(invoiceAsPayment({ status: "void", payable: false })).state, "off");
  assert.equal(fromServer(invoiceAsPayment({ status: "open", payable: "true" })).state, "off", "only a real true");
  assert.equal(fromServer(invoiceAsPayment(null)).state, "off");
});

test("a pack: granted is the only confirmed; a failure the owner can finish stops the wait with its kind", () => {
  assert.equal(fromServer(packAnswer({ status: "granted" }).payment).state, "confirmed");
  assert.equal(fromServer(packAnswer({ status: "pending" }).payment).state, "confirming");
  assert.equal(packAnswer({ status: "failed", can_act: true, failure_reason: "authentication_required" }).stopped, "needs_action");
  assert.equal(packAnswer({ status: "failed", can_act: true, failure_reason: "card_declined" }).stopped, "card_declined");
  assert.equal(packAnswer({ status: "failed", can_act: false, failure_reason: "refused" }).stopped, "no_card");
  assert.equal(packAnswer({ status: "failed", can_act: true }).payment.status, "waiting", "never confirmed");
});

test("STOPPED ends a confirming wait with an error kind, never with paid; an action starts over", () => {
  let s = { state: "confirming", attempt: 3 };
  s = reduce(s, { type: "STOPPED", kind: "needs_action" });
  assert.deepEqual(s, { state: "error", kind: "needs_action" });
  assert.equal(reduce(s, { type: "PAY" }).state, "submitting", "Confirm with your bank starts the same flow again");
  assert.equal(reduce({ state: "confirmed" }, { type: "STOPPED", kind: "no_card" }).state, "confirmed");
  assert.deepEqual(reduce({ state: "pending" }, { type: "STOPPED", kind: "nonsense" }), { state: "error", kind: "server" });
  for (const st of ["idle", "submitting", "loading", "ready", "confirming", "pending", "error"]) assert.notEqual(reduce({ state: st }, { type: "STOPPED", kind: "card_declined" }).state, "confirmed");
});

test("the server's refusals map to kinds, with its own words kept for a plain refusal", () => {
  assert.equal(failureKind({ code: "NOT_FOUND" }), "not_found");
  assert.equal(failureKind({ code: "NOT_PAYABLE" }), "not_payable");
  assert.equal(failureKind({ code: "NO_CUSTOMER" }), "no_card");
  assert.equal(failureKind({ code: "NO_SAVED_CARD" }), "no_card");
  assert.equal(failureKind({ code: "NO_ACTIVE_PLAN" }), "refused");
  const s = reduce({ state: "submitting" }, { type: "FAIL", kind: "refused", words: "Packs can be bought once your plan is active." });
  assert.deepEqual(s, { state: "error", kind: "refused", words: "Packs can be bought once your plan is active." });
  for (const k of ["needs_action", "card_declined", "no_card", "not_payable", "not_found", "refused"]) {
    assert.ok(ERROR_WORDS[k]?.label && ERROR_WORDS[k]?.body, k);
    for (const t of [ERROR_WORDS[k].label, ERROR_WORDS[k].body, ERROR_WORDS[k].action].filter(Boolean)) assert.ok(!DASH.test(t), t);
  }
});

test("the card's issuing bank: shown only as the server passed it on, plain text, trimmed and capped; nothing when null", () => {
  assert.deepEqual(cardWords({ brand: "visa", last4: "4242", issuer: "  Test Bank " }), { brand: "Visa", last4: "4242", issuer: "Test Bank" });
  assert.deepEqual(cardWords({ brand: "visa", last4: "4242", issuer: null }), { brand: "Visa", last4: "4242" });
  assert.deepEqual(cardWords({ brand: "visa", last4: "4242" }), { brand: "Visa", last4: "4242" });
  assert.equal(cardWords({ brand: "visa", last4: "4242", issuer: "B".repeat(90) }).issuer.length, 40);
  // text, never markup: the string stays as it is (React escapes it on screen) and control characters go
  assert.equal(cardWords({ brand: "visa", last4: "4242", issuer: "<img src=x onerror=alert(1)>\u0000Bank" }).issuer, "<img src=x onerror=alert(1)>Bank");
  assert.equal(cardWords({ brand: "visa", last4: "4242", issuer: 42 }).issuer, undefined);
});

test("stand in: owner only, Pay now confirms only on the server's later look, a paid invoice is refused", async () => {
  const api = createFakeBillingApi({ scenario: "", delay: 0 });
  await assert.rejects(api.invoices("someone-else"), (e) => e.code === "NOT_ALLOWED");
  const list = await api.invoices(FAKE_BUSINESS);
  assert.deepEqual(list.map((i) => [i.number, i.status, i.payable]), [["ZV-0042", "open", true], ["ZV-0031", "paid", false]]);
  await assert.rejects(api.invoiceStart(PAID), (e) => e.code === "ALREADY_PAID");
  await assert.rejects(api.invoiceStatus("00000000-0000-4000-8000-00000000ffff"), (e) => e.code === "NOT_FOUND");
  const a = await api.invoiceStart(OPEN, await PLAN(24900)), b = await api.invoiceStart(OPEN, await PLAN(24900));
  assert.equal(a.client_secret, b.client_secret, "a double start: the same intent");
  assert.equal(a.amount_minor, 24900);
  assert.equal((await api.invoiceReturn(OPEN)).invoice.status, "open", "nothing happened yet");
  let done = false;
  const doc = { createElement: () => ({ setAttribute() {}, classList: { remove() {} }, textContent: "" }) };
  const slot = () => ({ ownerDocument: doc, replaceChildren() {} });
  const slots = { number: slot(), expiry: slot(), cvc: slot() };
  const events = [];
  const h = await api.mountPayment(slots, { clientSecret: a.client_secret, invoiceId: OPEN, onEvent: (e) => events.push(e), onComplete: () => { done = true; } });
  await assert.rejects(h.submit(), (e) => e.code === "LOCAL_CHECK", "nothing to pay with before the fields are complete");
  await h.demo();
  // the events Stripe's fields would send: the brand while typing, the card turned over for the security code, then the preview
  assert.ok(events.some((e) => e.type === "change" && e.field === "number" && e.brand === "visa"));
  assert.ok(events.some((e) => e.type === "focus" && e.field === "cvc"));
  assert.deepEqual(events.at(-1), { type: "preview", card: { brand: "visa", last4: "4242", exp: "12/28" } });
  assert.ok(!JSON.stringify(events).match(/\d{5,}|4242 4242/), "no event ever carries more than the last 4");
  await h.submit();
  assert.ok(done);
  assert.deepEqual(await api.invoiceStart(OPEN, await PLAN(24900)), { status: "processing" }, "Stripe has it: no second form");
  assert.equal((await api.invoiceReturn(OPEN)).invoice.status, "open", "the first look after paying: not yet");
  const paid = await api.invoiceReturn(OPEN);
  assert.equal(paid.invoice.status, "paid");
  assert.deepEqual(paid.card, { brand: "visa", last4: "4242", issuer: "Test Bank" });
  await assert.rejects(api.invoiceStart(OPEN), (e) => e.code === "ALREADY_PAID", "never paid twice");
});

test("stand in: a pack the bank wants to confirm is finished on the same intent; no card and payments off refuse", async () => {
  const api = createFakeBillingApi({ scenario: "packauth", delay: 0 });
  const r1 = await api.packBuy(FAKE_BUSINESS, "minutes_100", "pack-key-0001", await PACK(2900)), r2 = await api.packBuy(FAKE_BUSINESS, "minutes_100", "pack-key-0001", await PACK(2900));
  assert.equal(r1.purchase_id, r2.purchase_id, "the same key: the same purchase");
  assert.equal((await api.packStatus(FAKE_BUSINESS, r1.purchase_id)).purchase.status, "pending");
  const failed = (await api.packStatus(FAKE_BUSINESS, r1.purchase_id)).purchase;
  assert.equal(packAnswer(failed).stopped, "needs_action");
  const act = await api.packActStart(FAKE_BUSINESS, r1.purchase_id, await PACK(2900));
  assert.equal(act.amount_minor, 2900);
  await api.packStatus(FAKE_BUSINESS, r1.purchase_id);
  const done = await api.packStatus(FAKE_BUSINESS, r1.purchase_id);
  assert.equal(done.purchase.status, "granted");
  await assert.rejects(api.packActStart(FAKE_BUSINESS, r1.purchase_id), (e) => e.code === "ALREADY_PAID");
  const none = createFakeBillingApi({ scenario: "nocard", delay: 0 });
  await assert.rejects(none.packBuy(FAKE_BUSINESS, "minutes_100", "pack-key-0002", await PACK(2900)), (e) => failureKind(e) === "no_card");
  await assert.rejects(none.cardUpdateStart(FAKE_BUSINESS, "card-key-0001"), (e) => failureKind(e) === "no_card");
  assert.equal(await none.cardSummary(FAKE_BUSINESS), null);
  const off = createFakeBillingApi({ scenario: "off", delay: 0 });
  assert.ok((await off.invoices(FAKE_BUSINESS)).every((i) => i.payable === false));
  await assert.rejects(off.packBuy(FAKE_BUSINESS, "minutes_100", "pack-key-0003", await PACK(2900)), (e) => e.code === "PAYMENTS_NOT_LIVE");
});

test("billing emails: Pay now opens the invoice's own page when the data names it, else the business's Payments page", async () => {
  const { renderEmail } = await import("../src/emails/businessEmails.js");
  const inv = "11111111-2222-4333-8444-555555555555", biz = "00000000-0000-4000-8000-0000000000b1";
  assert.ok(renderEmail("D1", { invoiceId: inv, businessId: biz }).html.includes(`/pay/invoice/${inv}`));
  const byBiz = renderEmail("D1", { businessId: biz }).html;
  assert.ok(byBiz.includes(`/pay?business=${biz}`) && !byBiz.includes("/settings/billing"), "Update card goes to the Payments page too");
  assert.ok(!renderEmail("D1", { invoiceId: "<script>", businessId: "x" }).html.includes("<script>"), "only real ids make it into a link");
});

test("Auto pay words: honest about email while billing emails are held, no dashes", async () => {
  const { autopayWords } = await import("../src/billing/payState.js");
  const held = autopayWords(false), live = autopayWords(true, "your saved card");
  assert.equal(held.onText, "Stripe charges this card on each renewal date.");
  assert.match(held.offText, /in the CRM/);
  assert.doesNotMatch(held.offText, /email/i, "no promise of an email while email is off");
  assert.equal(live.offText, "We'll email your invoice; pay it within 3 days in the CRM.");
  assert.equal(live.onText, "Stripe charges your saved card on each renewal date.");
  for (const w of [held.onText, held.offText, live.offText]) assert.doesNotMatch(w, DASH);
});

test("stand in Auto pay: owner only, on by default, a double submit changes nothing, Stripe's event (a moment later) changes it, no card refuses on", async () => {
  const api = createFakeBillingApi({ delay: 1 });
  assert.equal((await api.autopayStatus(FAKE_BUSINESS)).on, true);
  await assert.rejects(api.autopaySet("00000000-0000-4000-8000-00000000ffff", false, "autopay-key-1"), { code: "NOT_ALLOWED" });
  const a = await api.autopaySet(FAKE_BUSINESS, false, "autopay-key-1");
  assert.deepEqual([a.on, a.desired, a.pending], [true, false, true], "still on until Stripe's event");
  const b = await api.autopaySet(FAKE_BUSINESS, false, "autopay-key-1");
  assert.equal(b.pending, true);
  await new Promise((r) => setTimeout(r, 20));
  const c = await api.autopayStatus(FAKE_BUSINESS);
  assert.deepEqual([c.on, c.pending, c.days_until_due], [false, false, 3]);
  const nocard = createFakeBillingApi({ scenario: "nocard", delay: 1 });
  await nocard.autopaySet(FAKE_BUSINESS, false, "autopay-key-2");
  await new Promise((r) => setTimeout(r, 20));
  await assert.rejects(nocard.autopaySet(FAKE_BUSINESS, true, "autopay-key-3"), { code: "NO_SAVED_CARD" });
  await assert.rejects(api.autopaySet(FAKE_BUSINESS, "yes", "autopay-key-4"), { code: "INVALID_INPUT" });
});

test("the old /pay addresses redirect into the CRM's own payment pages, keeping only the stand in scenario and the card flag", async () => {
  const { payRedirect } = await import("../src/billing/payRedirect.js");
  assert.equal(payRedirect(`/pay/invoice/${OPEN}`, ""), `/app/settings/billing/pay/${OPEN}`);
  assert.equal(payRedirect(`/pay/invoice/${OPEN}/`, "?scenario=paid&x=1"), `/app/settings/billing/pay/${OPEN}?scenario=paid`);
  // the business goes through the redirect (an owner of several opens the right workspace; the server still checks the owner)
  assert.equal(payRedirect("/pay", `?business=${FAKE_BUSINESS}&card=updated`), `/app/settings/billing/invoices?card=updated&business=${FAKE_BUSINESS}`);
  assert.equal(payRedirect(`/pay/invoice/${OPEN}`, `?business=${FAKE_BUSINESS}`), `/app/settings/billing/pay/${OPEN}?business=${FAKE_BUSINESS}`);
  assert.equal(payRedirect(`/pay/invoice/${OPEN}`, "?business=not-a-business"), `/app/settings/billing/pay/${OPEN}`, "only a real business id");
  // a malformed escape: the invoices page, never a page stuck loading (review)
  assert.equal(payRedirect("/pay/invoice/%E0%A4%A", ""), "/app/settings/billing/invoices");
  assert.equal(payRedirect("/pay/invoice/a%2Fb", ""), "/app/settings/billing/pay/a%2Fb", "an odd id stays one path part (the page refuses it)");
});
