// Zella: the phone assistant's call_rules tool, transfer destinations and call status, answered by the backend directly.
//
// Vapi calls this DURING a call. Every decision is made by the database: open or closed, take a message, emergency,
// reach a person (zella_ai_voice), which number a transfer goes to (zella_transfer_destination) and the call's status
// (zella_record_call_status). n8n is not on this path, so a slow or stopped workflow can never let a blocked caller
// through, hold a call up or send a caller to the wrong number. Every tool call in a request gets its own answer.
//
// Public function (deploy with --no-verify-jwt): Vapi sends the shared secret in the X-Zella-Secret header
// (ZELLA_VAPI_SECRET). If the database can't be reached the assistant is told to take no action and say the team will
// call back; a transfer is refused rather than guessed.

import { createClient } from "@supabase/supabase-js";
import { plan, sameSecret, toolResult, transferReply, unsupported } from "./logic.ts";

const json = (data: unknown, status = 200) => Response.json(data, { status });
const MAX_BODY = 256 * 1024;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const secret = Deno.env.get("ZELLA_VAPI_SECRET");
  if (!url || !key || !secret) {
    console.error("voice-rules configuration is missing");
    return json({ error: "Not configured" }, 500);
  }
  if (!sameSecret(req.headers.get("x-zella-secret") ?? "", secret)) return json({ error: "Unauthorized" }, 401);
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "Too large" }, 413);

  let body: unknown;
  try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  const p = plan(body);
  if (p.kind === "ignore") return json(p.reply);

  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

  if (p.kind === "status") {
    const { error } = await db.rpc("zella_record_call_status", p.record);
    if (error) console.error("zella_record_call_status failed", error.code ?? "", (error.message ?? "").slice(0, 120));
    return json({});
  }

  if (p.kind === "transfer") {
    try {
      const { data, error } = await db.rpc("zella_transfer_destination", {
        p_provider_call_id: p.providerCallId, p_called_number: p.calledNumber, p_vapi_phone_number_id: p.vapiNumberId, p_from_number: p.callerNumber,
      });
      if (error) console.error("zella_transfer_destination failed", error.code ?? "", (error.message ?? "").slice(0, 120));
      return json(transferReply(!error, data as Record<string, unknown>));
    } catch (e) {
      console.error("voice-rules transfer failed", String(e).slice(0, 120));
      return json(transferReply(false, null));
    }
  }

  // tool calls: one answer per tool call id, in the same request; one failure never loses the others
  const results: Record<string, unknown>[] = [];
  let businessId: string | null = null;
  let looked = false;
  for (const c of p.calls) {
    if (!c.action) { results.push(unsupported(c.toolCallId)); continue; }
    try {
      // a runaway assistant can't hammer the database: 30 tool calls a minute per call (a counter problem never blocks)
      if (p.providerCallId) {
        const { data: allowed, error } = await db.rpc("zella_rate_limit", { p_key: "voice:" + p.providerCallId, p_max: 30, p_window_seconds: 60 });
        if (!error && allowed === false) { results.push(toolResult(c.toolCallId, false, null)); continue; }
      }
      // a registered number always wins over call settings; with no business the database refuses to act
      if (!looked) {
        const { data: found } = await db.rpc("zella_business_for_number", p.lookup);
        businessId = typeof found === "string" ? found : null;
        looked = true;
      }
      const { data, error } = await db.rpc("zella_ai_voice", { p_provider_call_id: p.providerCallId, p_business_id: businessId, p_action: c.action, p_args: c.args });
      if (error) console.error("zella_ai_voice failed", error.code ?? "", (error.message ?? "").slice(0, 120));
      results.push(toolResult(c.toolCallId, !error, data as Record<string, unknown>));
    } catch (e) {
      console.error("voice-rules failed", String(e).slice(0, 120));
      results.push(toolResult(c.toolCallId, false, null));
    }
  }
  return json({ results });
});
