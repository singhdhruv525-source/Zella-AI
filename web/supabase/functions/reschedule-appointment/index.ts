// Zella: the Reschedule button in appointment texts and emails.
//
// Public function (deploy with --no-verify-jwt): the customer is not signed in.
// The long private code in the link identifies one appointment and nothing else.
// All the rules (is the link valid, is the time free) live in the database.
//
//   POST { token, action: "lookup" }                 -> appointment and business
//   POST { token, action: "slots" }                  -> free times
//   POST { token, action: "confirm", start: ISO }    -> moves the appointment
//   Waitlist offers (the /w/<code> page), same kind of private code:
//   POST { token, action: "offer_lookup" }           -> the offered time
//   POST { token, action: "offer_accept" }           -> books it (the calendar re-checks the time)
//   POST { token, action: "offer_decline" }          -> passes it to the next person

import { withCors } from "../_shared/cors.ts";
import { createClient } from "@supabase/supabase-js";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(data: unknown, status = 200) {
  return Response.json(data, { status, headers: corsHeaders });
}

Deno.serve(withCors(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serverSecretKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!supabaseUrl || !serverSecretKey) {
    console.error("reschedule-appointment configuration is missing");
    return respond({ error: "This link can't be used right now. Please contact the business." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return respond({ error: "Invalid request" }, 400);
  }

  const token = typeof body.token === "string" ? body.token.trim().toLowerCase().slice(0, 100) : "";
  if (!/^[0-9a-f]{64}$/.test(token)) return respond({ ok: false, reason: "invalid" });

  const admin = createClient(supabaseUrl, serverSecretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let result;
  if (body.action === "offer_lookup") {
    result = await admin.rpc("zella_waitlist_offer_lookup", { p_token: token });
  } else if (body.action === "offer_accept" || body.action === "offer_decline") {
    result = await admin.rpc("zella_waitlist_offer_answer", { p_token: token, p_accept: body.action === "offer_accept" });
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
}));
