// Zella Voice - the business's own email address (owner, 26 Nov 2026; docs/ARCHITECTURE.md §14.4,
// sql/zella_business_email.sql). Used by the Create Business wizard (a Zella Voice admin with businesses.manage) and by
// the business's own Settings (an owner or admin). Every request is signed in; the person comes from their own sign
// in (never the body, TEN-4), and the database decides whether they may (TEN-3) before any provider is asked.
//   POST { action: "domain_start", business_id, address }   the business's address on its own domain: the domain is
//        added at Resend (or found, if Zella Voice's Resend account already has it) and its DNS records are kept, so
//        the setup page can show them step by step. A domain this business set up before is removed at Resend.
//   POST { action: "domain_verify", business_id }            Resend checks the records again; Verified or not yet
//   POST { action: "disconnect", business_id }               back to the fallback; the domain is removed at Resend
// Thin adapter (ARC-3): it authenticates, asks the database, calls Resend once or twice with a time limit, reports
// to the database and answers in short names. Resend's own error text, the key and any token never leave it.
// verify_jwt is off (config.toml) so the mailbox sign in can come back here later; the sign in is checked through Auth.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { withCors } from "../_shared/cors.ts";
import { checkLimits, idKey, type Limit, TOO_MANY_ATTEMPTS } from "../_shared/rate_limit.ts";
import { alreadyAdded, domainStatus, findDomain, readDomain, reason, RESEND, UUID } from "./logic.ts";

const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) ?? "";
const T = 10_000;   // BE-3: every outside call has a time limit

// Rate limits (SEC-12): per person, then per business once the database has said the person may manage it.
// A domain is set up once, with a few checks while DNS changes are seen; these never get in a normal owner's way.
export const USER_LIMIT = { max: 20, seconds: 60 }, BUSINESS_LIMIT = { max: 30, seconds: 60 };
async function limit(base: string, server: string, l: Limit): Promise<Response | null> {
  const answer = await checkLimits(base, server, [l]);
  if (answer === "limited") return json({ ok: false, error: "rate_limited", message: TOO_MANY_ATTEMPTS }, 429);
  if (answer === "unavailable") return json({ ok: false, error: "try_again" }, 502);
  return null;
}

type Signed = { ok: true; id: string } | { ok: false; res: Response };
async function signedIn(req: Request, base: string, anon: string, server: string): Promise<Signed> {
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth) || auth.includes(server)) return { ok: false, res: json({ ok: false, error: "sign_in_required" }, 401) };
  try {
    const who = await fetch(`${base}/auth/v1/user`, { headers: { apikey: anon, Authorization: auth }, signal: AbortSignal.timeout(T) });
    if (who.status === 401 || who.status === 403) return { ok: false, res: json({ ok: false, error: "sign_in_required" }, 401) };
    if (!who.ok) return { ok: false, res: json({ ok: false, error: "try_again" }, 502) };
    const user = await who.json();
    if (!user || typeof user.id !== "string" || !UUID.test(user.id)) return { ok: false, res: json({ ok: false, error: "sign_in_required" }, 401) };
    return { ok: true, id: user.id };
  } catch (error) { console.error("sign in check", error instanceof Error ? error.name : "unknown"); return { ok: false, res: json({ ok: false, error: "try_again" }, 502) }; }
}

// a database rule with the server key; null when the database couldn't be reached or answered an error
async function rpc(base: string, server: string, name: string, body: unknown): Promise<Record<string, unknown> | null> {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/${name}`, { method: "POST", headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` },
      body: JSON.stringify(body), signal: AbortSignal.timeout(T) });
    if (!r.ok) { await r.body?.cancel().catch(() => {}); return null; }
    const v = await r.json();
    return v && typeof v === "object" ? v as Record<string, unknown> : null;
  } catch (error) { console.error("database call", name, error instanceof Error ? error.name : "unknown"); return null; }
}

// one Resend call; { status: 0 } when it timed out or couldn't be reached
async function resend(key: string, method: string, path: string, body?: unknown): Promise<{ status: number; body: unknown }> {
  try {
    const r = await fetch(`${RESEND}${path}`, { method, headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(T) });
    return { status: r.status, body: await r.json().catch(() => null) };
  } catch (error) { console.error("resend", method, error instanceof Error ? error.name : "unknown"); return { status: 0, body: null }; }
}

export const handle = withCors(async (req: Request): Promise<Response> => {
  const base = env("SUPABASE_URL"), server = env("ZELLA_SERVER_SECRET_KEY"), anon = env("SUPABASE_ANON_KEY");
  if (!base || !server || !anon) return json({ ok: false, error: "not_configured" }, 503);
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const read = await readJsonLimited(req, 8_000);   // SEC-12
  if (!read.ok) return json({ ok: false, error: read.error }, read.error === "too_large" ? 413 : 400);
  const body = asObject(read.value);
  const action = body?.action, biz = typeof body?.business_id === "string" ? body.business_id : "";
  if (!body || !["domain_start", "domain_verify", "disconnect"].includes(String(action)) || !UUID.test(biz)) return json({ ok: false, error: "bad_request" }, 400);
  const address = typeof body.address === "string" ? body.address.trim() : "";
  if (action === "domain_start" && (!address || address.length > 254)) return json({ ok: false, error: "bad_address" }, 400);

  const who = await signedIn(req, base, anon, server);
  if (!who.ok) return who.res;
  const mine = await limit(base, server, [`business-email:user:${who.id}`, USER_LIMIT.max, USER_LIMIT.seconds]);
  if (mine) return mine;
  const key = env("RESEND_DOMAINS_API_KEY");
  const business = () => limit(base, server, [`business-email:business:${idKey(biz)}`, BUSINESS_LIMIT.max, BUSINESS_LIMIT.seconds]);

  if (action === "disconnect") {
    const r = await rpc(base, server, "zella_business_email_disconnect", { p_business_id: biz, p_actor: who.id });
    if (!r) return json({ ok: false, error: "try_again" }, 502);
    if (r.ok !== true) return json({ ok: false, error: reason(r.reason) }, r.reason === "NOT_ALLOWED" ? 403 : 400);
    // the domain leaves Zella Voice's Resend account too; if that fails it is said, and the business is disconnected anyway
    let cleanup = "none";
    if (typeof r.removed_domain_id === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(r.removed_domain_id)) {
      const d = key ? await resend(key, "DELETE", `/domains/${r.removed_domain_id}`) : { status: 0 };
      cleanup = d.status >= 200 && d.status < 300 || d.status === 404 ? "removed" : "not_removed";
    }
    return json({ ok: true, changed: r.changed === true, provider_cleanup: cleanup }, 200);
  }

  // the address whose domain is checked: given (start), or the one set up (verify, read with the person's own sign in)
  let want = address;
  if (action === "domain_verify") {
    let status: Record<string, unknown> | null = null;
    try {
      const s = await fetch(`${base}/rest/v1/rpc/zella_business_email_status`, { method: "POST", headers: { "Content-Type": "application/json", apikey: anon, Authorization: req.headers.get("authorization") ?? "" },
        body: JSON.stringify({ p_business_id: biz }), signal: AbortSignal.timeout(T) });
      if (s.status === 401) return json({ ok: false, error: "sign_in_required" }, 401);
      if (!s.ok) { await s.body?.cancel().catch(() => {}); return json({ ok: false, error: s.status === 400 || s.status === 403 ? "not_allowed" : "try_again" }, s.status === 400 || s.status === 403 ? 403 : 502); }
      status = await s.json();
    } catch (error) { console.error("status", error instanceof Error ? error.name : "unknown"); return json({ ok: false, error: "try_again" }, 502); }
    if (status?.route !== "domain" || typeof status.address !== "string") return json({ ok: false, error: "not_set_up" }, 409);
    want = status.address;
  }
  const begin = await rpc(base, server, "zella_business_email_domain_begin", { p_business_id: biz, p_actor: who.id, p_address: want });
  if (!begin) return json({ ok: false, error: "try_again" }, 502);
  if (begin.ok !== true) return json({ ok: false, error: reason(begin.reason) }, begin.reason === "NOT_ALLOWED" ? 403 : 400);
  const theirs = await business();
  if (theirs) return theirs;
  if (!key) return json({ ok: false, error: "provider_not_configured" }, 503);
  const domainName = String(begin.domain), known = typeof begin.resend_domain_id === "string" ? begin.resend_domain_id : null;

  if (action === "domain_verify") {
    if (!known) return json({ ok: false, error: "not_set_up" }, 409);
    const v = await resend(key, "POST", `/domains/${known}/verify`);
    if (v.status === 0 || v.status >= 500) return json({ ok: false, error: "provider_unavailable" }, 502);
    const g = await resend(key, "GET", `/domains/${known}`);
    const d = g.status === 200 ? readDomain(g.body) : null;
    if (!d || d.id !== known) return json({ ok: false, error: g.status === 0 || g.status >= 500 ? "provider_unavailable" : "provider_refused" }, 502);
    const c = await rpc(base, server, "zella_business_email_domain_checked", { p_business_id: biz, p_actor: who.id, p_resend_domain_id: d.id, p_provider_status: d.status, p_records: d.records });
    if (!c) return json({ ok: false, error: "try_again" }, 502);
    if (c.ok !== true) return json({ ok: false, error: reason(c.reason) }, c.reason === "NOT_ALLOWED" ? 403 : 409);
    return json({ ok: true, domain_status: domainStatus(d.status), records: d.records }, 200);
  }

  // domain_start: the domain this business already added, else a new one; one Resend already has is looked up by name
  let d: ReturnType<typeof readDomain> = null;
  if (known) {
    const g = await resend(key, "GET", `/domains/${known}`);
    if (g.status === 0 || g.status >= 500) return json({ ok: false, error: "provider_unavailable" }, 502);
    if (g.status === 200) d = readDomain(g.body);
  }
  if (!d) {
    const made = await resend(key, "POST", "/domains", { name: domainName });
    if (made.status === 0 || made.status >= 500) return json({ ok: false, error: "provider_unavailable" }, 502);
    if (made.status >= 200 && made.status < 300) d = readDomain(made.body);
    else if (alreadyAdded(made.status, made.body)) {
      const list = await resend(key, "GET", "/domains");
      const id = list.status === 200 ? findDomain(list.body, domainName) : null;
      const g = id ? await resend(key, "GET", `/domains/${id}`) : null;
      d = g && g.status === 200 ? readDomain(g.body) : null;
    } else return json({ ok: false, error: "provider_refused" }, 502);
  }
  if (!d || d.name !== domainName) return json({ ok: false, error: "provider_refused" }, 502);
  const saved = await rpc(base, server, "zella_business_email_domain_saved",
    { p_business_id: biz, p_actor: who.id, p_address: want, p_resend_domain_id: d.id, p_records: d.records, p_provider_status: d.status });
  if (!saved) return json({ ok: false, error: "try_again" }, 502);
  if (saved.ok !== true) return json({ ok: false, error: reason(saved.reason) }, saved.reason === "NOT_ALLOWED" ? 403 : 400);
  // a different domain this business set up before leaves Zella Voice's Resend account (best effort)
  if (typeof begin.replaces_domain_id === "string" && begin.replaces_domain_id !== d.id && /^[A-Za-z0-9_-]{1,100}$/.test(begin.replaces_domain_id)) {
    await resend(key, "DELETE", `/domains/${begin.replaces_domain_id}`);
  }
  return json({ ok: true, domain_status: domainStatus(d.status), records: d.records }, 200);
});

if (import.meta.main) Deno.serve(handle);
