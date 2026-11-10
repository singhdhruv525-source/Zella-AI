// Zella - public website lead endpoint. A business's website form or chat widget posts here.
// It holds no secrets of its own: the form key identifies the business, and the database does every check
// (allowed websites, spam, rate limits, duplicates, consent). verify_jwt is off because visitors have no login.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const cors = (origin: string | null) => ({
  "Access-Control-Allow-Origin": origin ?? "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});
const json = (body: unknown, status: number, origin: string | null) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(origin), "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405, origin);

  const serverKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!serverKey) return json({ ok: false, error: "try_again", message: "Something went wrong. Please try again or call us." }, 503, origin);

  const raw = await req.text();
  if (raw.length > 12000) return json({ ok: false, error: "too_large" }, 413, origin);
  let b: Record<string, unknown>;
  try { b = JSON.parse(raw); } catch { return json({ ok: false, error: "bad_json" }, 400, origin); }
  if (typeof b !== "object" || b === null || Array.isArray(b)) return json({ ok: false, error: "bad_json" }, 400, origin);

  const str = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : null);
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;
  const source = typeof b.source === "object" && b.source !== null ? b.source : {};

  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/zella_capture_web_lead`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: serverKey,
    },
    body: JSON.stringify({
      p_public_key: str(b.key, 64),
      p_kind: str(b.kind, 40),
      p_name: str(b.name, 120),
      p_phone: str(b.phone, 40),
      p_email: str(b.email, 254),
      p_message: str(b.message, 2000),
      p_source: source,
      p_marketing_consent: b.marketing_consent === true,
      p_origin: origin,
      p_ip: ip,
      p_honeypot: str(b.website_url, 200),
      p_channel: b.channel === "website_chat" ? "website_chat" : "website",
    }),
  });
  if (!res.ok) return json({ ok: false, error: "try_again", message: "Something went wrong. Please try again or call us." }, 502, origin);
  const out = await res.json();
  const status = out.ok ? 200 : out.error === "too_many_requests" ? 429 : out.error === "origin_not_allowed" ? 403 : 400;
  return json(out, status, origin);
});
