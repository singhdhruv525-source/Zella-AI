// Zella Voice: billing worker (docs/PAYMENTS_ARCHITECTURE.md §6.0b, §8). Called every minute by the
// zella_billing_worker job (created off; zella_payments_switch turns it on) with the X-Zella-Secret header from the
// Vault, which the database checks. Sends the outbox to Stripe and applies stored events to objects fetched from
// Stripe. Off (503) until STRIPE_SECRET_KEY is set; the database claims nothing while payments_live is false.
// verify_jwt is off: the secret header is the proof.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { rpcClient, runWorkerOnce } from "../_shared/billingWorker.ts";
import { keyIsLive, stripeClient } from "../_shared/stripe.ts";

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const apiKey = Deno.env.get("STRIPE_SECRET_KEY");
  const serverKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  if (!apiKey || !serverKey || !url) return new Response("billing worker not configured", { status: 503 });
  await req.body?.cancel();
  const rpc = rpcClient(url, serverKey);
  const given = req.headers.get("x-zella-secret") ?? "";
  if (given.length < 32 || given.length > 200 || (await rpc("zella_billing_worker_check", { p_secret: given }).catch(() => false)) !== true) {
    return new Response("not allowed", { status: 401 });
  }
  // STRIPE_API_BASE (the local fake) is honoured only with a sandbox key, never with a live one
  const stripe = stripeClient({ secretKey: apiKey, baseUrl: (!keyIsLive(apiKey) && Deno.env.get("STRIPE_API_BASE")) || undefined });
  try {
    return Response.json(await runWorkerOnce(rpc, stripe));
  } catch (e) {
    console.error("billing worker run failed", e instanceof Error ? e.message : "error");
    return new Response("error", { status: 500 });
  }
}

if (import.meta.main) Deno.serve(handle);
