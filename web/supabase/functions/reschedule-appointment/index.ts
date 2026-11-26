// Zella Voice: the Reschedule button in appointment texts and emails.
//
// Public function (deploy with --no-verify-jwt): the customer is not signed in.
// The long private code in the link identifies one appointment and nothing else.
// All the rules (is the link valid, is the time free) live in the database.
//
//   POST { token, action: "lookup" }                 -> appointment and business
//   POST { token, action: "slots" }                  -> free times
//   POST { token, action: "confirm", start: ISO }    -> moves the appointment
//   The Confirm and Cancel buttons in confirmation and reminder emails open the same page (/r/<code>?do=...), which
//   asks first; only its button calls (sql/zella_email_action_buttons.sql):
//   POST { token, action: "attend_confirm" }         -> confirms the appointment
//   POST { token, action: "attend_cancel" }          -> cancels it
//   Waitlist offers (the /w/<code> page), same kind of private code:
//   POST { token, action: "offer_lookup" }           -> the offered time
//   POST { token, action: "offer_accept" }           -> books it (the calendar re-checks the time)
//   POST { token, action: "offer_decline" }          -> passes it to the next person

import { withCors } from "../_shared/cors.ts";
import { createClient } from "@supabase/supabase-js";
import { readBodyLimited } from "../_shared/body.ts";
import { clientIp } from "../_shared/client_ip.ts";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(data: unknown, status = 200) {
  return Response.json(data, { status, headers: corsHeaders });
}

export const handler = withCors(async (req: Request) => {
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serverSecretKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!supabaseUrl || !serverSecretKey) {
    console.error("reschedule-appointment configuration is missing");
    return respond({ error: "This link can't be used right now. Please contact the business." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    const raw = await readBodyLimited(req, 8000);
    if (raw === null) return respond({ error: "Invalid request" }, 413);
    body = JSON.parse(raw);
  } catch {
    return respond({ error: "Invalid request" }, 400);
  }

  const token = typeof body.token === "string" ? body.token.trim().toLowerCase().slice(0, 100) : "";
  if (!/^[0-9a-f]{64}$/.test(token)) return respond({ ok: false, reason: "invalid" });

  const admin = createClient(supabaseUrl, serverSecretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Rate limits (the shared, concurrency-safe database counter): per visitor address and per link, so a script
  // can't hammer slot lookups or confirmations. A counter that can't be checked refuses (fails closed, M10).
  const ip = clientIp(req.headers) ?? "unknown";   // never the caller-written first X-Forwarded-For value
  const writes = body.action === "confirm" || body.action === "offer_accept" || body.action === "offer_decline"
    || body.action === "attend_confirm" || body.action === "attend_cancel";
  for (const [key, max] of [[`resched:ip:${ip}`, 60], [`resched:token:${token.slice(0, 16)}`, writes ? 10 : 40]] as const) {
    const { data: ok, error: limitError } = await admin.rpc("zella_rate_limit", { p_key: key, p_max: max, p_window_seconds: 60 });
    if (limitError || typeof ok !== "boolean") {
      console.error("rate limit check failed", limitError?.message?.slice(0, 120) ?? "no answer");
      return respond({ ok: false, reason: "busy", error: "This page is busy right now. Please try again in a minute." }, 503);
    }
    if (ok === false) return respond({ ok: false, reason: "busy", error: "Too many tries. Please wait a minute and try again." }, 429);
  }

  let result;
  if (body.action === "offer_lookup") {
    result = await admin.rpc("zella_waitlist_offer_lookup", { p_token: token });
  } else if (body.action === "offer_accept" || body.action === "offer_decline") {
    result = await admin.rpc("zella_waitlist_offer_answer", { p_token: token, p_accept: body.action === "offer_accept" });
  } else if (body.action === "attend_confirm" || body.action === "attend_cancel") {
    result = await admin.rpc("zella_reschedule_attend", { p_token: token, p_action: body.action === "attend_confirm" ? "confirm" : "cancel" });
  } else if (body.action === "slots") {
    result = await admin.rpc("zella_reschedule_slots", { p_token: token, p_days: 14 });
  } else if (body.action === "confirm") {
    const start = typeof body.start === "string" ? new Date(body.start) : null;
    if (!start || isNaN(start.getTime())) return respond({ error: "Invalid time" }, 400);
    result = await admin.rpc("zella_reschedule_confirm", { p_token: token, p_start: start.toISOString() });
  } else {
    result = await admin.rpc("zella_reschedule_lookup", { p_token: token });
  }

  if (result.error) {
    console.error("reschedule-appointment failed", result.error.message);
    return respond({ error: "Something went wrong. Please try again." }, 500);
  }
  return respond(result.data);
});

if (import.meta.main) Deno.serve(handler);
