// Zella Voice: billing API for business owners (docs/PAYMENTS_ARCHITECTURE.md §3, §6.1). The browser says WHAT it
// wants, never how much: every amount is computed in the database from the accepted plan.
//   POST { action: "checkout_start", business_id, idempotency_key }
//        -> { status: "open", client_secret, publishable_key, mode, amount_minor, currency, expires_at } for Stripe
//           Embedded Checkout (owner, 27 Nov 2026), or { status: "processing" } when Stripe already took the payment
//   POST { action: "checkout_return", business_id }                  -> the payment state, after applying any events;
//        with { card: { brand, last4 } } once confirmed, only when Stripe returns both for the saved card
// The client_secret is passed straight from Stripe to the owner's browser: never stored, never logged.
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
};
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
  const business = String(body.business_id ?? "");
  if (!UUID.test(business)) return refuse("INVALID_INPUT");

  const rpc = rpcClient(url, server);
  const stripe = stripeClient({ secretKey: apiKey, baseUrl: (!keyIsLive(apiKey) && Deno.env.get("STRIPE_API_BASE")) || undefined });
  try {
    if (body.action === "checkout_start") {
      // Stripe.js in the owner's browser needs the publishable key, in the same mode as ours: never a test form for a
      // live session or the reverse. A mismatch keeps the Pay step closed and tells Zella Voice.
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
