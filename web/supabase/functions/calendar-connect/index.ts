// Zella Voice - connect a business's Google Calendar or Outlook calendar (sql/zella_calendar_providers.sql).
//   POST { action: "start", business_id, provider }   signed-in owner or admin; answers { url } for the provider's sign-in
//   GET  ?code=...&state=...                         the provider sends the person back here; the code is exchanged for a
//                                                    refresh token, stored in Vault by the database (server key), and the
//                                                    person is sent back to Settings > Calendar connections
// verify_jwt is off (config.toml): the provider's redirect carries no Supabase sign-in. "start" checks the caller's
// sign-in through the database; the redirect is trusted only with a valid signed state, and the database checks again
// that the person is still an owner or admin when the token is stored. Tokens are never logged or returned.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { accountEmail, authorizeUrl, PROVIDER, PROVIDERS, problem, type Provider, signState, tokenForm, verifyState } from "./logic.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) ?? "";
const client = (p: Provider) => p === "google"
  ? { id: env("GOOGLE_CALENDAR_CLIENT_ID"), secret: env("GOOGLE_CALENDAR_CLIENT_SECRET") }
  : { id: env("MICROSOFT_CALENDAR_CLIENT_ID"), secret: env("MICROSOFT_CALENDAR_CLIENT_SECRET") };
const redirectUri = () => env("CALENDAR_REDIRECT_URL") || `${env("SUPABASE_URL")}/functions/v1/calendar-connect`;

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const base = env("SUPABASE_URL"), server = env("ZELLA_SERVER_SECRET_KEY"), anon = env("SUPABASE_ANON_KEY"), linkSecret = env("ZELLA_LINK_SECRET"), app = env("ZELLA_APP_URL");
  if (!base || !server || !anon || linkSecret.length < 32 || !app) return json({ ok: false, error: "not_configured" }, 503);

  if (req.method === "POST") {
    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }
    if (!body || typeof body !== "object" || Array.isArray(body)) return json({ ok: false, error: "bad_request" }, 400);
    const p = body.provider as Provider, biz = String(body.business_id ?? "");
    if (body.action !== "start" || !PROVIDERS.includes(p) || !/^[0-9a-f-]{36}$/i.test(biz)) return json({ ok: false, error: "bad_request" }, 400);
    const auth = req.headers.get("authorization") ?? "";
    if (!/^Bearer\s+\S+/i.test(auth) || auth.includes(server)) return json({ ok: false, error: "sign_in_required" }, 401);
    let user: { id: string };
    try {
      const who = await fetch(`${base}/auth/v1/user`, { headers: { apikey: anon, Authorization: auth }, signal: AbortSignal.timeout(10_000) });
      if (who.status === 401 || who.status === 403) return json({ ok: false, error: "sign_in_required" }, 401);
      if (!who.ok) return json({ ok: false, error: "try_again" }, 502);
      user = await who.json();
      if (!user || typeof user.id !== "string" || !user.id) return json({ ok: false, error: "sign_in_required" }, 401);
      const can = await fetch(`${base}/rest/v1/rpc/zella_calendar_can_manage`, { method: "POST", headers: { "Content-Type": "application/json", apikey: anon, Authorization: auth }, body: JSON.stringify({ p_business_id: biz }), signal: AbortSignal.timeout(10_000) });
      if (can.status === 401) return json({ ok: false, error: "sign_in_required" }, 401);
      if (can.status === 403) return json({ ok: false, error: "not_allowed" }, 403);
      if (!can.ok) return json({ ok: false, error: "try_again" }, 502);
      const allowed = await can.json();
      if (allowed === false) return json({ ok: false, error: "not_allowed" }, 403);
      if (allowed !== true) return json({ ok: false, error: "try_again" }, 502);
    } catch (error) { console.error(error instanceof Error ? error.name : "unknown"); return json({ ok: false, error: "try_again" }, 502); }
    const c = client(p);
    if (!c.id || !c.secret) return json({ ok: false, error: "provider_not_configured", provider: p }, 503);
    const state = await signState(linkSecret, { b: biz, p, u: String(user.id) });
    return json({ ok: true, url: authorizeUrl(p, c.id, redirectUri(), state) }, 200);
  }

  if (req.method === "GET") {
    const q = new URL(req.url).searchParams;
    const back = (outcome: string, reason?: string) => Response.redirect(`${app}/app/settings/calendar/connections?calendar=${outcome}${reason ? `&reason=${encodeURIComponent(reason)}` : ""}`, 302);
    const s = await verifyState(linkSecret, q.get("state") ?? "");
    if (!s) return back("error", "link_expired");
    if (q.get("error")) return back("cancelled", problem(q.get("error")));
    const code = q.get("code");
    if (!code || code.length > 4096) return back("error", "no_code");
    const c = client(s.p);
    if (!c.id || !c.secret) return back("error", "provider_not_configured");
    const tok = await fetch(PROVIDER[s.p].token, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: tokenForm(s.p, c.id, c.secret, redirectUri(), code) }).catch(() => null);
    const t = tok ? await tok.json().catch(() => ({})) : {};
    if (!tok?.ok || typeof t.refresh_token !== "string") return back("error", tok?.ok ? "no_refresh_token" : problem(t.error ?? "token_exchange_failed"));
    const saved = await fetch(`${base}/rest/v1/rpc/zella_calendar_connect_provider`, {
      method: "POST", headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` },
      body: JSON.stringify({ p_business_id: s.b, p_provider: s.p, p_actor: s.u, p_account_email: accountEmail(t.id_token), p_refresh_token: t.refresh_token, p_calendar_id: "primary" }),
    }).catch(() => null);
    if (!saved?.ok) return back("error", saved && /NOT_ALLOWED/.test(await saved.text()) ? "not_allowed" : "try_again");
    return back("connected");
  }
  return json({ ok: false, error: "method_not_allowed" }, 405);
}

if (import.meta.main) Deno.serve(handle);
