import { supabase } from "../supabase";

// The owner's payments from inside the CRM (owner, 27 Nov 2026: "auto charge plus Pay now"): every call goes to the
// database's owner functions or the billing-api edge function, which check the caller is the business's owner. The
// screens never send an amount. With VITE_ONBOARDING_FAKE=1 (local preview and tests only) a stand in answers instead
// (fakeBillingApi.js), so a production build never contains it.

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw Object.assign(new Error(/^[A-Z_]{3,40}$/.test(error.message ?? "") ? error.message : "Something went wrong. Please try again."), { code: error.message });
  return data;
}

async function billing(action, payload) {
  const { data, error } = await supabase.functions.invoke("billing-api", { body: { action, ...payload } });
  if (error) {
    const status = error.context?.status;
    let body = null;
    try { body = await error.context?.json(); } catch { /* not JSON */ }
    throw Object.assign(new Error(body?.error || "Something went wrong. Please try again."), { status, code: typeof body?.code === "string" ? body.code : undefined, words: typeof body?.error === "string" ? body.error : undefined });
  }
  return data;
}

export const realBillingApi = {
  getSession: async () => (await supabase.auth.getSession()).data.session ?? null,
  onAuthChange: (fn) => { const { data } = supabase.auth.onAuthStateChange((_e, s) => fn(s)); return () => data.subscription.unsubscribe(); },
  overview: (businessId) => rpc("zella_billing_overview", { p_business_id: businessId }),
  invoices: (businessId) => rpc("zella_owner_invoices", { p_business_id: businessId }),
  cardSummary: async (businessId) => (await billing("card_summary", { business_id: businessId }))?.card ?? null,
  cardUpdateStart: (businessId, key) => billing("card_update_start", { business_id: businessId, idempotency_key: key }),
  invoiceStatus: async (invoiceId) => (await billing("invoice_pay_status", { invoice_id: invoiceId })).invoice,
  // every start carries the owner's agreement (consent: true and the sha256 of the words shown; owner, 27 Nov 2026)
  invoiceStart: (invoiceId, opts = {}) => billing("invoice_pay_start", { invoice_id: invoiceId, consent: true, consent_hash: opts.consentHash,
    ...(typeof opts.autopay === "boolean" ? { autopay: opts.autopay } : {}), ...(opts.autopayKey ? { autopay_key: opts.autopayKey } : {}),
    addons: Array.isArray(opts.addons) ? opts.addons : [], ...(opts.submit ? { submit: true } : {}) }),
  invoiceReturn: (invoiceId) => billing("invoice_pay_return", { invoice_id: invoiceId }),
  packBuy: (businessId, packCode, key, opts = {}) => billing("pack_buy", { business_id: businessId, pack_code: packCode, idempotency_key: key, consent: true,
    consent_hash: opts.consentHash, ...(opts.invoiceId ? { invoice_id: opts.invoiceId } : {}) }),
  packStatus: (businessId, purchaseId) => billing("pack_status", { business_id: businessId, purchase_id: purchaseId }),
  packActStart: (businessId, purchaseId, opts = {}) => billing("pack_act_start", { business_id: businessId, purchase_id: purchaseId, consent: true, consent_hash: opts.consentHash }),
  // the packs on offer, priced by the server's catalogue (add ons on the Pay pages)
  addonCatalog: (businessId) => rpc("zella_owner_addon_catalog", { p_business_id: businessId }),
  // Auto pay (owner, 27 Nov 2026): the database answers what Stripe has (from its events) and checks the owner
  autopayStatus: (businessId) => rpc("zella_owner_autopay_status", { p_business_id: businessId }),
  autopaySet: async (businessId, on, key) => (await billing("autopay_set", { business_id: businessId, on, idempotency_key: key })).autopay,
  // Stripe's real card fields and billing address come from stripeEmbedded.js (mountCardFields); the stand in brings its own
};

let chosen = null;
export async function getBillingApi() {
  if (chosen) return chosen;
  if (import.meta.env.VITE_ONBOARDING_FAKE === "1") {
    const { createFakeBillingApi } = await import("./fakeBillingApi.js");
    chosen = createFakeBillingApi({ scenario: new URLSearchParams(window.location.search).get("scenario") ?? "" });
  } else {
    chosen = realBillingApi;
  }
  return chosen;
}

export { invoiceAsPayment, packAnswer } from "./payState.js";
