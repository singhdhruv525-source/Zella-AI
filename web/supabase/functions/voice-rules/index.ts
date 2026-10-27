// Zella: the phone assistant's call_rules tool, answered by the backend directly.
//
// Vapi calls this DURING a call (a server tool). Every decision is made by the database (zella_ai_voice): open or
// closed, take a message, emergency, reach a person, and spam screening. n8n is not on this path, so a slow or
// stopped workflow can never let a blocked caller through or hold a call up. The Spam Response workflow only does
// the follow-up afterwards (alerts, investigation, reports).
//
// Public function (deploy with --no-verify-jwt): Vapi sends the shared secret in the X-Zella-Secret header
// (ZELLA_VAPI_SECRET). Same request and reply as the n8n "Zella - Voice Rules" webhook, so only the tool URL changes.
// If the database can't be reached the assistant is told to take no action and say the team will call back.

import { createClient } from "@supabase/supabase-js";
import { FAILED, plan, reply, sameSecret } from "./logic.ts";

const json = (data: unknown, status = 200) => Response.json(data, { status });

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

  let body: unknown;
  try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  const p = plan(body);
  if (p.kind === "ignore") return json(p.reply);

  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  try {
    // A runaway assistant can't hammer the database: 30 tool calls a minute per call (a counter problem never blocks).
    if (p.providerCallId) {
      const { data: allowed, error } = await db.rpc("zella_rate_limit", { p_key: "voice:" + p.providerCallId, p_max: 30, p_window_seconds: 60 });
      if (!error && allowed === false) return json({ results: [{ toolCallId: p.toolCallId, result: JSON.stringify({ status: "error", instruction: FAILED }) }] });
    }
    // A registered number always wins over call settings; with no business the database refuses to act.
    const { data: found } = await db.rpc("zella_business_for_number", p.lookup);
    const businessId = typeof found === "string" ? found : null;
    const { data, error } = await db.rpc("zella_ai_voice", { p_provider_call_id: p.providerCallId, p_business_id: businessId, p_action: p.action, p_args: p.args });
    if (error) {
      console.error("zella_ai_voice failed", error.code ?? "", (error.message ?? "").slice(0, 120));
      return json(reply(p.toolCallId, false, null));
    }
    return json(reply(p.toolCallId, true, data as Record<string, unknown>));
  } catch (e) {
    console.error("voice-rules failed", String(e).slice(0, 120));
    return json(reply(p.toolCallId, false, null));
  }
});
