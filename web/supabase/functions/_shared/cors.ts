// Zella - which websites may call the browser-facing functions (owner-provision-business, continue-plan,
// reschedule-appointment). CORS only stops other websites' pages from reading the answer; every function still
// checks a sign-in token or a private link code itself.
//
// ZELLA_ALLOWED_ORIGINS: comma-separated list, e.g. "https://app.zella.ai,https://my-codespace-3000.app.github.dev".
// ZELLA_APP_URL's origin is always allowed, and so is localhost for development.
// While ZELLA_ALLOWED_ORIGINS is not set, any website is allowed (the behaviour before this file). Set it at go-live.
// Server-to-server callers (Telnyx, Vapi, Stripe, Resend, n8n) send no Origin header and are never affected.

function allowedOrigins(): string[] | null {
  const list = (Deno.env.get("ZELLA_ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);
  if (!list.length) return null;
  try {
    const app = Deno.env.get("ZELLA_APP_URL");
    if (app) list.push(new URL(app).origin);
  } catch { /* a bad ZELLA_APP_URL is reported by the settings page */ }
  return list;
}

const isLocal = (origin: string) => /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);

export function corsFor(origin: string | null): Record<string, string> {
  const base = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const list = allowedOrigins();
  if (!list) return { ...base, "Access-Control-Allow-Origin": "*" };
  if (origin && (list.includes(origin) || isLocal(origin))) return { ...base, "Access-Control-Allow-Origin": origin };
  return base;   // no Allow-Origin: the browser refuses to hand the answer to that page
}

// Wraps a handler so every response, including errors, carries the right CORS headers.
export function withCors(handler: (req: Request) => Response | Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    const cors = corsFor(req.headers.get("origin"));
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    const res = await handler(req);
    const headers = new Headers(res.headers);
    headers.delete("Access-Control-Allow-Origin");
    for (const [k, v] of Object.entries(cors)) headers.set(k, v);
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  };
}
