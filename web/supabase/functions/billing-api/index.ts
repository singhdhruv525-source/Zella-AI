// Zella Voice: billing API for business owners (docs/PAYMENTS_ARCHITECTURE.md §3, §6.1). The browser says WHAT it
// wants, never how much: every amount is computed in the database from the accepted plan.
//   Every action that starts a payment (checkout_start, invoice_pay_start, pack_buy, pack_act_start) needs consent: true and
//   consent_hash, the sha256 of the "I agree" words the page showed (owner, 27 Nov 2026): the database and this function
//   rebuild the words from the server's own figures and refuse a different hash (CONSENT_REQUIRED, CONSENT_MISMATCH).
//   POST { action: "checkout_start", business_id, idempotency_key, autopay?, hosted?, packs?, consent, consent_hash }
//        packs: the add ons ticked (pack codes only), lines of the same Checkout Session, priced by the database
//        -> { status: "open", client_secret, publishable_key, mode, amount_minor, currency, expires_at } for Stripe's card
//           fields in our page (a Checkout Session, ui_mode custom; owner, 27 Nov 2026), { status: "redirect", url } for
//           Stripe's own page (ui_mode hosted: billing setting onboarding_checkout_mode, or hosted: true when Stripe.js
//           can't load), or { status: "processing" } when Stripe already took the payment. autopay: false keeps the
//           owner's Auto pay choice with the checkout, applied once the subscription is linked.
//        Every open reply also carries billing_prefill: the business's own address, to prefill Stripe's billing address
//        fields (the owner can change it there; it goes to Stripe with the card and is not saved back here)
//   POST { action: "checkout_return", business_id }                  -> the payment state, after applying any events;
//        with { card: { brand, last4 } } once confirmed, only when Stripe returns both for the saved card
// The client_secret is passed straight from Stripe to the owner's browser: never stored, never logged.
// Paying from inside the CRM (owner, 27 Nov 2026: "auto charge plus Pay now"; sql/zella_stripe_owner_pay.sql):
//   POST { action: "invoice_pay_status", invoice_id }      -> { invoice } (the owner of its business only; else NOT_FOUND)
//   POST { action: "invoice_pay_start", invoice_id, autopay?, autopay_key?, addons?: [{ code, key }], consent, consent_hash }
//        (autopay is the switch's value, for the words; autopay_key only when it changed) -> { status: "open", client_secret,
//        publishable_key, livemode, amount_minor, currency, number, hosted_invoice_url } for Stripe's card fields on the
//        invoice's OWN PaymentIntent (confirmation_secret), or { status: "processing" } when Stripe already has it
//   POST { action: "invoice_pay_return", invoice_id }      -> { invoice } after applying any events (paid only from those)
//   POST { action: "card_summary", business_id }           -> { card: { brand, last4 } | null } (the saved card, from Stripe)
//   POST { action: "card_update_start", business_id, idempotency_key } -> { url } of Stripe's Customer Portal, card
//        update only (flow payment_method_update)
//   POST { action: "pack_status", business_id, purchase_id } -> { purchase } after applying any events
//   POST { action: "pack_act_start", business_id, purchase_id, consent, consent_hash } -> the pack's own PaymentIntent for Stripe's card fields,
//        when the bank asked to confirm or the saved card was declined: checked with Stripe first, then reopened and
//        linked (never a second charge)
//   POST { action: "autopay_set", business_id, on, idempotency_key } -> { autopay } (owner decision, 27 Nov 2026: "Auto pay
//        switch, on by default"): the database checks the owner and records the choice; turning it on needs a usable
//        saved card (checked with Stripe here and in the database); the Stripe subscription update is sent from the
//        outbox with its stored body (§8.1). Our record of Auto pay changes only from customer.subscription.updated.
//   POST { action: "pack_buy", business_id, pack_code, idempotency_key, consent, consent_hash, invoice_id? } -> { purchase_id, status }
//        (charged on the saved card; with invoice_id, an add on agreed with Pay now, bought only once that invoice is paid;
//                                                                    the pack is added when Stripe confirms the payment)
//   POST { action: "refund_options", business_id }  /  { action: "refund_request", business_id, kind, payment_id, idempotency_key }
//                                                                    eligibility decided by the database (REQ-BIL-45)
// Each request first runs the owner's database function with the owner's own sign in (active owner of THAT business,
// a code verified session); only then does the server key send the commands that function queued. Each action is
// rate limited per signed in person (§9). The return from Stripe is never trusted: it only triggers the same event processing the
// worker runs; access is granted only by a verified, fetched and bound Stripe invoice.
// Off (503) until STRIPE_SECRET_KEY is set (and, to start a checkout, STRIPE_PUBLISHABLE_KEY in the same mode); the
// database refuses while payments_live is false. Apply order (§16.7): the migrations first, then this function, then the
// web app; a checkout is refused (PAYMENTS_MISCONFIGURED) while sql/zella_stripe_embedded_checkout.sql isn't applied.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withCors } from "../_shared/cors.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { applyEvents, type Rpc, rpcClient, sendOutboxNow } from "../_shared/billingWorker.ts";
import { checkLimits, idKey } from "../_shared/rate_limit.ts";
import { cardSummary, invoicePaymentIntent, keyIsLive, publishableKeyLive, type StripeClient, stripeClient } from "../_shared/stripe.ts";
import { consentHash, consentText } from "../_shared/paymentConsent.js";

const WORDS: Record<string, string> = {
  NOT_SIGNED_IN: "Please sign in again.",
  NOT_ALLOWED: "Only the business owner can do this.",
  MFA_REQUIRED: "Enter the code from your authenticator app to continue.",
  BUSINESS_NOT_AVAILABLE: "This workspace is paused. Contact Zella Voice support.",
  PAYMENTS_NOT_LIVE: "Payments aren't switched on yet. You weren't charged.",
  STEP_LOCKED: "Finish the earlier steps first.",
  PLAN_MISSING: "Your plan isn't ready yet. Zella Voice will be in touch.",
  PLAN_CHANGED: "Your plan was just updated. Please review it again.",
  ALREADY_PAID: "Your payment is already confirmed.",
  NO_SAVED_CARD: "Add a card in Settings, Billing first.",
  NO_ACTIVE_PLAN: "Packs can be bought once your plan is active.",
  NOT_ELIGIBLE: "This payment can't be refunded under the refund policy.",
  UNKNOWN_PACK: "That pack isn't available.",
  IDEMPOTENCY_CONFLICT: "That didn't work. Reload the page and try again.",
  INVALID_INPUT: "That didn't work. Reload the page and try again.",
  CHECKOUT_NOT_READY: "We couldn't open the payment form. Please try again in a minute.",
  CHECKOUT_EXPIRED: "This payment form expired. You weren't charged. Start again to get a new one.",
  PAYMENTS_MISCONFIGURED: "Payments can't open right now. You weren't charged. We've been alerted.",
  NOT_FOUND: "We couldn't find that for your account. Check you're signed in as the business owner.",
  NOT_PAYABLE: "This can't be paid online right now. You weren't charged.",
  NO_CUSTOMER: "Your card is added with your first payment. There's nothing to update yet.",
  NO_SUBSCRIPTION: "Auto pay can be changed once your plan is active.",
  PACK_PENDING: "This pack is already being paid. Wait a moment for it to finish, or finish it with your bank.",
  TOO_MANY: "Too many attempts. Wait a minute and try again.",
  CONSENT_REQUIRED: "Please tick the box to continue.",
  CONSENT_MISMATCH: "The total changed. Please tick the box again.",
  ADDONS_NOT_IN_TRIAL: "Add ons can be added once your plan is active. You weren't charged.",
  ADDONS_IN_PROGRESS: "Another payment for this bill is in progress. Wait a moment, then reload this page.",
  INVOICE_NOT_PAID: "Add ons are charged once your plan payment is confirmed. You weren't charged for them yet.",
};
// per person, per minute (§9): starting a payment or a change, and the confirming polls
const LIMITS: Record<string, number> = { checkout_start: 20, invoice_pay_start: 20, pack_act_start: 20, pack_buy: 10, card_update_start: 10, autopay_set: 10,
  refund_request: 10, checkout_return: 120, invoice_pay_return: 120, pack_status: 120, invoice_pay_status: 120, card_summary: 60, refund_options: 60 };
const jwtSub = (jwt: string) => { try { return String(JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? ""); } catch { return ""; } };
// applying Stripe's events while a page polls: at most every few seconds per running function (the worker does the rest)
let lastApply = 0;
async function applyEventsSoon(rpc: Rpc, stripe: StripeClient, limit: number, rounds: number) {
  if (Date.now() - lastApply < 3000) return;
  lastApply = Date.now();
  await applyEvents(rpc, stripe, limit, rounds).catch(() => null);
}
export const resetApplyThrottle = () => { lastApply = 0; };
// a saved card Stripe can still charge: a card PaymentMethod whose expiry hasn't passed
export function usableCard(pm: unknown, now = new Date()): boolean {
  const c = (pm as Record<string, any> | null)?.card;
  if (!c || typeof c !== "object") return false;
  const m = Number(c.exp_month), y = Number(c.exp_year);
  if (!Number.isInteger(m) || !Number.isInteger(y)) return false;
  return y > now.getUTCFullYear() || (y === now.getUTCFullYear() && m >= now.getUTCMonth() + 1);
}
const INVOICE_ACTIONS = new Set(["invoice_pay_status", "invoice_pay_start", "invoice_pay_return"]);
const OPEN_INTENT = new Set(["requires_payment_method", "requires_action", "requires_confirmation"]);
const intentOf = (secret: string) => secret.split("_secret_")[0];
const OPEN_ISH = new Set(["open", "expiring"]);
// The owner's agreement (owner decision, 27 Nov 2026: a required "I agree" box before Pay): the page sends consent: true
// and the sha256 of the words it showed. The database rebuilds the words from its own figures and refuses a different
// sha256; billing-api checks again here from the figures the database answered, before anything reaches Stripe or the
// browser gets a client secret. The browser is never trusted alone.
const HEX64 = /^[0-9a-f]{64}$/;
const PACK_CODE = /^[a-z]+_[0-9]+$/;
const ATTEMPT_KEY = /^[A-Za-z0-9_-]{8,100}$/;
const consentGiven = (b: Record<string, unknown>) => b.consent === true && HEX64.test(String(b.consent_hash ?? ""));
async function consentMatches(hash: string, figures: Record<string, unknown>): Promise<boolean> {
  const text = consentText(figures as Parameters<typeof consentText>[0]);
  return typeof text === "string" && (await consentHash(text)) === hash;
}

// The checkout's Stripe session, fetched with the server key and checked against our own record before anything from
// it reaches the browser: our session id, our checkout (client_reference_id), this business, the key's mode.
async function ourSession(rpc: Rpc, stripe: StripeClient, business: string, checkoutId: string | null, query?: Record<string, unknown>) {
  const row = await rpc("zella_billing_checkout_session", { p_business_id: business, p_checkout_id: checkoutId }) as Record<string, any> | null;
  const sid = typeof row?.stripe_session_id === "string" ? row.stripe_session_id : "";
  if (!row || !/^cs_[A-Za-z0-9_]{1,250}$/.test(sid)) return { row, session: null };
  const session = await stripe.get(`/v1/checkout/sessions/${sid}`, query) as Record<string, any>;
  const ours = session.id === sid && session.client_reference_id === row.checkout_id && session.metadata?.business_id === business
    && session.livemode === stripe.livemode;
  if (!ours) throw Object.assign(new Error("checkout session binding failed"), { binding: true });
  return { row, session };
}
const reply = (data: unknown, status = 200) => Response.json(data, { status });
const refuse = (code: string, status = 400) => reply({ error: WORDS[code] ?? "Something went wrong. Please try again.", code: WORDS[code] ? code : "ERROR" }, status);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class DbRefusal extends Error { constructor(readonly code: string, readonly status: number) { super(code); } }

// A database call with the owner's own sign in, so row security and the function's own checks are the real ones.
async function asOwner(url: string, anon: string, jwt: string, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST", signal: AbortSignal.timeout(15_000),
    headers: { "Content-Type": "application/json", apikey: anon, Authorization: `Bearer ${jwt}` }, body: JSON.stringify(args),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    const msg = String(body?.message ?? "");
    throw new DbRefusal(/^[A-Z_]{3,40}$/.test(msg) ? msg : res.status === 401 ? "NOT_SIGNED_IN" : "ERROR", res.status === 401 ? 401 : 400);
  }
  return body;
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY"), server = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const apiKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!url || !anon || !server || !apiKey) return refuse("PAYMENTS_NOT_LIVE", 503);
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt || jwt === anon) return refuse("NOT_SIGNED_IN", 401);
  const read = await readJsonLimited(req, 4_000);   // SEC-12
  const body = read.ok ? asObject(read.value) : null;
  if (!body) return refuse("INVALID_INPUT");
  // invoice actions name only our invoice id (the emailed link): the database finds its business and checks the caller
  // is that business's owner; every other action names the business
  const action = String(body.action ?? "");
  const invoiceId = String(body.invoice_id ?? "");
  if (INVOICE_ACTIONS.has(action) ? !UUID.test(invoiceId) : !UUID.test(String(body.business_id ?? ""))) return refuse("INVALID_INPUT");
  let business = String(body.business_id ?? "");

  const sub = jwtSub(jwt);
  if (LIMITS[action]) {
    const answer = await checkLimits(url, server, [[`billing-api:${action}:${idKey(sub || "unknown")}`, LIMITS[action], 60]]);
    if (answer === "limited") return refuse("TOO_MANY", 429);
    if (answer === "unavailable") return refuse("ERROR", 503);
  }
  const rpc = rpcClient(url, server);
  const stripe = stripeClient({ secretKey: apiKey, baseUrl: (!keyIsLive(apiKey) && Deno.env.get("STRIPE_API_BASE")) || undefined });
  try {
    // Stripe.js in the owner's browser needs the publishable key, in the same mode as ours: never a test form for a
    // live object or the reverse. A mismatch keeps every payment form closed and tells Zella Voice.
    const browserKey = async (): Promise<string | Response> => {
      const publishable = Deno.env.get("STRIPE_PUBLISHABLE_KEY") ?? "";
      const pkLive = publishableKeyLive(publishable);
      if (pkLive === null) return refuse("PAYMENTS_NOT_LIVE", 503);
      if (pkLive !== stripe.livemode) {
        console.error("billing api: the Stripe publishable key and secret key are in different modes");
        await rpc("zella_platform_alert", { p_kind: "stripe_key_mode_mismatch", p_title: "Stripe keys are in different modes",
          p_detail: "The publishable key and the secret key are not both test or both live, so the Pay step stays closed until they match.",
          p_severity: "urgent", p_business_id: null, p_dedupe_key: "stripe_key_mode_mismatch", p_meta: {} }).catch(() => null);
        return refuse("PAYMENTS_MISCONFIGURED", 503);
      }
      return publishable;
    };
    // the business's own address for Stripe's billing address fields: plain strings only, never required
    const prefill = async (biz: string) => {
      const a = await rpc("zella_billing_address_prefill", { p_business_id: biz }).catch(() => null) as Record<string, unknown> | null;
      const out: Record<string, string> = {};
      for (const k of ["line1", "line2", "city", "state", "postal_code"]) if (typeof a?.[k] === "string" && a[k]) out[k] = String(a[k]).slice(0, 100);
      if (typeof a?.country === "string" && /^[A-Z]{2}$/.test(a.country)) out.country = a.country;
      return out;
    };
    const refs = async (biz: string) => await rpc("zella_billing_stripe_refs", { p_business_id: biz, p_livemode: stripe.livemode }) as { customer: string | null; subscription: string | null } | null;
    // the subscription's saved card, checked with Stripe (a card, not expired), and the check recorded for the database,
    // which turns Auto pay on only after it (review)
    const checkSavedCard = async (biz: string): Promise<boolean> => {
      const ref = await refs(biz).catch(() => null);
      const sub = ref?.subscription && ref.customer
        ? await stripe.get(`/v1/subscriptions/${ref.subscription}`, { expand: ["default_payment_method"] }).catch(() => null) as Record<string, any> | null : null;
      if (!sub || sub.customer !== ref?.customer || !usableCard(sub.default_payment_method)) return false;
      await rpc("zella_billing_card_checked", { p_business_id: biz, p_payment_method: String(sub.default_payment_method?.id ?? "") });
      return true;
    };
    // the card a confirmed payment used, from its PaymentIntent's payment method (our customer, our purchase); null on any doubt
    const paidWith = async (biz: string, intentOf: (customer: string) => Promise<string | null>, purchaseId?: string) => {
      try {
        const ref = await refs(biz);
        if (!ref?.customer) return null;
        const piId = await intentOf(ref.customer);
        if (!piId || !/^pi_[A-Za-z0-9_]{1,250}$/.test(piId)) return null;
        const pi = await stripe.get(`/v1/payment_intents/${piId}`, { expand: ["payment_method"] }) as Record<string, any>;
        if (pi.customer !== ref.customer || pi.status !== "succeeded" || (purchaseId && pi.metadata?.purchase_id !== purchaseId)) return null;
        return cardSummary(pi.payment_method);
      } catch { return null; }
    };
    if (body.action === "checkout_start") {
      const key = String(body.idempotency_key ?? "");
      const wantHosted = body.hosted === true;
      if (!consentGiven(body)) return refuse("CONSENT_REQUIRED");
      // the add ons the owner ticked (owner, 27 Nov 2026): pack codes only; the database prices them from its catalogue
      const packs = Array.isArray(body.packs) ? body.packs : [];
      if (packs.length > 20 || !packs.every((c) => typeof c === "string" && PACK_CODE.test(c))) return refuse("INVALID_INPUT");
      const autopay = body.autopay !== false;
      const consentHashSent = String(body.consent_hash);
      // applied in order (§16.7): without sql/zella_stripe_embedded_checkout.sql a checkout would ask Stripe for a session
      // this function can't use, so nothing starts and Zella Voice is told
      const applied = await rpc("zella_billing_checkout_session", { p_business_id: business, p_checkout_id: null }).then(() => true, (e) => !/PGRST202|Could not find the function|404/.test(String(e?.message ?? e)));
      if (!applied) {
        await rpc("zella_platform_alert", { p_kind: "billing_migration_missing", p_title: "The checkout migration isn't applied", p_detail: "Apply sql/zella_stripe_embedded_checkout.sql before this billing-api version.",
          p_severity: "urgent", p_business_id: null, p_dedupe_key: "billing_migration_missing", p_meta: {} }).catch(() => null);
        return refuse("PAYMENTS_MISCONFIGURED", 503);
      }
      // the same key and selection, a second tab or a reload gets the same open checkout (one per business, the database
      // decides); the owner's Auto pay choice is kept with it (review M2)
      const startArgs = { p_business_id: business, p_idempotency_key: key, p_packs: packs, p_autopay: autopay, p_consent_hash: consentHashSent };
      let start = await asOwner(url, anon, jwt, "zella_owner_billing_checkout_start", startArgs) as Record<string, unknown>;
      // a different selection while a session is open: the database marked that session for expiry; it is expired at
      // Stripe now (its stored command), and only then does the new selection get its own checkout (one open at a time)
      if (start?.status === "expiring" && UUID.test(String(start.checkout_id ?? ""))) {
        for (let i = 0; i < 3; i++) {
          const next = await rpc("zella_billing_checkout_next_command", { p_checkout_id: start.checkout_id }) as string | null;
          if (!next || (await sendOutboxNow(rpc, stripe, next)) !== "sent") break;
        }
        start = await asOwner(url, anon, jwt, "zella_owner_billing_checkout_start", startArgs) as Record<string, unknown>;
        if (start?.status === "expiring") return refuse("CHECKOUT_NOT_READY", 502);
      }
      const checkout = String(start?.checkout_id ?? "");
      if (!UUID.test(checkout)) return refuse("ERROR", 500);
      const publishable = await browserKey();   // after the owner check (review 7)
      if (publishable instanceof Response) return publishable;
      // the words again, from the database's own figures for THIS checkout, before anything reaches Stripe (Stripe already
      // taking a payment needs none)
      if (start.status !== "completed" && !(await consentMatches(consentHashSent, { kind: "plan", todayMinor: start.amount_minor, autopay,
          renewalMinor: start.renewal_minor, addonsMinor: Number(start.addons_minor ?? 0) }))) return refuse("CONSENT_MISMATCH", 409);
      if (wantHosted && start.status === "preparing") await rpc("zella_billing_checkout_use_hosted", { p_checkout_id: checkout });
      // customer, product, prices, session: one after the other, each from the outbox with its stored body and key
      if (start.status === "preparing") {
        await rpc("zella_billing_checkout_continue", { p_checkout_id: checkout, p_livemode: stripe.livemode });
        for (let i = 0; i < 6; i++) {
          const rows = await rpc("zella_billing_checkout_next_command", { p_checkout_id: checkout }) as string | null;
          if (!rows) break;
          const r = await sendOutboxNow(rpc, stripe, rows);
          if (r !== "sent") break;
        }
      }
      const { row, session } = await ourSession(rpc, stripe, business, checkout);
      if (row?.status === "completed" || session?.status === "complete") return reply({ status: "processing" });   // Stripe took it; the webhook confirms
      if (!session || !OPEN_ISH.has(String(row?.status))) return refuse("CHECKOUT_NOT_READY", 502);
      if (session.status !== "open") {
        await applyEvents(rpc, stripe, 20, 4).catch(() => null);   // records the expiry, so the next start opens a new one
        return refuse("CHECKOUT_EXPIRED", 409);
      }
      if (row?.status !== "open") return refuse("CHECKOUT_NOT_READY", 502);
      // the amount Stripe will take is ours (review 4): a session that differs is never shown
      if (Number(session.amount_total) !== Number(row.amount_minor) || String(session.currency ?? "").toLowerCase() !== String(row.currency ?? "").toLowerCase()) {
        console.error("billing api: a checkout session's amount differs from our record");
        await rpc("zella_platform_alert", { p_kind: "billing_checkout_amount", p_title: "A checkout's amount differs from our record", p_detail: null,
          p_severity: "urgent", p_business_id: business, p_dedupe_key: `checkout_amount:${checkout}`, p_meta: {} }).catch(() => null);
        return refuse("CHECKOUT_NOT_READY", 502);
      }
      // Stripe.js can't load: an open in page session is expired at Stripe first, so one session at a time; the next
      // start (a new key) makes a hosted one (owner, 27 Nov 2026)
      if (wantHosted && session.ui_mode !== "hosted") {
        await stripe.post(`/v1/checkout/sessions/${session.id}/expire`, {}, `expire:${session.id}`);
        await applyEvents(rpc, stripe, 20, 4).catch(() => null);
        return refuse("CHECKOUT_EXPIRED", 409);
      }
      // ui_mode hosted: Stripe's own page; the return proves nothing (the server confirms from Stripe's events)
      if (session.ui_mode === "hosted") {
        if (typeof session.url !== "string" || !/^https:\/\/checkout\.stripe\.com\//.test(session.url)) return refuse("CHECKOUT_NOT_READY", 502);
        return reply({ status: "redirect", url: session.url, mode: row.mode, amount_minor: row.amount_minor, currency: row.currency });
      }
      // ui_mode custom: Stripe's card fields in our page, with the Checkout Sessions API (owner, 27 Nov 2026)
      if (session.ui_mode !== "custom" || typeof session.client_secret !== "string") return refuse("CHECKOUT_NOT_READY", 502);
      return reply({ status: "open", client_secret: session.client_secret, publishable_key: publishable, livemode: stripe.livemode,
        mode: row.mode, amount_minor: row.amount_minor, currency: row.currency, expires_at: row.expires_at, billing_prefill: await prefill(business) });
    }
    if (body.action === "checkout_return") {
      await asOwner(url, anon, jwt, "zella_owner_onboarding_payment_status", { p_business_id: business });   // the owner check first
      await applyEventsSoon(rpc, stripe, 20, 8);   // the worker's own step (throttled); nothing here trusts the return
      const payment = await asOwner(url, anon, jwt, "zella_owner_onboarding_payment_status", { p_business_id: business }) as Record<string, any>;
      // once the server confirmed the payment: the saved card's brand and last 4, only as Stripe returns them
      let card = null;
      if (payment?.status === "confirmed") {
        card = await ourSession(rpc, stripe, business, null, { expand: ["subscription.default_payment_method"] })
          .then(({ row, session }) => (row && ["paid", "completed"].includes(row.status) ? cardSummary(session?.subscription?.default_payment_method) : null))
          .catch(() => null);
      }
      return reply(card ? { payment, card } : { payment });
    }
    // a payment Stripe already has for an invoice our record still calls unpaid (a reload, another tab, Auto pay at the same
    // moment, invoice.paid not applied yet): the page shows it confirming and never offers Pay again (double payment cases
    // 1, 3, 8, 11); and when Stripe has none, the page can say so and offer Pay again (review)
    const stripeHasIt = async (invoice: Record<string, any>): Promise<boolean> => {
      if (!["open", "payment_failed"].includes(String(invoice?.status)) || !/^in_[A-Za-z0-9_]{1,250}$/.test(String(invoice?.stripe_invoice_id ?? ""))) return false;
      const ref = await refs(String(invoice.business_id)).catch(() => null);
      const si = await stripe.get(`/v1/invoices/${invoice.stripe_invoice_id}`, { expand: ["payments"] }).catch(() => null) as Record<string, any> | null;
      if (!si || !ref?.customer || (typeof si.customer === "string" ? si.customer : si.customer?.id) !== ref.customer) return false;
      if (si.status === "paid") return true;
      const piId = invoicePaymentIntent(si);
      const pi = piId ? await stripe.get(`/v1/payment_intents/${piId}`).catch(() => null) as Record<string, any> | null : null;
      return ["processing", "succeeded"].includes(String(pi?.status));
    };
    if (action === "invoice_pay_status") {
      const invoice = await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId }) as Record<string, any>;
      return reply({ invoice: (await stripeHasIt(invoice)) ? { ...invoice, processing: true } : invoice });
    }
    if (action === "invoice_pay_return") {
      await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId });   // the owner check first
      await applyEventsSoon(rpc, stripe, 20, 8);   // invoice.paid is what marks it paid (throttled); nothing here trusts the browser
      let invoice = await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId }) as Record<string, any>;
      if (invoice?.status !== "paid" && (await stripeHasIt(invoice))) invoice = { ...invoice, processing: true };
      // once OUR record says paid: the card that paid it (brand, last 4, issuer), only as Stripe returns them
      const card = invoice?.status === "paid" ? await paidWith(String(invoice.business_id), async (cus) => {
        // payments is includable: without expanding it the invoice's PaymentIntent can't be found on the pinned version (review)
        const si = await stripe.get(`/v1/invoices/${invoice.stripe_invoice_id}`, { expand: ["payments"] }) as Record<string, any>;
        if (si.id !== invoice.stripe_invoice_id || (typeof si.customer === "string" ? si.customer : si.customer?.id) !== cus) return null;
        return invoicePaymentIntent(si);
      }) : null;
      return reply(card ? { invoice, card } : { invoice });
    }
    if (action === "invoice_pay_start") {
      if (!consentGiven(body)) return refuse("CONSENT_REQUIRED");
      // the add ons ticked with Pay now (owner, 27 Nov 2026): codes and the key each was given when Pay was pressed; they
      // are bought right after the plan payment (pack_buy with invoice_id), never on the invoice
      const addons = Array.isArray(body.addons) ? body.addons : [];
      if (addons.length > 20 || !addons.every((a) => a && typeof a === "object" && PACK_CODE.test(String(a.code ?? "")) && ATTEMPT_KEY.test(String(a.key ?? "")))) return refuse("INVALID_INPUT");
      // submit: true is the Pay press (the agreement that goes with the payment to Stripe). Another tab's payment with
      // other add ons may be in flight: the database refuses (ADDONS_IN_PROGRESS); only when Stripe says that attempt
      // failed (the invoice's intent has a payment error, or was cancelled) is it cleared and this one let through, so
      // the add ons bought after the payment are exactly those of the attempt that paid (review round 2)
      const payArgs = { p_invoice_id: invoiceId, p_autopay: typeof body.autopay === "boolean" ? body.autopay : null,
        p_addons: addons.map((a: Record<string, unknown>) => ({ code: String(a.code), key: String(a.key) })), p_consent_hash: String(body.consent_hash), p_submit: body.submit === true };
      let inv: Record<string, any>;
      try { inv = await asOwner(url, anon, jwt, "zella_owner_invoice_pay_start", payArgs) as Record<string, any>; }
      catch (e) {
        if (!(e instanceof DbRefusal) || e.code !== "ADDONS_IN_PROGRESS") throw e;
        const seen = await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId }) as Record<string, any>;
        const si = /^in_[A-Za-z0-9_]{1,250}$/.test(String(seen?.stripe_invoice_id ?? "")) ? await stripe.get(`/v1/invoices/${seen.stripe_invoice_id}`, { expand: ["payments"] }).catch(() => null) as Record<string, any> | null : null;
        const piId = si ? invoicePaymentIntent(si) : null;
        const pi = piId ? await stripe.get(`/v1/payment_intents/${piId}`).catch(() => null) as Record<string, any> | null : null;
        const failed = pi && (pi.status === "canceled" || (pi.status === "requires_payment_method" && pi.last_payment_error));
        if (!failed) return refuse("ADDONS_IN_PROGRESS", 409);
        await rpc("zella_billing_invoice_attempts_clear", { p_invoice_id: invoiceId });
        inv = await asOwner(url, anon, jwt, "zella_owner_invoice_pay_start", payArgs) as Record<string, any>;
      }
      business = String(inv.business_id);
      const publishable = await browserKey();   // after the owner check (review 7)
      if (publishable instanceof Response) return publishable;
      // the words again from the database's figures (the invoice's amount due plus the add ons at catalogue prices), before
      // any Auto pay change, any Stripe call and any client secret
      if (!(await consentMatches(String(body.consent_hash), { kind: "invoice", todayMinor: inv.amount_due_minor, autopay: inv.autopay !== false, renewalMinor: inv.renewal_minor,
          addonsMinor: Number(inv.addons_minor ?? 0) }))) return refuse("CONSENT_MISMATCH", 409);
      if (String(inv.currency ?? "").toLowerCase() !== "usd") return refuse("NOT_PAYABLE");   // review 4
      // the owner's Auto pay choice made with Pay now, stored on the server as the payment starts (review M2); a refusal
      // (no saved card to turn it on) never blocks paying the invoice
      let autopayError: string | null = null;
      if (typeof body.autopay === "boolean" && /^[A-Za-z0-9_-]{8,100}$/.test(String(body.autopay_key ?? ""))) {
        // turning it on needs the same check with Stripe as autopay_set (review): a usable saved card, recorded for the database
        const cardOk = body.autopay ? await checkSavedCard(business) : true;
        if (!cardOk) autopayError = "NO_SAVED_CARD";
        else await asOwner(url, anon, jwt, "zella_owner_autopay_set", { p_business_id: business, p_on: body.autopay, p_idempotency_key: String(body.autopay_key) })
          .catch((e) => { autopayError = e instanceof DbRefusal ? e.code : "ERROR"; });
        const next = await rpc("zella_billing_autopay_next_command", { p_business_id: business }).catch(() => null) as string | null;
        if (next) await sendOutboxNow(rpc, stripe, next).catch(() => null);
      }
      const sid = String(inv.stripe_invoice_id ?? "");
      if (!/^in_[A-Za-z0-9_]{1,250}$/.test(sid) || inv.livemode !== stripe.livemode) return refuse("NOT_PAYABLE");
      const ref = await refs(business);
      const si = await stripe.get(`/v1/invoices/${sid}`, { expand: ["confirmation_secret"] }) as Record<string, any>;
      // ours: the same invoice, our customer, the key's mode
      if (si.id !== sid || si.livemode !== stripe.livemode || !ref?.customer || (typeof si.customer === "string" ? si.customer : si.customer?.id) !== ref.customer) {
        throw Object.assign(new Error("invoice binding failed"), { binding: true });
      }
      if (si.status === "paid") return reply({ status: "processing" });   // Stripe has it; our record follows from invoice.paid
      if (si.status !== "open" || String(si.currency ?? "").toLowerCase() !== "usd") return refuse("NOT_PAYABLE");
      if (Number(si.amount_due) !== Number(inv.amount_due_minor)) {
        console.error("billing api: an invoice's amount due differs from our record");
        await rpc("zella_platform_alert", { p_kind: "billing_invoice_amount", p_title: "An invoice's amount differs from our record", p_detail: null,
          p_severity: "urgent", p_business_id: business, p_dedupe_key: `invoice_amount:${invoiceId}`, p_meta: {} }).catch(() => null);
        return refuse("CHECKOUT_NOT_READY", 502);
      }
      let secret = typeof si.confirmation_secret?.client_secret === "string" ? si.confirmation_secret.client_secret : "";
      if (!secret && typeof si.payment_intent === "string") secret = String((await stripe.get(`/v1/payment_intents/${si.payment_intent}`)).client_secret ?? "");
      if (!/^pi_[A-Za-z0-9_]+_secret_[A-Za-z0-9_]+$/.test(secret)) return refuse("CHECKOUT_NOT_READY", 502);
      const pi = await stripe.get(`/v1/payment_intents/${intentOf(secret)}`) as Record<string, any>;
      if (pi.status === "succeeded" || pi.status === "processing") return reply({ status: "processing" });
      if (!OPEN_INTENT.has(String(pi.status))) return refuse("NOT_PAYABLE");
      return reply({ status: "open", client_secret: secret, publishable_key: publishable, livemode: stripe.livemode, amount_minor: inv.amount_due_minor,
        currency: inv.currency, number: inv.number, hosted_invoice_url: inv.hosted_invoice_url, billing_prefill: await prefill(business), addons: inv.addons ?? [],
        ...(autopayError ? { autopay_error: autopayError } : {}) });
    }
    if (action === "card_summary") {
      await asOwner(url, anon, jwt, "zella_owner_billing_access", { p_business_id: business, p_write: false });
      const ref = await refs(business);
      if (!ref?.subscription || !ref.customer) return reply({ card: null });
      const sub = await stripe.get(`/v1/subscriptions/${ref.subscription}`, { expand: ["default_payment_method"] }).catch(() => null) as Record<string, any> | null;
      return reply({ card: sub && sub.customer === ref.customer ? cardSummary(sub.default_payment_method) : null });
    }
    if (action === "card_update_start") {
      // Stripe's Customer Portal, card update only (docs/PAYMENTS_ARCHITECTURE.md §16.1, §16.2): a short lived page, no
      // money; a new one per attempt, keyed portal:<business>:<the browser's attempt key>
      const key = String(body.idempotency_key ?? "");
      if (!/^[A-Za-z0-9_-]{8,100}$/.test(key)) return refuse("INVALID_INPUT");
      const access = await asOwner(url, anon, jwt, "zella_owner_billing_access", { p_business_id: business, p_write: true }) as Record<string, any>;
      const ref = await refs(business);
      if (!ref?.customer) return refuse("NO_CUSTOMER", 409);
      const app = String(access.app_base_url ?? "");
      if (!/^https:\/\/[^/?#]+/.test(app)) return refuse("ERROR", 500);
      // back to Settings, Billing and subscription, Invoices and payments in the CRM (owner, 27 Nov 2026)
      const back = `${app.replace(/\/+$/, "")}/app/settings/billing/invoices?card=updated`;
      const portal = await stripe.post("/v1/billing_portal/sessions", { customer: ref.customer, return_url: back,
        flow_data: { type: "payment_method_update", after_completion: { type: "redirect", redirect: { return_url: back } } } }, `portal:${business}:${key}`) as Record<string, any>;
      if (typeof portal.url !== "string" || !portal.url.startsWith("https://")) return refuse("ERROR", 500);
      return reply({ url: portal.url });
    }
    if (action === "pack_status") {
      if (!UUID.test(String(body.purchase_id ?? ""))) return refuse("INVALID_INPUT");
      const before = await asOwner(url, anon, jwt, "zella_owner_pack_status", { p_business_id: business, p_purchase_id: body.purchase_id }) as Record<string, any>;
      await applyEventsSoon(rpc, stripe, 20, 8);
      // a reopened purchase past its day: back to failed only once Stripe says the payment wasn't taken (review 3)
      if (before?.reopen_expired === true && typeof before.payment_intent === "string" && /^pi_[A-Za-z0-9_]{1,250}$/.test(before.payment_intent)) {
        const pi = await stripe.get(`/v1/payment_intents/${before.payment_intent}`).catch(() => null) as Record<string, any> | null;
        if (pi && !["succeeded", "processing"].includes(String(pi.status))) await rpc("zella_billing_pack_reopen_expire", { p_purchase_id: body.purchase_id });
      }
      const purchase = await asOwner(url, anon, jwt, "zella_owner_pack_status", { p_business_id: business, p_purchase_id: body.purchase_id }) as Record<string, any>;
      const card = purchase?.status === "granted" && typeof purchase.payment_intent === "string" ? await paidWith(business, async () => purchase.payment_intent, String(body.purchase_id)) : null;
      return reply(card ? { purchase, card } : { purchase });
    }
    if (action === "pack_act_start") {
      if (!UUID.test(String(body.purchase_id ?? ""))) return refuse("INVALID_INPUT");
      if (!consentGiven(body)) return refuse("CONSENT_REQUIRED");
      const act = await asOwner(url, anon, jwt, "zella_owner_pack_act_start", { p_business_id: business, p_purchase_id: body.purchase_id, p_consent_hash: String(body.consent_hash) }) as Record<string, any>;
      if (!(await consentMatches(String(body.consent_hash), { kind: "pack", todayMinor: act.price_cents }))) return refuse("CONSENT_MISMATCH", 409);
      const publishable = await browserKey();   // after the owner check (review 7)
      if (publishable instanceof Response) return publishable;
      const ref = await refs(business);
      const piId = String(act.payment_intent ?? "");
      if (!/^pi_[A-Za-z0-9_]{1,250}$/.test(piId)) return refuse("NOT_PAYABLE");
      const pi = await stripe.get(`/v1/payment_intents/${piId}`) as Record<string, any>;
      if (pi.id !== piId || pi.livemode !== stripe.livemode || pi.metadata?.purchase_id !== String(body.purchase_id) || !ref?.customer || pi.customer !== ref.customer
          || Number(pi.amount) !== Number(act.price_cents)) throw Object.assign(new Error("pack payment binding failed"), { binding: true });
      if (!OPEN_INTENT.has(String(pi.status)) && pi.status !== "succeeded" && pi.status !== "processing") return refuse("NOT_PAYABLE");
      // verified: now the purchase moves forward on THIS PaymentIntent, linked with its price, so Stripe's succeeded grants it
      await rpc("zella_billing_pack_reopen", { p_business_id: business, p_purchase_id: body.purchase_id, p_payment_intent: piId, p_livemode: stripe.livemode,
        p_user_id: UUID.test(String(act.user_id ?? "")) ? act.user_id : null });
      if (pi.status === "succeeded" || pi.status === "processing") return reply({ status: "processing" });
      if (typeof pi.client_secret !== "string") return refuse("NOT_PAYABLE");
      return reply({ status: "open", client_secret: pi.client_secret, publishable_key: publishable, livemode: stripe.livemode, amount_minor: act.price_cents, currency: "usd",
        billing_prefill: await prefill(business) });
    }
    if (action === "autopay_set") {
      const key = String(body.idempotency_key ?? "");
      if (typeof body.on !== "boolean" || !/^[A-Za-z0-9_-]{8,100}$/.test(key)) return refuse("INVALID_INPUT");
      if (body.on) {
        // turning Auto pay on needs a saved card Stripe can charge (the owner check first)
        await asOwner(url, anon, jwt, "zella_owner_billing_access", { p_business_id: business, p_write: true });
        const ref = await refs(business);
        const sub = ref?.subscription && ref.customer
          ? await stripe.get(`/v1/subscriptions/${ref.subscription}`, { expand: ["default_payment_method"] }).catch(() => null) as Record<string, any> | null : null;
        if (!sub || sub.customer !== ref?.customer || !usableCard(sub.default_payment_method)) return refuse("NO_SAVED_CARD", 409);
        await rpc("zella_billing_card_checked", { p_business_id: business, p_payment_method: String(sub.default_payment_method?.id ?? "") });   // the database requires it to turn Auto pay on
      }
      try { await asOwner(url, anon, jwt, "zella_owner_autopay_set", { p_business_id: business, p_on: body.on, p_idempotency_key: key }); }
      catch (e) { if (e instanceof DbRefusal && e.code === "IDEMPOTENCY_CONFLICT") return refuse("IDEMPOTENCY_CONFLICT", 409); throw e; }
      const next = await rpc("zella_billing_autopay_next_command", { p_business_id: business }) as string | null;
      if (next) {
        await sendOutboxNow(rpc, stripe, next);
        await applyEvents(rpc, stripe, 20, 4).catch(() => null);   // Stripe's customer.subscription.updated is what changes our record
      }
      return reply({ autopay: await asOwner(url, anon, jwt, "zella_owner_autopay_status", { p_business_id: business }) });
    }
    if (body.action === "pack_buy") {
      if (!consentGiven(body)) return refuse("CONSENT_REQUIRED");
      const code = String(body.pack_code ?? "");
      const forInvoice = body.invoice_id == null ? null : String(body.invoice_id);
      if (forInvoice !== null && !UUID.test(forInvoice)) return refuse("INVALID_INPUT");
      // on its own (the pack page): the add on's own words at the catalogue's price; as an add on agreed with Pay now, the
      // database checks it against that agreement (it named this pack and this key) and that the invoice is paid
      if (forInvoice === null) {
        const offer = await asOwner(url, anon, jwt, "zella_owner_addon_catalog", { p_business_id: business }) as Record<string, unknown>[] | null;
        const pack = Array.isArray(offer) ? offer.find((p) => p.code === code) : null;
        if (!pack) return refuse("UNKNOWN_PACK");
        if (!(await consentMatches(String(body.consent_hash), { kind: "pack", todayMinor: pack.price_cents }))) return refuse("CONSENT_MISMATCH", 409);
      }
      const bought = await asOwner(url, anon, jwt, "zella_owner_pack_buy", { p_business_id: business, p_pack_code: code, p_idempotency_key: String(body.idempotency_key ?? ""),
        p_consent_hash: String(body.consent_hash), p_invoice_id: forInvoice }) as Record<string, unknown>;
      const next = await rpc("zella_billing_pack_next_command", { p_purchase_id: bought.purchase_id }) as string | null;
      if (next) await sendOutboxNow(rpc, stripe, next);
      return reply({ purchase_id: bought.purchase_id, status: bought.status });
    }
    if (body.action === "refund_options") return reply(await asOwner(url, anon, jwt, "zella_owner_refund_options", { p_business_id: business }));
    if (body.action === "refund_request") {
      if (!UUID.test(String(body.payment_id ?? ""))) return refuse("INVALID_INPUT");
      return reply(await asOwner(url, anon, jwt, "zella_owner_refund_request", { p_business_id: business, p_kind: String(body.kind ?? ""), p_payment_id: body.payment_id, p_idempotency_key: String(body.idempotency_key ?? "") }));
    }
    return refuse("INVALID_INPUT");
  } catch (e) {
    if (e instanceof DbRefusal) return refuse(e.code, e.status);
    console.error("billing api failed", e instanceof Error ? e.message.slice(0, 120) : "error");
    return refuse("ERROR", 500);
  }
}

if (import.meta.main) Deno.serve(withCors(handle));
