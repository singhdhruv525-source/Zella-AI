// Zella Voice - identity provider webhook (docs/OWNER_ONBOARDING_CONTRACT.md section 7). Receives a provider's
// result for an owner's identity check, checks its signature over the exact bytes received, and hands it to the
// database (zella_identity_provider_event, sql/zella_owner_onboarding.sql), which processes each event once, binds it
// to a business only through the reference that business gave the provider, and keeps unknown ones as unmapped.
//
// Off by default. It answers 503 not_enabled unless IDENTITY_WEBHOOK_ENABLED is "true", IDENTITY_WEBHOOK_SECRET is
// set, and the database's rule (zella_onboarding_rules().identity_provider) names this provider; today it is "none"
// (manual upload, checked in Verification). No provider is called from here.
// verify_jwt is off (config.toml) because the provider cannot send a sign in token; the signature is the proof.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { MAX_BODY_BYTES, persona, SIGNATURE_HEADERS, statusFor, verifySignature } from "./logic.ts";

const PROVIDER = persona;   // the provider this receiver reads; its name must match the database's rule
const TIMEOUT_MS = 10_000;  // BE-3
const text = (body: string, status: number) => new Response(body, { status, headers: { "Content-Type": "text/plain" } });

// The body's exact bytes, never more than the limit (SEC-12). null when too large.
async function readBytes(req: Request): Promise<Uint8Array | null> {
  if (Number(req.headers.get("content-length")) > MAX_BODY_BYTES) return null;
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) { await reader.cancel().catch(() => {}); return null; }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.byteLength; }
  return all;
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return text("method not allowed", 405);
  const enabled = Deno.env.get("IDENTITY_WEBHOOK_ENABLED") === "true";
  const secret = Deno.env.get("IDENTITY_WEBHOOK_SECRET") ?? "";
  const server = Deno.env.get("ZELLA_SERVER_SECRET_KEY"), base = Deno.env.get("SUPABASE_URL");
  if (!enabled || !secret || !server || !base) return text("not_enabled", 503);

  let raw: Uint8Array | null;
  try { raw = await readBytes(req); } catch { return text("bad body", 400); }
  if (raw === null) return text("too large", 413);
  const header = SIGNATURE_HEADERS.map((h) => req.headers.get(h)).find((v) => v) ?? null;
  if (!(await verifySignature(raw, header, secret))) return text("bad signature", 401);   // checked before parsing

  let body: unknown;
  try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); } catch { return text("bad json", 400); }
  const parsed = PROVIDER.parseEvent(body);
  if ("invalid" in parsed) return text("unprocessable", 422);
  const e = parsed.event;

  const res = await fetch(`${base}/rest/v1/rpc/zella_identity_provider_event`, {
    method: "POST", signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` },
    body: JSON.stringify({ p_provider: PROVIDER.name, p_event_id: e.eventId, p_reference: e.reference, p_outcome: e.outcome, p_occurred_at: e.occurredAt }),
  }).catch(() => null);
  if (!res?.ok) return text("error", 500);   // the provider retries
  let out: unknown;
  try { out = await res.json(); } catch { return text("error", 500); }
  const s = statusFor((out as { result?: unknown } | null)?.result);
  return text(s.text, s.status);
}

if (import.meta.main) Deno.serve(handle);
