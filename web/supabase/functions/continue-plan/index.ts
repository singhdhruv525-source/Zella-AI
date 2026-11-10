// Zella: "Continue my plan" link from the cancellation email.
//
// Public function (deploy with --no-verify-jwt): the business owner is not
// signed in when they click the email link. Access is controlled by the
// signed token instead, which is only valid for one business and one
// specific cancellation date.
//
//   POST { token, action: "preview" }  -> business name and end date
//   POST { token, action: "continue" } -> removes the scheduled cancellation

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

Deno.serve(withCors(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serverSecretKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const linkSecret = Deno.env.get("ZELLA_LINK_SECRET");

  if (!supabaseUrl || !serverSecretKey || !linkSecret) {
    console.error("continue-plan configuration is missing");
    return respond({ error: "This link can't be used right now. Please contact Zella support." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return respond({ error: "Invalid request" }, 400);
  }

  const token = typeof body.token === "string" ? body.token.slice(0, 2000) : "";
  const action = body.action === "continue" ? "continue" : "preview";
  const claims = token ? await verify(linkSecret, token) : null;

  if (!claims) return respond({ status: "invalid" });

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
}));
