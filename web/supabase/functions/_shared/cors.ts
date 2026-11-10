// Zella - which websites may call the browser-facing functions (owner-provision-business, continue-plan,
// reschedule-appointment). CORS only stops other websites' pages from reading the answer; every function still
// checks a sign-in token or a private link code itself.
//
// ZELLA_ALLOWED_ORIGINS: comma-separated list, e.g. "https://app.zella.ai,https://my-codespace-3000.app.github.dev".
// ZELLA_APP_URL's origin is always allowed, and so is localhost for development.
// With neither ZELLA_ALLOWED_ORIGINS nor ZELLA_APP_URL set (a project that isn't hosted yet), any website is
// allowed, as before. As soon as either is set, only those origins (and localhost) are: setting ZELLA_APP_URL at
// go-live is enough to close the wildcard, so a forgotten ZELLA_ALLOWED_ORIGINS no longer leaves it open.
// Server-to-server callers (Telnyx, Vapi, Stripe, Resend, n8n) send no Origin header and are never affected.

function allowedOrigins(): string[] | null {
  const list = (Deno.env.get("ZELLA_ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);
  const app = Deno.env.get("ZELLA_APP_URL");
  if (!list.length && !app) return null;   // not hosted yet: any website, as before
  try {
    if (app) list.push(new URL(app).origin);
  } catch { /* a bad ZELLA_APP_URL is reported by the settings page; the list stays closed */ }
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
