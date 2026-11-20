// Zella Voice: billing webhook (Stripe). It does two things only (docs/PAYMENTS_ARCHITECTURE.md §6.0b): prove the
// event came from Stripe, and store it once. It never grants anything: the billing worker fetches the object from
// Stripe and the database applies it after the binding check.
//   - Stripe-Signature: HMAC SHA256 over "<t>.<raw body>", every v1 compared in constant time, t within 5 minutes.
//     STRIPE_WEBHOOK_SECRET_PREVIOUS is also accepted during a planned rotation (unset otherwise).
//   - livemode must match the key's mode (STRIPE_SECRET_KEY: sk_live_/rk_live_ is live), so a sandbox event can never
//     reach live and the reverse; a mismatch is refused (400) and nothing is stored.
//   - Body limit 500 KB. Unknown event types are acknowledged (200) and not stored. A repeated event id is 200.
// Off (503) until STRIPE_WEBHOOK_SECRET and STRIPE_SECRET_KEY are set. verify_jwt is off: the signature is the proof.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { keyIsLive, verifyStripeSignature } from "../_shared/stripe.ts";

const LIMIT = 500_000;

async function readLimited(req: Request): Promise<string | null | "too_large"> {
  if (Number(req.headers.get("content-length")) > LIMIT) return "too_large";
  const reader = req.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > LIMIT) { await reader.cancel(); return "too_large"; }
      chunks.push(value);
    }
  } catch { return null; } finally { reader.releaseLock(); }
  const all = new Uint8Array(bytes);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.byteLength; }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(all); } catch { return null; }
}

// The database's answer -> HTTP status. Stored, repeated and ignored events are 200 so Stripe stops resending.
export function httpStatusFor(result: unknown): number {
  if (result === "stored" || result === "duplicate" || result === "ignored") return 200;
  if (result === "mode_mismatch" || result === "bad_event") return 400;
  return 500;
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  const apiKey = Deno.env.get("STRIPE_SECRET_KEY");
  const serverKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  if (!secret || !apiKey || !serverKey || !url) return new Response("billing webhook not configured", { status: 503 });
  const raw = await readLimited(req);
  if (raw === "too_large") return new Response("too large", { status: 413 });
  if (raw === null) return new Response("bad body", { status: 400 });
  const secrets = [secret, Deno.env.get("STRIPE_WEBHOOK_SECRET_PREVIOUS") ?? ""];
  if ((await verifyStripeSignature(raw, req.headers.get("stripe-signature"), secrets)) === null) return new Response("bad signature", { status: 400 });
  let ev: Record<string, unknown>;
  try { ev = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  if (!ev || typeof ev !== "object" || typeof ev.id !== "string" || typeof ev.type !== "string") return new Response("bad event", { status: 400 });
  const res = await fetch(`${url}/rest/v1/rpc/zella_stripe_event_store`, {
    method: "POST", signal: AbortSignal.timeout(10_000),
    headers: { "Content-Type": "application/json", apikey: serverKey, Authorization: `Bearer ${serverKey}` },
    body: JSON.stringify({ p_event: ev, p_key_livemode: keyIsLive(apiKey) }),
  }).catch(() => null);
  if (!res?.ok) { await res?.body?.cancel(); return new Response("error", { status: 500 }); }   // Stripe retries
  let out: unknown;
  try { out = await res.json(); } catch { return new Response("error", { status: 500 }); }
  const status = httpStatusFor(out);
  if (status === 400) console.error("billing event refused", ev.type, out);
  return new Response(status === 200 ? "ok" : "refused", { status });
}

if (import.meta.main) Deno.serve(handle);
