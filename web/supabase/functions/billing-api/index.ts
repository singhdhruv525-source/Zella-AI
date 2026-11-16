// Zella Voice: billing API for business owners (docs/PAYMENTS_ARCHITECTURE.md §3, §6.1). The browser says WHAT it
// wants, never how much: every amount is computed in the database from the accepted plan.
//   POST { action: "checkout_start", business_id, idempotency_key }  -> { url } of Stripe Checkout
//   POST { action: "checkout_return", business_id }                  -> the payment state, after applying any events
//   POST { action: "pack_buy", business_id, pack_code, idempotency_key } -> { purchase_id, status } (charged on the saved card;
//                                                                    the pack is added when Stripe confirms the payment)
// Each request first runs the owner's database function with the owner's own sign in (active owner of THAT business,
// a code verified session); only then does the server key send the commands that function queued, so the owner gets
// the Checkout link at once. The return from Stripe is never trusted: it only triggers the same event processing the
// worker runs; access is granted only by a verified, fetched and bound Stripe invoice.
// Off (503) until STRIPE_SECRET_KEY is set; the database refuses while payments_live is false.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withCors } from "../_shared/cors.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { applyEvents, rpcClient, sendOutboxNow } from "../_shared/billingWorker.ts";
import { keyIsLive, stripeClient } from "../_shared/stripe.ts";

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
  UNKNOWN_PACK: "That pack isn't available.",
  IDEMPOTENCY_CONFLICT: "That didn't work. Reload the page and try again.",
  INVALID_INPUT: "That didn't work. Reload the page and try again.",
};
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
      const key = String(body.idempotency_key ?? "");
      const start = await asOwner(url, anon, jwt, "zella_owner_billing_checkout_start", { p_business_id: business, p_idempotency_key: key }) as Record<string, unknown>;
      if (typeof start?.url === "string") return reply({ url: start.url, mode: start.mode, amount_minor: start.amount_minor });
      const checkout = String(start?.checkout_id ?? "");
      if (!UUID.test(checkout)) return refuse("ERROR", 500);
      // customer, product, prices, session: one after the other, each from the outbox with its stored key
      await rpc("zella_billing_checkout_continue", { p_checkout_id: checkout, p_livemode: stripe.livemode });
      for (let i = 0; i < 6; i++) {
        const rows = await rpc("zella_billing_checkout_next_command", { p_checkout_id: checkout }) as string | null;
        if (!rows) break;
        const r = await sendOutboxNow(rpc, stripe, rows);
        if (r !== "sent") break;
      }
      const state = await asOwner(url, anon, jwt, "zella_owner_onboarding_payment_status", { p_business_id: business }) as Record<string, any>;
      const link = state?.checkout?.url;
      if (typeof link !== "string") return reply({ error: "We couldn't open the payment page. Please try again in a minute.", code: "CHECKOUT_NOT_READY" }, 502);
      return reply({ url: link, mode: state.checkout.mode, amount_minor: state.checkout.amount_minor });
    }
    if (body.action === "checkout_return") {
      await asOwner(url, anon, jwt, "zella_owner_onboarding_payment_status", { p_business_id: business });   // the owner check first
      await applyEvents(rpc, stripe, 20, 8).catch(() => null);   // the worker's own step; nothing here trusts the return
      return reply({ payment: await asOwner(url, anon, jwt, "zella_owner_onboarding_payment_status", { p_business_id: business }) });
    }
    if (body.action === "pack_buy") {
      const bought = await asOwner(url, anon, jwt, "zella_owner_pack_buy", { p_business_id: business, p_pack_code: String(body.pack_code ?? ""), p_idempotency_key: String(body.idempotency_key ?? "") }) as Record<string, unknown>;
      const next = await rpc("zella_billing_pack_next_command", { p_purchase_id: bought.purchase_id }) as string | null;
      if (next) await sendOutboxNow(rpc, stripe, next);
      return reply({ purchase_id: bought.purchase_id, status: bought.status });
    }
    return refuse("INVALID_INPUT");
  } catch (e) {
    if (e instanceof DbRefusal) return refuse(e.code, e.status);
    console.error("billing api failed", e instanceof Error ? e.message.slice(0, 120) : "error");
    return refuse("ERROR", 500);
  }
}

if (import.meta.main) Deno.serve(withCors(handle));
