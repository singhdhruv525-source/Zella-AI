// A stand in for the owner's payments from inside the CRM, for unit tests and the local browser preview ONLY. billingApi.js
// loads it only when the app is built with VITE_ONBOARDING_FAKE=1, so a production build never contains it. It answers
// in the shapes billing-api and the owner functions give, follows their rules (owner only, paid only after the "server"
// confirms, an invoice is never paid twice), and mounts a static picture of Stripe's form instead of Stripe.js.
// The business, invoices and card are invented; the card is Stripe's public test card.
//
// Scenarios (?scenario=... on /app/settings/billing/invoices; the CRM keeps the stand in chosen on the first page):
//   ""         one paid invoice and one open renewal the saved card couldn't pay (past due); Pay now works
//   paid       every invoice is paid: Pay now opens "This invoice is paid"
//   packauth   buying a pack: the bank wants to confirm; finishing it in Stripe's form grants it
//   nocard     no card saved yet: Update card and buying a pack say there's no card to charge
//   off        payments aren't switched on: no Pay now, no buying
//   autopayoff Auto pay is off: invoices are emailed (held while email is off) and paid with Pay now
//   stripefail Stripe's form can't load: the error offers Stripe's secure page as the only fallback
//   canada     as "", with a business address in Canada: Stripe's billing address fields in Canada's format
//   addonfail  as "": the texts add on bought after the plan payment is declined ("Plan paid. 500 texts not added")
//   declined, insufficient, cvc, lost: Pay now's first card is declined at payment (Stripe's decline code generic_decline,
//              insufficient_funds, incorrect_cvc, lost_card shown as generic); another card then pays
//   bankverify the bank's own check (a labelled preview: Approve, Fail or Close); demo: declined, then the bank's check
//   unknown    Stripe doesn't answer the confirm: the page checks with the server and says the payment wasn't taken
//   packdeclined buying a pack: the saved card is declined for insufficient funds
// Like the server, every payment start checks the owner's agreement: the sha256 of the words for the stand in's own
// figures (paymentConsent.js), refused without it (CONSENT_REQUIRED) or with other words (CONSENT_MISMATCH).
import { mountStandInCard } from "./standinForm.js";
import { consentHash, consentText } from "../../supabase/functions/_shared/paymentConsent.js";

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
    looks: 0, purchases: new Map(), cardUpdated: false, consents: [], invoiceAddons: new Map(),
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
    { code: "minutes_250", resource: "minutes", quantity: 250, price_cents: 8900, rollover_if_unused: 50 },
    { code: "texts_500", resource: "texts", quantity: 500, price_cents: 1800, rollover_if_unused: 0 },
    { code: "emails_10000", resource: "emails", quantity: 10000, price_cents: 2500, rollover_if_unused: 0 }];
  const RENEWAL = 24900;
  // the agreement, as the server checks it: the words rebuilt from these figures, their sha256 compared
  async function agreed(hash, figures) {
    if (!/^[0-9a-f]{64}$/.test(String(hash ?? ""))) throw refuse("CONSENT_REQUIRED", "Please tick the box to continue.");
    const text = consentText(figures);
    if (!text || (await consentHash(text)) !== hash) throw refuse("CONSENT_MISMATCH", "The total changed. Please tick the box again.");
    st.consents.push({ text, hash });
  }
  // an invoice Stripe already took in this tab or an earlier one (sessionStorage survives a reload; review)
  const completed = (invoiceId) => st.completed === invoiceId || globalThis.sessionStorage?.getItem(`zella.fake.paid.${invoiceId}`) === "1";
  const addonsOf = (invoiceId) => (st.invoiceAddons.get(invoiceId)?.addons ?? []).map((a) => {
    const p = [...st.purchases.values()].find((x) => x.key === a.key);
    return { ...a, purchase_id: p?.purchase_id ?? null, status: p?.status ?? null, failure_reason: p?.failure_reason ?? null, can_act: Boolean(p?.can_act) };
  });

  // the purchases and the add ons agreed with Pay now survive a reload, as the server's records do (sessionStorage)
  const SAVE = "zella.fake.billing.v1";
  try {
    const kept = JSON.parse(globalThis.sessionStorage?.getItem(SAVE) ?? "null");
    if (kept) {
      st.purchases = new Map(kept.purchases ?? []); st.invoiceAddons = new Map(kept.invoiceAddons ?? []);
      for (const id of kept.paid ?? []) { const i = st.invoices.find((x) => x.id === id); if (i && i.status !== "paid") { i.status = "paid"; i.amount_paid_minor = i.total_minor; i.amount_due_minor = 0; i.paid_at = kept.paidAt?.[id] ?? null; } }
    }
  } catch { /* nothing kept */ }
  const persist = () => { try { globalThis.sessionStorage?.setItem(SAVE, JSON.stringify({ purchases: [...st.purchases], invoiceAddons: [...st.invoiceAddons],
    paid: st.invoices.filter((i) => i.status === "paid" && completed(i.id)).map((i) => i.id), paidAt: Object.fromEntries(st.invoices.map((i) => [i.id, i.paid_at])) })); } catch { /* none */ } };
  function markPaid(i) { i.status = "paid"; i.amount_paid_minor = i.total_minor; i.amount_due_minor = 0; i.paid_at = new Date().toISOString(); persist(); }
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
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. You weren't charged.");
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
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. You weren't charged.");
      if (scenario === "nocard") throw refuse("NO_CUSTOMER", "Your card is added with your first payment. There's nothing to update yet.");
      // Stripe's Customer Portal is a page of Stripe's; the stand in comes straight back as the portal would
      const back = new URLSearchParams(); back.set("scenario", scenario); back.set("card", "updated");
      return { url: `/app/settings/billing/invoices?${back}` };
    },
    addonCatalog: async (id) => { await wait(delay); owner(id); return PACKS.map(({ code, resource, quantity, price_cents }) => ({ code, resource, quantity, price_cents, currency: "usd" })); },
    invoiceStatus: async (invoiceId) => { await wait(delay); const i = find(invoiceId);
      // as billing-api asks Stripe: a payment it already has shows as processing (the marker survives a reload in sessionStorage)
      if (completed(invoiceId) && i.status !== "paid" && st.looks >= 2) markPaid(i);
      const processing = i.status !== "paid" && completed(invoiceId);
      return { ...out(i), ...(processing ? { processing: true } : {}), invoice_id: invoiceId, business_id: FAKE_BUSINESS, business_name: "Maple Street Salon", payments_live: live,
        renewal_minor: RENEWAL, addons: addonsOf(invoiceId), addons_consent: st.invoiceAddons.get(invoiceId)?.hash ?? null }; },
    invoiceStart: async (invoiceId, opts) => {
      await wait(delay);
      const i = find(invoiceId);
      // the Auto pay choice made with Pay now, applied as the server would at the start (Stripe's event a moment later)
      if (opts && typeof opts.autopay === "boolean" && live) {
        if (opts.autopay && scenario === "nocard") { /* turning it on needs a saved card: the payment still opens */ }
        else { st.autopay.desired = opts.autopay; setTimeout(() => { st.autopay.on = opts.autopay; st.autopay.desired = null; }, delay * 3); }
      }
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. You weren't charged.");
      if (i.status === "paid") throw refuse("ALREADY_PAID", "Your payment is already confirmed.");
      const addons = (opts?.addons ?? []).map((a) => ({ ...a, ...PACKS.find((p) => p.code === a.code) }));
      if (addons.some((a) => !a.price_cents || !/^[A-Za-z0-9_-]{8,100}$/.test(String(a.key)))) throw refuse("INVALID_INPUT", "That didn't work. Reload the page and try again.");
      const sum = addons.reduce((t, a) => t + a.price_cents, 0);
      await agreed(opts?.consentHash, { kind: "invoice", todayMinor: i.amount_due_minor, addonsMinor: sum, autopay: opts?.autopay !== false, renewalMinor: RENEWAL });
      // one submitted agreement at a time (the Pay press): another tab's with other add ons is refused while it may be paying
      const prev = st.invoiceAddons.get(invoiceId);
      const codes = (list) => list.map((a) => a.code).sort().join(",");
      if (opts.submit && prev?.submitted && prev.hash !== opts.consentHash && codes(prev.addons) !== codes(addons)) {
        throw refuse("ADDONS_IN_PROGRESS", "Another payment for this bill is in progress. Wait a moment, then reload this page.");
      }
      if (prev?.submitted && !opts.submit) { /* the submitted agreement stays the one bought */ }
      else st.invoiceAddons.set(invoiceId, { hash: opts.consentHash, submitted: Boolean(opts.submit), addons: addons.map(({ code, key, resource, quantity, price_cents }) => ({ code, key, resource, quantity, price_cents })) });
      persist();
      if (completed(invoiceId)) return { status: "processing" };
      return { ...open(i.amount_due_minor), number: i.number, hosted_invoice_url: i.hosted_invoice_url, addons };
    },
    // the "server" confirms on its second look after Stripe's form completes, as invoice.paid would arrive
    // the "server" confirms on its second look after Stripe's form completes, as invoice.paid would arrive; a new stand in
    // (a reload) finds the same marker in sessionStorage and carries on (review)
    invoiceReturn: async (invoiceId) => {
      await wait(delay);
      const i = find(invoiceId);
      if (completed(invoiceId) && i.status !== "paid" && ++st.looks >= 2) markPaid(i);
      const invoice = { ...out(i), invoice_id: invoiceId, business_id: FAKE_BUSINESS, ...(i.status !== "paid" && completed(invoiceId) ? { processing: true } : {}) };
      return i.status === "paid" && completed(invoiceId) ? { invoice, card: CARD } : { invoice };
    },
    packBuy: async (id, code, key, opts = {}) => {
      await wait(delay); owner(id);
      if (!live) throw refuse("PAYMENTS_NOT_LIVE", "Payments aren't switched on yet. You weren't charged.");
      if (scenario === "nocard") throw refuse("NO_SAVED_CARD", "Add a card in Settings, Billing first.");
      const pack = PACKS.find((p) => p.code === code);
      if (!pack) throw refuse("UNKNOWN_PACK", "That pack isn't available.");
      if (opts.invoiceId) {
        // an add on agreed with Pay now: only once that invoice is paid, and only as that agreement named it
        const agreedWith = st.invoiceAddons.get(opts.invoiceId);
        if (find(opts.invoiceId).status !== "paid") throw refuse("INVOICE_NOT_PAID", "Add ons are charged once your plan payment is confirmed. You weren't charged for them yet.");
        if (!agreedWith || agreedWith.hash !== opts.consentHash || !agreedWith.addons.some((a) => a.code === code && a.key === key)) throw refuse("CONSENT_MISMATCH");
      } else {
        await agreed(opts.consentHash, { kind: "pack", todayMinor: pack.price_cents });
      }
      const existing = [...st.purchases.values()].find((p) => p.key === key);
      if (existing) return { purchase_id: existing.purchase_id, status: existing.status };
      const purchase_id = `00000000-0000-4000-8000-${String(st.purchases.size + 1).padStart(12, "0")}`;
      st.purchases.set(purchase_id, { purchase_id, key, pack_code: code, resource: pack.resource, quantity: pack.quantity, price_cents: pack.price_cents,
        status: "pending", looks: 0, outcome: scenario === "packauth" ? "authentication_required" : scenario === "packdeclined" ? "insufficient_funds" : scenario === "addonfail" && code.startsWith("texts") ? "card_declined" : "ok" });
      st.buys = (st.buys ?? 0) + 1;
      persist();
      return { purchase_id, status: "pending" };
    },
    packStatus: async (id, purchaseId) => {
      await wait(delay); owner(id);
      const p = st.purchases.get(purchaseId);
      if (!p) throw refuse("NOT_FOUND");
      if (p.status === "pending" && ++p.looks >= 2) {
        if (p.outcome === "ok") p.status = "granted";
        else { p.status = "failed"; p.failure_reason = p.outcome; p.can_act = true; }
        persist();
      }
      const purchase = { ...p };
      return p.status === "granted" ? { purchase, card: CARD } : { purchase };
    },
    packActStart: async (id, purchaseId, opts = {}) => {
      await wait(delay); owner(id);
      const p = st.purchases.get(purchaseId);
      if (!p) throw refuse("NOT_FOUND");
      if (p.status === "granted") throw refuse("ALREADY_PAID");
      await agreed(opts.consentHash, { kind: "pack", todayMinor: p.price_cents });
      if (p.status === "failed") { p.status = "pending"; p.failure_reason = null; p.can_act = false; p.outcome = "ok"; p.looks = 0; p.acted = true; }
      return open(p.price_cents);
    },
    // the stand in for Stripe's card fields (no input elements; demo() plays the test card); submit() is our Pay button
    mountPayment: async (slots, opts) => {
      await wait(delay * 2);
      if (scenario === "stripefail") throw Object.assign(new Error("Stripe.js didn't load"), { code: "STRIPE_JS" });
      if (opts.clientSecret !== "pi_standin_secret_standin") throw Object.assign(new Error("not the stand in's intent"), { code: "STRIPE_JS" });
      const outcomes = { declined: ["declined:generic_decline", "ok"], insufficient: ["declined:insufficient_funds", "ok"], cvc: ["declined:incorrect_cvc", "ok"],
        lost: ["declined:lost_card", "ok"], bankverify: ["verify"], demo: ["declined:generic_decline", "verify"], unknown: ["unknown", "ok"] }[scenario] ?? ["ok"];
      return mountStandInCard(slots, opts, { speed: delay ? 45 : 0, outcomes, onPay: async () => {
        await wait(delay);
        if (opts.invoiceId) { st.completed = opts.invoiceId; st.looks = 0; try { globalThis.sessionStorage?.setItem(`zella.fake.paid.${opts.invoiceId}`, "1"); } catch { /* none */ } }
        if (opts.purchaseId) { const p = st.purchases.get(opts.purchaseId); if (p) p.looks = 0; }
      } });
    },
  };
  // stand in only: how many pack purchases were made (a double click or a retry must not make a second)
  api.debugCounts = () => ({ buys: st.buys ?? 0, purchases: st.purchases.size });
  if (typeof window !== "undefined") window.__zellaBillingFake = api;
  return api;
}
