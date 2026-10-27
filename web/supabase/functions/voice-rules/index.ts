// Zella: the Vapi server endpoint (assistant server URL). Answers, without n8n:
//   tool-calls (call_rules)            every tool call in the request, each under its own toolCallId (zella_ai_voice)
//   transfer-destination-request       the number this call's own business authorised, or a refusal (zella_transfer_destination)
//   status-update                      the call's status, once and in order (zella_record_call_status)
//   end-of-call-report                 the call's record (zella_record_inbound_call / zella_record_call_result)
// Everything else is acknowledged and ignored. The 14 Receptionist Brain tools still go to n8n until phase 3.
//
// Authentication: Vapi's HMAC credential (or Bearer). The database checks the exact request bytes, the signature, the
// timestamp (5 minutes) and that the request was not seen before (zella_vapi_authenticate); the secret lives only in
// Vault. Nothing is read from or written to the database for a request that fails the check.
// Public function (deploy with --no-verify-jwt: Vapi has no Supabase sign-in); the check above is the gate.
// Timing: Vapi waits up to the server timeout (20 s by default). Every database call here gives up after RPC_MS and the
// whole request after BUDGET_MS, answering with a safe failure (assistant takes no action; transfer refused).

import { createClient } from "@supabase/supabase-js";
import { AUTH_OK, authHeaders, plan, toolResult, transferReply, unsupported } from "./logic.ts";

const json = (data: unknown, status = 200) => Response.json(data, { status });
const MAX_BODY = 256 * 1024;
const RPC_MS = Number(Deno.env.get("ZELLA_VOICE_RPC_MS") ?? 4000);
const BUDGET_MS = Number(Deno.env.get("ZELLA_VOICE_BUDGET_MS") ?? 12000);
// deno-lint-ignore no-explicit-any
type Db = any;
type RpcOut = { data: unknown; error: { code?: string; message?: string } | null };

// one database call with a time limit; a timeout or network failure is an error, never an answer
async function call(db: Db, fn: string, args: Record<string, unknown>, ms = RPC_MS): Promise<RpcOut> {
  try {
    const r = await db.rpc(fn, args).abortSignal(AbortSignal.timeout(Math.max(1, ms)));
    if (r.error) console.error(fn + " failed", r.error.code ?? "", (r.error.message ?? "").slice(0, 120));
    return { data: r.data, error: r.error };
  } catch (e) {
    console.error(fn + " failed", String(e).slice(0, 120));
    return { data: null, error: { message: "unreachable" } };
  }
}

Deno.serve(async (req: Request) => {
  const started = Date.now();
  const left = () => Math.min(RPC_MS, BUDGET_MS - (Date.now() - started));
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!url || !key) {
    console.error("voice-rules configuration is missing");
    return json({ error: "Not configured" }, 500);
  }
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "Too large" }, 413);
  // the exact bytes are needed for the signature, so the body is read as text first
  let raw: string;
  try { raw = await req.text(); } catch { return json({ error: "Bad request" }, 400); }
  if (new TextEncoder().encode(raw).length > MAX_BODY) return json({ error: "Too large" }, 413);

  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const auth = await call(db, "zella_vapi_authenticate", { p_raw: raw, p_headers: authHeaders(req.headers) });
  if (auth.error) return json({ error: "Unavailable" }, 503);         // can't check: refuse, never guess
  if (auth.data !== AUTH_OK) {
    console.warn("voice-rules refused a request:", String(auth.data).slice(0, 30));
    return json({ error: "Unauthorized" }, 401);
  }

  let body: unknown;
  try { body = JSON.parse(raw); } catch { return json({ error: "Bad request" }, 400); }
  const p = plan(body);
  if (p.kind === "invalid") return json({ error: "Bad request" }, 400);
  if (p.kind === "ignore") return json(p.reply);

  if (p.kind === "status" || p.kind === "report") {
    // Vapi does not use the answer; a failure is logged and the call is picked up by reconciliation later
    await call(db, p.kind === "status" ? "zella_record_call_status" : p.rpc, p.record, left());
    return json({});
  }

  if (p.kind === "transfer") {
    const r = await call(db, "zella_transfer_destination", {
      p_provider_call_id: p.providerCallId, p_called_number: p.calledNumber, p_vapi_phone_number_id: p.vapiNumberId, p_from_number: p.callerNumber,
    }, left());
    return json(transferReply(!r.error, r.data as Record<string, unknown>));
  }

  // tool calls: one answer per tool call id, in the same request; one failure never loses the others
  const results: Record<string, unknown>[] = [];
  let businessId: string | null = null;
  let looked = false;
  for (const c of p.calls) {
    if (!c.action) { results.push(unsupported(c.toolCallId, c.name)); continue; }
    if (left() < 200) { results.push(toolResult(c.toolCallId, false, null, c.name)); continue; }   // out of time: safe answer
    // a runaway assistant can't hammer the database: 30 tool calls a minute per call (a counter problem never blocks)
    if (p.providerCallId) {
      const rl = await call(db, "zella_rate_limit", { p_key: "voice:" + p.providerCallId, p_max: 30, p_window_seconds: 60 }, left());
      if (!rl.error && rl.data === false) { results.push(toolResult(c.toolCallId, false, null, c.name)); continue; }
    }
    // a registered number always wins over call settings; with no business the database refuses to act
    if (!looked) {
      const found = await call(db, "zella_business_for_number", p.lookup, left());
      if (found.error) { results.push(toolResult(c.toolCallId, false, null, c.name)); continue; }
      businessId = typeof found.data === "string" ? found.data : null;
      looked = true;
    }
    const r = await call(db, "zella_ai_voice", { p_provider_call_id: p.providerCallId, p_business_id: businessId, p_action: c.action, p_args: c.args }, left());
    results.push(toolResult(c.toolCallId, !r.error, r.data as Record<string, unknown>, c.name));
  }
  return json({ results });
});
