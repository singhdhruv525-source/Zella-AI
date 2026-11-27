// Zella Voice: billing API for business owners (docs/PAYMENTS_ARCHITECTURE.md §3, §6.1). The browser says WHAT it
// wants, never how much: every amount is computed in the database from the accepted plan.
//   POST { action: "checkout_start", business_id, idempotency_key }
//        -> { status: "open", client_secret, publishable_key, mode, amount_minor, currency, expires_at } for Stripe
//           Embedded Checkout (owner, 27 Nov 2026), or { status: "processing" } when Stripe already took the payment
//   POST { action: "checkout_return", business_id }                  -> the payment state, after applying any events;
//        with { card: { brand, last4 } } once confirmed, only when Stripe returns both for the saved card
// The client_secret is passed straight from Stripe to the owner's browser: never stored, never logged.
// Paying from inside the CRM (owner, 27 Nov 2026: "auto charge plus Pay now"; sql/zella_stripe_owner_pay.sql):
//   POST { action: "invoice_pay_status", invoice_id }      -> { invoice } (the owner of its business only; else NOT_FOUND)
//   POST { action: "invoice_pay_start", invoice_id }       -> { status: "open", client_secret, publishable_key, livemode,
//        amount_minor, currency, number, hosted_invoice_url } for Stripe's Payment Element on the invoice's OWN
//        PaymentIntent (confirmation_secret), or { status: "processing" } when Stripe already has it
//   POST { action: "invoice_pay_return", invoice_id }      -> { invoice } after applying any events (paid only from those)
//   POST { action: "card_summary", business_id }           -> { card: { brand, last4 } | null } (the saved card, from Stripe)
//   POST { action: "card_update_start", business_id, idempotency_key } -> { url } of Stripe's Customer Portal, card
//        update only (flow payment_method_update)
//   POST { action: "pack_status", business_id, purchase_id } -> { purchase } after applying any events
//   POST { action: "pack_act_start", business_id, purchase_id } -> the pack's own PaymentIntent for Stripe's form, when
//        the bank asked to confirm or the saved card was declined (never a second charge)
//   POST { action: "pack_buy", business_id, pack_code, idempotency_key } -> { purchase_id, status } (charged on the saved card;
//                                                                    the pack is added when Stripe confirms the payment)
//   POST { action: "refund_options", business_id }  /  { action: "refund_request", business_id, kind, payment_id, idempotency_key }
//                                                                    eligibility decided by the database (REQ-BIL-45)
// Each request first runs the owner's database function with the owner's own sign in (active owner of THAT business,
// a code verified session); only then does the server key send the commands that function queued, so the owner gets
// the Checkout link at once. The return from Stripe is never trusted: it only triggers the same event processing the
// worker runs; access is granted only by a verified, fetched and bound Stripe invoice.
// Off (503) until STRIPE_SECRET_KEY is set (and, to start a checkout, STRIPE_PUBLISHABLE_KEY in the same mode); the
// database refuses while payments_live is false.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withCors } from "../_shared/cors.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { applyEvents, type Rpc, rpcClient, sendOutboxNow } from "../_shared/billingWorker.ts";
import { cardSummary, keyIsLive, publishableKeyLive, type StripeClient, stripeClient } from "../_shared/stripe.ts";

const WORDS: Record<string, string> = {
  NOT_SIGNED_IN: "Please sign in again.",
  NOT_ALLOWED: "Only the business owner can do this.",
  MFA_REQUIRED: "Enter the code from your authenticator app to continue.",
  BUSINESS_NOT_AVAILABLE: "This workspace is paused. Contact Zella Voice support.",
  PAYMENTS_NOT_LIVE: "Payments aren't switched on yet. Nothing has been charged.",
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
  CHECKOUT_EXPIRED: "This payment form expired. Nothing was charged. Start again to get a new one.",
  PAYMENTS_MISCONFIGURED: "Payments can't open right now. Nothing has been charged, and Zella Voice has been told.",
  NOT_FOUND: "We couldn't find that for your account. Check you're signed in as the business owner.",
  NOT_PAYABLE: "This can't be paid online right now. Nothing was charged.",
  NO_CUSTOMER: "Your card is added with your first payment. There's nothing to update yet.",
};
const INVOICE_ACTIONS = new Set(["invoice_pay_status", "invoice_pay_start", "invoice_pay_return"]);
const OPEN_INTENT = new Set(["requires_payment_method", "requires_action", "requires_confirmation"]);
const intentOf = (secret: string) => secret.split("_secret_")[0];
const OPEN_ISH = new Set(["open", "expiring"]);

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
    const refs = async (biz: string) => await rpc("zella_billing_stripe_refs", { p_business_id: biz, p_livemode: stripe.livemode }) as { customer: string | null; subscription: string | null } | null;
    if (body.action === "checkout_start") {
      const publishable = await browserKey();
      if (publishable instanceof Response) return publishable;
      const key = String(body.idempotency_key ?? "");
      // the same key, a second tab or a reload gets the same open checkout (one per business, the database decides)
      const start = await asOwner(url, anon, jwt, "zella_owner_billing_checkout_start", { p_business_id: business, p_idempotency_key: key }) as Record<string, unknown>;
      const checkout = String(start?.checkout_id ?? "");
      if (!UUID.test(checkout)) return refuse("ERROR", 500);
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
      if (row?.status !== "open" || session.ui_mode !== "embedded" || typeof session.client_secret !== "string") return refuse("CHECKOUT_NOT_READY", 502);
      return reply({ status: "open", client_secret: session.client_secret, publishable_key: publishable, livemode: stripe.livemode,
        mode: row.mode, amount_minor: row.amount_minor, currency: row.currency, expires_at: row.expires_at });
    }
    if (body.action === "checkout_return") {
      await asOwner(url, anon, jwt, "zella_owner_onboarding_payment_status", { p_business_id: business });   // the owner check first
      await applyEvents(rpc, stripe, 20, 8).catch(() => null);   // the worker's own step; nothing here trusts the return
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
    if (action === "invoice_pay_status") {
      return reply({ invoice: await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId }) });
    }
    if (action === "invoice_pay_return") {
      await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId });   // the owner check first
      await applyEvents(rpc, stripe, 20, 8).catch(() => null);   // invoice.paid is what marks it paid; nothing here trusts the browser
      return reply({ invoice: await asOwner(url, anon, jwt, "zella_owner_invoice_pay_status", { p_invoice_id: invoiceId }) });
    }
    if (action === "invoice_pay_start") {
      const publishable = await browserKey();
      if (publishable instanceof Response) return publishable;
      const inv = await asOwner(url, anon, jwt, "zella_owner_invoice_pay_start", { p_invoice_id: invoiceId }) as Record<string, any>;
      business = String(inv.business_id);
      const sid = String(inv.stripe_invoice_id ?? "");
      if (!/^in_[A-Za-z0-9_]{1,250}$/.test(sid) || inv.livemode !== stripe.livemode) return refuse("NOT_PAYABLE");
      const ref = await refs(business);
      const si = await stripe.get(`/v1/invoices/${sid}`, { expand: ["confirmation_secret"] }) as Record<string, any>;
      // ours: the same invoice, our customer, the key's mode
      if (si.id !== sid || si.livemode !== stripe.livemode || !ref?.customer || (typeof si.customer === "string" ? si.customer : si.customer?.id) !== ref.customer) {
        throw Object.assign(new Error("invoice binding failed"), { binding: true });
      }
      if (si.status === "paid") return reply({ status: "processing" });   // Stripe has it; our record follows from invoice.paid
      if (si.status !== "open") return refuse("NOT_PAYABLE");
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
        currency: inv.currency, number: inv.number, hosted_invoice_url: inv.hosted_invoice_url });
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
      // back to the owner's Payments page (the same panel as Settings, Billing, Invoices and payments)
      const back = `${app.replace(/\/+$/, "")}/pay?business=${business}&card=updated`;
      const portal = await stripe.post("/v1/billing_portal/sessions", { customer: ref.customer, return_url: back,
        flow_data: { type: "payment_method_update", after_completion: { type: "redirect", redirect: { return_url: back } } } }, `portal:${business}:${key}`) as Record<string, any>;
      if (typeof portal.url !== "string" || !portal.url.startsWith("https://")) return refuse("ERROR", 500);
      return reply({ url: portal.url });
    }
    if (action === "pack_status") {
      if (!UUID.test(String(body.purchase_id ?? ""))) return refuse("INVALID_INPUT");
      await asOwner(url, anon, jwt, "zella_owner_pack_status", { p_business_id: business, p_purchase_id: body.purchase_id });
      await applyEvents(rpc, stripe, 20, 8).catch(() => null);
      return reply({ purchase: await asOwner(url, anon, jwt, "zella_owner_pack_status", { p_business_id: business, p_purchase_id: body.purchase_id }) });
    }
    if (action === "pack_act_start") {
      if (!UUID.test(String(body.purchase_id ?? ""))) return refuse("INVALID_INPUT");
      const publishable = await browserKey();
      if (publishable instanceof Response) return publishable;
      const act = await asOwner(url, anon, jwt, "zella_owner_pack_act_start", { p_business_id: business, p_purchase_id: body.purchase_id }) as Record<string, any>;
      const ref = await refs(business);
      const piId = String(act.payment_intent ?? "");
      if (!/^pi_[A-Za-z0-9_]{1,250}$/.test(piId)) return refuse("NOT_PAYABLE");
      const pi = await stripe.get(`/v1/payment_intents/${piId}`) as Record<string, any>;
      if (pi.id !== piId || pi.livemode !== stripe.livemode || pi.metadata?.purchase_id !== String(body.purchase_id) || !ref?.customer || pi.customer !== ref.customer
          || Number(pi.amount) !== Number(act.price_cents)) throw Object.assign(new Error("pack payment binding failed"), { binding: true });
      if (pi.status === "succeeded" || pi.status === "processing") return reply({ status: "processing" });
      if (!OPEN_INTENT.has(String(pi.status)) || typeof pi.client_secret !== "string") return refuse("NOT_PAYABLE");
      return reply({ status: "open", client_secret: pi.client_secret, publishable_key: publishable, livemode: stripe.livemode, amount_minor: act.price_cents, currency: "usd" });
    }
    if (body.action === "pack_buy") {
      const bought = await asOwner(url, anon, jwt, "zella_owner_pack_buy", { p_business_id: business, p_pack_code: String(body.pack_code ?? ""), p_idempotency_key: String(body.idempotency_key ?? "") }) as Record<string, unknown>;
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
