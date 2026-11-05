// Zella - Google Ads lead form webhook. Each lead form's webhook is set to this address with the business's Google key
// (created in Settings > Integrations, shown once). The key inside the payload identifies the business; the database
// checks it, ignores Google's retries of the same lead, and creates the lead (sql/zella_google_leads.sql).
// verify_jwt is off because Google has no Zella login. Replies: 200 stored / already seen / test, 401 wrong or revoked
// key, 429 too many, 400 not a lead, 503 try again (Google retries non-200 answers).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const serverKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!serverKey) return json({ ok: false, error: "try_again" }, 503);

  const raw = await req.text();
  if (raw.length > 50000) return json({ ok: false, error: "too_large" }, 413);
  let payload: unknown;
  try { payload = JSON.parse(raw); } catch { return json({ ok: false, error: "bad_json" }, 400); }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return json({ ok: false, error: "bad_json" }, 400);

  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/zella_capture_google_lead`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: serverKey, Authorization: `Bearer ${serverKey}` },
    body: JSON.stringify({ p_payload: payload }),
  });
  if (!res.ok) return json({ ok: false, error: "try_again" }, 503);
  const out = await res.json();
  // never echo customer data back
  const status = out.ok ? 200 : out.error === "bad_key" ? 401 : out.error === "too_many_requests" ? 429
    : out.error === "bad_payload" ? 400 : out.error === "business_unavailable" ? 410 : 503;
  return json({ ok: Boolean(out.ok), ...(out.duplicate ? { duplicate: true } : {}), ...(out.test ? { test: true } : {}), ...(out.ok ? {} : { error: out.error }) }, status);
});
