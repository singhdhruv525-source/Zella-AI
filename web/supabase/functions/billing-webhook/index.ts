// Zella - billing webhook (Stripe-style events). Checks the provider's signature, turns the event into a plain type and
// hands it to the database (zella_process_billing_event, sql/zella_billing_hardening.sql), which applies each event
// once, keeps events it can't match yet and applies them later, and never moves a subscription or payment backwards.
// Stays switched off (503) until STRIPE_WEBHOOK_SECRET is set. Deploy the SQL first.
// verify_jwt is off because the provider cannot send a login token; the signature is the proof instead.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { httpStatusFor, mapEvent, verifySignature } from "./logic.ts";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  const serverKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!secret || !serverKey) return new Response("billing webhook not configured", { status: 503 });
  const raw = await req.text();
  if (raw.length > 500000 || !(await verifySignature(raw, req.headers.get("stripe-signature"), secret))) return new Response("bad signature", { status: 400 });

  let ev: Record<string, unknown>;
  try { ev = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  if (typeof ev?.id !== "string" || typeof ev?.type !== "string") return new Response("bad event", { status: 400 });

  const mapped = mapEvent(ev);
  if ("ignore" in mapped) return new Response("ignored", { status: 200 });   // an event Zella does not use
  if ("invalid" in mapped) {
    console.error("billing event not understood", ev.type, mapped.invalid);
    return new Response("unprocessable", { status: 422 });
  }

  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/zella_process_billing_event`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: serverKey, Authorization: `Bearer ${serverKey}` },
    body: JSON.stringify({ p_provider: "stripe", p_event_id: ev.id, ...mapped.args }),
  }).catch(() => null);
  if (!res?.ok) return new Response("error", { status: 500 });   // the provider retries
  const out = String(await res.json());
  return new Response(out, { status: httpStatusFor(out) });
});
