// Zella Voice - connect a business's Google Calendar or Outlook calendar (sql/zella_calendar_providers.sql).
//   POST { action: "start", business_id, provider }   signed-in owner or admin; answers { url } for the provider's sign-in.
//                                                    A random value for this one sign in is stored (its hash) for that
//                                                    person, business and provider, valid 5 minutes (sql/zella_oauth_states.sql)
//   GET  ?code=...&state=...                         the provider sends the person back here; nothing is exchanged yet:
//                                                    the code and state go on to the app in the address fragment
//                                                    (never sent to a server), so the app can finish with the person's
//                                                    own sign in
//   POST { action: "finish", code, state }           signed in, the SAME person who started (security audit 18 Nov 2026,
//                                                    2.7): the stored value is used up once, then the code is exchanged
//                                                    for a refresh token, stored in Vault by the database (server key)
// verify_jwt is off (config.toml): the provider's redirect carries no Supabase sign-in. "start" and "finish" check the
// caller's sign-in through Auth; the database checks again that the person is still an owner or admin when the token
// is stored. Tokens are never logged or returned.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { accountEmail, authorizeUrl, newNonce, nonceHash, PROVIDER, PROVIDERS, problem, type Provider, signState, STATE_SECONDS, tokenForm, verifyState } from "./logic.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) ?? "";
const client = (p: Provider) => p === "google"
  ? { id: env("GOOGLE_CALENDAR_CLIENT_ID"), secret: env("GOOGLE_CALENDAR_CLIENT_SECRET") }
  : { id: env("MICROSOFT_CALENDAR_CLIENT_ID"), secret: env("MICROSOFT_CALENDAR_CLIENT_SECRET") };
const redirectUri = () => env("CALENDAR_REDIRECT_URL") || `${env("SUPABASE_URL")}/functions/v1/calendar-connect`;

type Signed = { ok: true; id: string } | { ok: false; res: Response };
// the person behind the request's own sign in (never the server key)
async function signedIn(req: Request, base: string, anon: string, server: string): Promise<Signed> {
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth) || auth.includes(server)) return { ok: false, res: json({ ok: false, error: "sign_in_required" }, 401) };
  try {
    const who = await fetch(`${base}/auth/v1/user`, { headers: { apikey: anon, Authorization: auth }, signal: AbortSignal.timeout(10_000) });
    if (who.status === 401 || who.status === 403) return { ok: false, res: json({ ok: false, error: "sign_in_required" }, 401) };
    if (!who.ok) return { ok: false, res: json({ ok: false, error: "try_again" }, 502) };
    const user = await who.json();
    if (!user || typeof user.id !== "string" || !user.id) return { ok: false, res: json({ ok: false, error: "sign_in_required" }, 401) };
    return { ok: true, id: user.id };
  } catch (error) { console.error(error instanceof Error ? error.name : "unknown"); return { ok: false, res: json({ ok: false, error: "try_again" }, 502) }; }
}
const rpc = (base: string, server: string, name: string, body: unknown) => fetch(`${base}/rest/v1/rpc/${name}`, {
  method: "POST", headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000),
}).catch(() => null);

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const base = env("SUPABASE_URL"), server = env("ZELLA_SERVER_SECRET_KEY"), anon = env("SUPABASE_ANON_KEY"), linkSecret = env("ZELLA_LINK_SECRET"), app = env("ZELLA_APP_URL");
  if (!base || !server || !anon || linkSecret.length < 32 || !app) return json({ ok: false, error: "not_configured" }, 503);

  if (req.method === "POST") {
    const read = await readJsonLimited(req, 16_000);   // SEC-12
    if (!read.ok) return json({ ok: false, error: read.error }, read.error === "too_large" ? 413 : 400);
    const body = asObject(read.value);
    if (!body) return json({ ok: false, error: "bad_request" }, 400);

    if (body.action === "finish") {
      const code = typeof body.code === "string" ? body.code : "", token = typeof body.state === "string" ? body.state : "";
      if (!code || code.length > 4096 || !token || token.length > 2048) return json({ ok: false, error: "bad_request" }, 400);
      const who = await signedIn(req, base, anon, server);
      if (!who.ok) return who.res;
      const s = await verifyState(linkSecret, token);
      if (!s) return json({ ok: false, error: "link_expired" }, 400);
      // the person finishing must be the person who started: someone else approving another owner's sign in is refused
      if (s.u !== who.id) return json({ ok: false, error: "not_your_sign_in" }, 403);
      const used = await rpc(base, server, "zella_oauth_state_consume", { p_nonce_hash: await nonceHash(s.n), p_user_id: s.u, p_business_id: s.b, p_provider: s.p });
      const fresh = used?.ok ? await used.json().catch(() => null) : null;
      if (!used?.ok) return json({ ok: false, error: "try_again" }, 502);
      if (fresh !== true) return json({ ok: false, error: "link_expired" }, 400);   // used already, expired, or never issued
      const c = client(s.p);
      if (!c.id || !c.secret) return json({ ok: false, error: "provider_not_configured" }, 503);
      const tok = await fetch(PROVIDER[s.p].token, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: tokenForm(s.p, c.id, c.secret, redirectUri(), code), signal: AbortSignal.timeout(10_000) }).catch(() => null);
      const t = tok ? await tok.json().catch(() => ({})) : {};
      if (!tok?.ok || typeof t.refresh_token !== "string") return json({ ok: false, error: tok?.ok ? "no_refresh_token" : problem(t.error ?? "token_exchange_failed") }, 400);
      const saved = await rpc(base, server, "zella_calendar_connect_provider",
        { p_business_id: s.b, p_provider: s.p, p_actor: s.u, p_account_email: accountEmail(t.id_token), p_refresh_token: t.refresh_token, p_calendar_id: "primary" });
      // the error body is read under the same deadline: a stalled or aborted read means "try again", never a crash
      if (!saved?.ok) return json({ ok: false, error: saved && /NOT_ALLOWED/.test(await saved.text().catch(() => "")) ? "not_allowed" : "try_again" }, saved ? 400 : 502);
      return json({ ok: true }, 200);
    }

    const p = body.provider as Provider, biz = String(body.business_id ?? "");
    if (body.action !== "start" || !PROVIDERS.includes(p) || !/^[0-9a-f-]{36}$/i.test(biz)) return json({ ok: false, error: "bad_request" }, 400);
    const who = await signedIn(req, base, anon, server);
    if (!who.ok) return who.res;
    try {
      const can = await fetch(`${base}/rest/v1/rpc/zella_calendar_can_manage`, { method: "POST", headers: { "Content-Type": "application/json", apikey: anon, Authorization: req.headers.get("authorization") ?? "" }, body: JSON.stringify({ p_business_id: biz }), signal: AbortSignal.timeout(10_000) });
      if (can.status === 401) return json({ ok: false, error: "sign_in_required" }, 401);
      if (can.status === 403) return json({ ok: false, error: "not_allowed" }, 403);
      if (!can.ok) return json({ ok: false, error: "try_again" }, 502);
      const allowed = await can.json();
      if (allowed === false) return json({ ok: false, error: "not_allowed" }, 403);
      if (allowed !== true) return json({ ok: false, error: "try_again" }, 502);
    } catch (error) { console.error(error instanceof Error ? error.name : "unknown"); return json({ ok: false, error: "try_again" }, 502); }
    const c = client(p);
    if (!c.id || !c.secret) return json({ ok: false, error: "provider_not_configured", provider: p }, 503);
    const n = newNonce();
    const issued = await rpc(base, server, "zella_oauth_state_issue", { p_nonce_hash: await nonceHash(n), p_user_id: who.id, p_business_id: biz, p_provider: p, p_seconds: STATE_SECONDS });
    if (!issued?.ok) return json({ ok: false, error: "try_again" }, 502);
    const state = await signState(linkSecret, { b: biz, p, u: who.id, n });
    return json({ ok: true, url: authorizeUrl(p, c.id, redirectUri(), state) }, 200);
  }

  if (req.method === "GET") {
    const q = new URL(req.url).searchParams;
    const page = `${app}/app/settings/calendar/connections`;
    const back = (outcome: string, reason?: string) => Response.redirect(`${page}?calendar=${outcome}${reason ? `&reason=${encodeURIComponent(reason)}` : ""}`, 302);
    const token = q.get("state") ?? "";
    const s = await verifyState(linkSecret, token);
    if (!s) return back("error", "link_expired");
    if (q.get("error")) return back("cancelled", problem(q.get("error")));
    const code = q.get("code");
    if (!code || code.length > 4096) return back("error", "no_code");
    // nothing is exchanged here: the signed in app finishes it (the fragment never reaches a server or a Referer)
    return Response.redirect(`${page}#${new URLSearchParams({ calendar_code: code, calendar_state: token })}`, 302);
  }
  return json({ ok: false, error: "method_not_allowed" }, 405);
}

if (import.meta.main) Deno.serve(handle);
