// A stand in for the owner's payments from inside the CRM, for unit tests and the local browser preview ONLY. billingApi.js
// loads it only when the app is built with VITE_ONBOARDING_FAKE=1, so a production build never contains it. It answers
// in the shapes billing-api and the owner functions give, follows their rules (owner only, paid only after the "server"
// confirms, an invoice is never paid twice), and mounts a static picture of Stripe's form instead of Stripe.js.
// The business, invoices and card are invented; the card is Stripe's public test card.
//
// Scenarios (?scenario=... on /pay):
//   ""         one paid invoice and one open renewal the saved card couldn't pay (past due); Pay now works
//   paid       every invoice is paid: Pay now opens "This invoice is paid"
//   packauth   buying a pack: the bank wants to confirm; finishing it in Stripe's form grants it
//   nocard     no card saved yet: Update card and buying a pack say there's no card to charge
//   off        payments aren't switched on: no Pay now, no buying
//   autopayoff Auto pay is off: invoices are emailed (held while email is off) and paid with Pay now
//   stripefail Stripe's form can't load: the error offers Stripe's secure page as the only fallback
//   canada     as "", with a business address in Canada: Stripe's billing address fields in Canada's format
import { mountStandInCard } from "./standinForm.js";

export const FAKE_BUSINESS = "00000000-0000-4000-8000-0000000000b1";
const OPEN = "00000000-0000-4000-8000-0000000000e2", PAID = "00000000-0000-4000-8000-0000000000e1";
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const refuse = (code, words) => Object.assign(new Error(words ?? code), { code, words });
const day = (d) => new Date(Date.UTC(2026, 10, d)).toISOString();

export function createFakeBillingApi({ scenario = "", delay = 120 } = {}) {
  const live = scenario !== "off";
  const st = {
    invoices: [
      { id: OPEN, number: "ZV-0042", status: scenario === "paid" ? "paid" : "open", total_minor: 24900, amount_due_minor: scenario === "paid" ? 0 : 24900,
        amount_paid_minor: scenario === "paid" ? 24900 : 0, currency: "usd", period_start: day(20), period_end: day(30) + "", hosted_invoice_url: "https://invoice.stripe.example/ZV-0042",
        invoice_pdf: scenario === "paid" ? "https://invoice.stripe.example/ZV-0042.pdf" : null, paid_at: scenario === "paid" ? day(21) : null, created_at: day(20) },
      { id: PAID, number: "ZV-0031", status: "paid", total_minor: 89800, amount_due_minor: 0, amount_paid_minor: 89800, currency: "usd",
        period_start: day(1), period_end: day(20), hosted_invoice_url: "https://invoice.stripe.example/ZV-0031", invoice_pdf: "https://invoice.stripe.example/ZV-0031.pdf",
        paid_at: day(1), created_at: day(1) },
    ],
    looks: 0, purchases: new Map(), cardUpdated: false,
    // Auto pay: what Stripe has (changed only by its event, a moment after the command) and the owner's latest choice
    autopay: { on: scenario !== "autopayoff", desired: null, keys: new Set() },
  };
  const autopayOut = () => ({ on: st.autopay.on, desired: st.autopay.desired ?? st.autopay.on, pending: st.autopay.desired !== null && st.autopay.desired !== st.autopay.on,
    days_until_due: st.autopay.on ? null : 3, current_period_end: day(30), email_live: false, has_card: scenario !== "nocard", subscribed: true, payments_live: live });
  const session = { user: { id: "00000000-0000-4000-8000-0000000000a1", email: "owner@example.test" } };
  const payable = (i) => live && ["open", "payment_failed"].includes(i.status) && i.amount_due_minor > 0;
  const out = (i) => ({ ...i, payable: payable(i) });
  const owner = (id) => { if (id !== FAKE_BUSINESS) throw refuse("NOT_ALLOWED", "Only the business owner can do this."); };
  const find = (id) => { const i = st.invoices.find((x) => x.id === id); if (!i) throw refuse("NOT_FOUND", "We couldn't find that for your account. Check you're signed in as the business owner."); return i; };
  // the fake business's address, to prefill Stripe's billing address fields (any country; prices stay in US dollars)
  const prefill = scenario === "canada" ? { line1: "100 King St W", city: "Toronto", state: "ON", postal_code: "M5H 3T4", country: "CA" }
    : { line1: "214 Maple Street", city: "Springfield", state: "IL", postal_code: "62701", country: "US" };
  const open = (amount) => ({ status: "open", client_secret: "pi_standin_secret_standin", publishable_key: "pk_test_standin", livemode: false, amount_minor: amount, currency: "usd",
    billing_prefill: prefill });
  const CARD = { brand: "visa", last4: "4242", issuer: "Test Bank" };
  const PACKS = [{ code: "minutes_100", resource: "minutes", quantity: 100, price_cents: 2900, rollover_if_unused: 20 },
    { code: "texts_500", resource: "texts", quantity: 500, price_cents: 1500, rollover_if_unused: 0 }];

  const api = {
    getSession: async () => session,
    onAuthChange: () => () => {},
    overview: async (id) => { await wait(delay); owner(id); return {
      plan: { tier: "pro", price_cents: 24900, billing_interval: "monthly", setup_fee_cents: 64900 },
      subscription: { status: scenario === "" || scenario === "canada" ? "past_due" : "active", current_period_end: day(30) }, packs: PACKS, payments_live: live }; },
    invoices: async (id) => { await wait(delay); owner(id); return st.invoices.map(out); },
    autopayStatus: async (id) => { await wait(delay); owner(id); return autopayOut(); },
    autopaySet: async (id, on, key) => {
      await wait(delay); owner(id);
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. Nothing has been charged.");
      if (typeof on !== "boolean" || !/^[A-Za-z0-9_-]{8,100}$/.test(String(key))) throw refuse("INVALID_INPUT");
      if (st.autopay.keys.has(key) || (st.autopay.desired ?? st.autopay.on) === on) return autopayOut();
      if (on && scenario === "nocard") throw refuse("NO_SAVED_CARD", "Add a card in Settings, Billing first.");
      st.autopay.keys.add(key); st.autopay.desired = on;
      // Stripe's customer.subscription.updated, applied by the server a moment later: only then does Auto pay change
      setTimeout(() => { st.autopay.on = on; st.autopay.desired = null; }, delay * 3);
      return autopayOut();
    },
    cardSummary: async (id) => { await wait(delay); owner(id); return scenario === "nocard" ? null : CARD; },
    cardUpdateStart: async (id) => {
      await wait(delay); owner(id);
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. Nothing has been charged.");
      if (scenario === "nocard") throw refuse("NO_CUSTOMER", "Your card is added with your first payment. There's nothing to update yet.");
      // Stripe's Customer Portal is a page of Stripe's; the stand in comes straight back as the portal would
      const back = new URLSearchParams(globalThis.location?.search ?? ""); back.set("business", id); back.set("card", "updated");
      return { url: `/pay?${back}` };
    },
    invoiceStatus: async (invoiceId) => { await wait(delay); return { ...out(find(invoiceId)), invoice_id: invoiceId, business_id: FAKE_BUSINESS, business_name: "Maple Street Salon", payments_live: live }; },
    invoiceStart: async (invoiceId) => {
      await wait(delay);
      const i = find(invoiceId);
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. Nothing has been charged.");
      if (i.status === "paid") throw refuse("ALREADY_PAID", "Your payment is already confirmed.");
      if (st.completed === invoiceId) return { status: "processing" };
      return { ...open(i.amount_due_minor), number: i.number, hosted_invoice_url: i.hosted_invoice_url };
    },
    // the "server" confirms on its second look after Stripe's form completes, as invoice.paid would arrive
    invoiceReturn: async (invoiceId) => {
      await wait(delay);
      const i = find(invoiceId);
      if (st.completed === invoiceId && i.status !== "paid" && ++st.looks >= 2) { i.status = "paid"; i.amount_paid_minor = i.total_minor; i.amount_due_minor = 0; i.paid_at = new Date().toISOString(); }
      const invoice = { ...out(i), invoice_id: invoiceId, business_id: FAKE_BUSINESS };
      return i.status === "paid" && st.completed === invoiceId ? { invoice, card: CARD } : { invoice };
    },
    packBuy: async (id, code, key) => {
      await wait(delay); owner(id);
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. Nothing has been charged.");
      if (scenario === "nocard") throw refuse("NO_SAVED_CARD", "Add a card in Settings, Billing first.");
      const pack = PACKS.find((p) => p.code === code);
      if (!pack) throw refuse("UNKNOWN_PACK", "That pack isn't available.");
      const existing = [...st.purchases.values()].find((p) => p.key === key);
      if (existing) return { purchase_id: existing.purchase_id, status: existing.status };
      const purchase_id = `00000000-0000-4000-8000-${String(st.purchases.size + 1).padStart(12, "0")}`;
      st.purchases.set(purchase_id, { purchase_id, key, pack_code: code, resource: pack.resource, quantity: pack.quantity, price_cents: pack.price_cents,
        status: "pending", looks: 0, outcome: scenario === "packauth" ? "authentication_required" : "ok" });
      return { purchase_id, status: "pending" };
    },
    packStatus: async (id, purchaseId) => {
      await wait(delay); owner(id);
      const p = st.purchases.get(purchaseId);
      if (!p) throw refuse("NOT_FOUND");
      if (p.status === "pending" && ++p.looks >= 2) {
        if (p.outcome === "ok") p.status = "granted";
        else { p.status = "failed"; p.failure_reason = p.outcome; p.can_act = true; }
      }
      const purchase = { ...p };
      return p.status === "granted" ? { purchase, card: CARD } : { purchase };
    },
    packActStart: async (id, purchaseId) => {
      await wait(delay); owner(id);
      const p = st.purchases.get(purchaseId);
      if (!p) throw refuse("NOT_FOUND");
      if (p.status === "granted") throw refuse("ALREADY_PAID");
      if (p.status === "failed") { p.status = "pending"; p.failure_reason = null; p.can_act = false; p.outcome = "ok"; p.looks = 0; p.acted = true; }
      return open(p.price_cents);
    },
    // the stand in for Stripe's card fields (no input elements; demo() plays the test card); submit() is our Pay button
    mountPayment: async (slots, opts) => {
      await wait(delay * 2);
      if (scenario === "stripefail") throw Object.assign(new Error("Stripe.js didn't load"), { code: "STRIPE_JS" });
      if (opts.clientSecret !== "pi_standin_secret_standin") throw Object.assign(new Error("not the stand in's intent"), { code: "STRIPE_JS" });
      return mountStandInCard(slots, opts, { speed: delay ? 45 : 0, onPay: async () => {
        await wait(delay);
        if (opts.invoiceId) { st.completed = opts.invoiceId; st.looks = 0; }
        if (opts.purchaseId) { const p = st.purchases.get(opts.purchaseId); if (p) p.looks = 0; }
      } });
    },
  };
  if (typeof window !== "undefined") window.__zellaBillingFake = api;
  return api;
}
