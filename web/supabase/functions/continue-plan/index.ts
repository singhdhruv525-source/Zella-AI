// Zella Voice: "Continue my plan" link from the cancellation email.
// Rate limited per visitor address and per business (SEC-12, see VISITOR_LIMIT below).
//
// Public function (deploy with --no-verify-jwt): the business owner is not
// signed in when they click the email link. Access is controlled by the
// signed token instead, which is only valid for one business and one
// specific cancellation date.
//
//   POST { token, action: "preview" }  -> business name and end date
//   POST { token, action: "continue" } -> removes the scheduled cancellation

import { withCors } from "../_shared/cors.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { createClient } from "@supabase/supabase-js";
import { clientIp } from "../_shared/client_ip.ts";
import { checkLimits, type Limit, TOO_MANY_ATTEMPTS } from "../_shared/rate_limit.ts";

// Rate limits (SEC-12, conformance G-6), counted by the shared database counter before the business is read or
// changed: per visitor address before the link is checked, then per business once the signed link names it. The link
// is opened by the owner, not a signed-in person, so the visitor address stands in for the person. These are
// defaults a normal owner never reaches (the page asks twice: once to show the plan, once to continue it); the owner
// can change them here.
export const VISITOR_LIMIT = { max: 30, seconds: 60 }, BUSINESS_LIMIT = { max: 10, seconds: 60 };

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(data: unknown, status = 200) {
  return Response.json(data, { status, headers: corsHeaders });
}

function base64UrlToBytes(value: string) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

async function verify(secret: string, token: string) {
  const [payload, signature] = token.split(".");
  if (!payload || !signature) return null;

  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );

  let valid = false;
  try {
    // crypto.subtle.verify compares in constant time.
    valid = await crypto.subtle.verify(
      "HMAC", key, base64UrlToBytes(signature), new TextEncoder().encode(payload),
    );
  } catch {
    return null;
  }
  if (!valid) return null;

  try {
    const data = JSON.parse(new TextDecoder().decode(base64UrlToBytes(payload)));
    if (typeof data.b !== "string" || typeof data.c !== "string") return null;
    return { businessId: data.b as string, cancelAt: data.c as string };
  } catch {
    return null;
  }
}

// null when the request may go on; otherwise the answer: 429 over the limit, 503 when the counter can't be checked
async function limit(base: string, server: string, l: Limit): Promise<Response | null> {
  const answer = await checkLimits(base, server, [l]);
  if (answer === "limited") return respond({ error: TOO_MANY_ATTEMPTS }, 429);
  if (answer === "unavailable") return respond({ error: "Something went wrong. Please try again." }, 503);
  return null;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serverSecretKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const linkSecret = Deno.env.get("ZELLA_LINK_SECRET");

  if (!supabaseUrl || !serverSecretKey || !linkSecret) {
    console.error("continue-plan configuration is missing");
    return respond({ error: "This link can't be used right now. Please contact Zella Voice support." }, 500);
  }

  let body: Record<string, unknown>;
  const read = await readJsonLimited(req, 8_000);   // SEC-12
  if (!read.ok) return respond({ error: read.error === "too_large" ? "Request too large" : "Invalid request" }, read.error === "too_large" ? 413 : 400);
  const obj = asObject(read.value);
  if (!obj) return respond({ error: "Invalid request" }, 400);
  body = obj;

  const ip = clientIp(req.headers) ?? "unknown";   // never the caller-written first X-Forwarded-For value
  const visitor = await limit(supabaseUrl, serverSecretKey, [`continue-plan:ip:${ip}`, VISITOR_LIMIT.max, VISITOR_LIMIT.seconds]);
  if (visitor) return visitor;

  const token = typeof body.token === "string" ? body.token.slice(0, 2000) : "";
  const action = body.action === "continue" ? "continue" : "preview";
  const claims = token ? await verify(linkSecret, token) : null;

  if (!claims) return respond({ status: "invalid" });
  const busy = await limit(supabaseUrl, serverSecretKey, [`continue-plan:business:${claims.businessId.toLowerCase()}`, BUSINESS_LIMIT.max, BUSINESS_LIMIT.seconds]);
  if (busy) return busy;

  const admin = createClient(supabaseUrl, serverSecretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: business, error } = await admin
    .from("businesses")
    .select("id, name, cancel_at, cancelled_at")
    .eq("id", claims.businessId)
    .maybeSingle();

  if (error) {
    console.error("continue-plan lookup failed", error);
    return respond({ error: "Something went wrong. Please try again." }, 500);
  }
  if (!business) return respond({ status: "invalid" });

  if (business.cancelled_at) {
    return respond({ status: "ended", businessName: business.name });
  }

  // No cancellation scheduled any more, or a different (newer) one.
  if (!business.cancel_at) {
    return respond({ status: "already_continued", businessName: business.name });
  }
  if (new Date(business.cancel_at).getTime() !== new Date(claims.cancelAt).getTime()) {
    return respond({ status: "outdated", businessName: business.name });
  }

  if (action === "preview") {
    return respond({ status: "scheduled", businessName: business.name, cancelAt: business.cancel_at });
  }

  // Only clears the cancellation if it is still the one this link was for.
  const { data: updated, error: updateError } = await admin
    .from("businesses")
    .update({
      cancel_at: null,
      cancel_requested_at: null,
      cancellation_reason: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", business.id)
    .eq("cancel_at", business.cancel_at)
    .is("cancelled_at", null)
    .select("id");

  if (updateError) {
    console.error("continue-plan update failed", updateError);
    return respond({ error: "Something went wrong. Please try again." }, 500);
  }
  if (!updated?.length) {
    return respond({ status: "already_continued", businessName: business.name });
  }

  const { error: auditError } = await admin.from("audit_logs").insert({
    action: "business.continued_by_owner",
    business_id: business.id,
    entity_type: "business",
    entity_id: business.id,
    old_data: { cancel_at: business.cancel_at },
    new_data: { via: "continue-plan email link" },
    user_agent: req.headers.get("user-agent")?.slice(0, 300) ?? null,
  });
  if (auditError) console.error("continue-plan audit failed", auditError);

  return respond({ status: "continued", businessName: business.name });
}

if (import.meta.main) Deno.serve(withCors(handler));
