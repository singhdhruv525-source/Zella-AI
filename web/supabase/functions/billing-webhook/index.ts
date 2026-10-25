// Zella - billing webhook (Stripe-style events). Checks the provider's signature, turns the event into a plain type and
// hands it to the database, which applies each event once. Stays switched off (503) until STRIPE_WEBHOOK_SECRET is set.
// verify_jwt is off because the provider cannot send a login token; the signature is the proof instead.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

async function verify(raw: string, header: string | null, secret: string): Promise<boolean> {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=") as [string, string]));
  const t = Number(parts["t"]);
  if (!t || Math.abs(Date.now() / 1000 - t) > 300) return false;   // reject old or replayed requests
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${raw}`)));
  return header.split(",").some((p) => p.startsWith("v1=") && p.slice(3) === mac);
}

const iso = (s: unknown) => (typeof s === "number" ? new Date(s * 1000).toISOString() : null);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("billing webhook not configured", { status: 503 });
  const raw = await req.text();
  if (raw.length > 500000 || !(await verify(raw, req.headers.get("stripe-signature"), secret))) return new Response("bad signature", { status: 400 });

  const ev = JSON.parse(raw);
  const o = ev?.data?.object ?? {};
  let args: Record<string, unknown> | null = null;
  switch (ev.type) {
    case "invoice.payment_succeeded":
      args = { p_type: "payment_succeeded", p_external_subscription_id: o.subscription, p_amount: (o.amount_paid ?? 0) / 100, p_currency: o.currency,
               p_external_payment_id: o.payment_intent ?? o.id, p_period_start: iso(o.lines?.data?.[0]?.period?.start), p_period_end: iso(o.lines?.data?.[0]?.period?.end) };
      break;
    case "invoice.payment_failed":
      args = { p_type: "payment_failed", p_external_subscription_id: o.subscription, p_amount: (o.amount_due ?? 0) / 100, p_currency: o.currency,
               p_external_payment_id: o.payment_intent ?? o.id, p_reason: "The card was declined or the payment could not be completed" };
      break;
    case "customer.subscription.deleted":
      args = { p_type: "subscription_cancelled", p_external_subscription_id: o.id };
      break;
    case "customer.subscription.updated":
      if (o.status === "active") args = { p_type: "subscription_renewed", p_external_subscription_id: o.id, p_period_start: iso(o.current_period_start), p_period_end: iso(o.current_period_end) };
      break;
    case "charge.refunded":
    case "charge.dispute.created":
      args = { p_type: "payment_reversed", p_external_payment_id: o.payment_intent, p_reason: ev.type === "charge.refunded" ? "Refund" : "Dispute opened" };
      break;
  }
  if (!args) return new Response("ignored", { status: 200 });   // an event type Zella does not use

  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/zella_process_billing_event`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
    body: JSON.stringify({ p_provider: "stripe", p_event_id: ev.id, ...args }),
  });
  if (!res.ok) return new Response("error", { status: 500 });
  const out = await res.json();
  return new Response(String(out), { status: out === "failed" ? 500 : 200 });   // 500 makes the provider retry
});
