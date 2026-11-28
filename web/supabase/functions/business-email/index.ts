// Zella Voice - the business's own email address (owner, 26 Nov 2026; docs/ARCHITECTURE.md §14.4,
// sql/zella_business_email.sql). Used by the Create Business wizard (a Zella Voice admin with businesses.manage) and by
// the business's own Settings (an owner or admin). Every request is signed in; the person comes from their own sign
// in (never the body, TEN-4), and the database decides whether they may (TEN-3) before any provider is asked.
//   POST { action: "domain_start", business_id, address }   the business's address on its own domain: the domain is
//        added at Resend (or found, if Zella Voice's Resend account already has it) and its DNS records are kept, so
//        the setup page can show them step by step. A domain this business set up before is removed at Resend.
//   POST { action: "domain_verify", business_id }            Resend checks the records again; Verified or not yet
//   POST { action: "disconnect", business_id }               back to the fallback; the domain is removed at Resend
//   Connecting a Gmail or Outlook mailbox (only the business's own owner or admin, who signs in themselves):
//   POST { action: "mailbox_start", business_id, provider }  answers { url } for the provider's sign in; a random value
//        for this one sign in is stored (its hash) for that person, business and mailbox, five minutes
//   GET  ?code=...&state=...                                 the provider sends the person back; nothing is exchanged
//        here: the code and state go on to the app in the address fragment (never sent to a server)
//   POST { action: "mailbox_finish", code, state }           the SAME person, signed in: the stored value is used up once,
//        the code is exchanged for a refresh token, which the database stores in Vault; a domain set up before is
//        removed at Resend; the mailbox's type (Workspace or free Gmail, Microsoft 365 or Outlook.com) is read from
//        the provider's sign in, for its daily cap (owner, 27 Nov 2026)
//   The owner's "Connect your mailbox" link (owner, 27 Nov 2026; sql/zella_business_email_mailbox_link.sql):
//   POST { action: "mailbox_link_send", business_id }       a Zella Voice admin with businesses.manage (Create
//        Business): a one time token is made here, the database keeps its hash bound to the business and its owner (7
//        days), and email S8 with the link is queued in the platform outbox (held as test mode while email_live is off)
//   POST { action: "mailbox_link_open", token }              the owner, signed in: the link is used up once and answers
//        the business, whose Settings page then offers the usual Connect Gmail and Connect Outlook
//   Pending domains (owner, 27 Nov 2026; sql/zella_business_email_pending_domains.sql):
//   POST { action: "domain_remove_pending", business_id, reason }  a Zella Voice admin with businesses.manage removes
//        an unverified domain at once; it is removed at Resend straight away (or later by the queue)
//   POST { action: "domain_removals" } + X-Zella-Secret       the database's daily job (no person): the Resend domains
//        it queued are removed (DELETE /domains/{id}), each reported back with its claim token
// Thin adapter (ARC-3): it authenticates, asks the database, calls Resend once or twice with a time limit, reports
// to the database and answers in short names. Resend's own error text, the key and any token never leave it.
// verify_jwt is off (config.toml): the provider's redirect carries no Supabase sign in. Every POST is checked through Auth.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { withCors } from "../_shared/cors.ts";
import { checkLimits, idKey, type Limit, TOO_MANY_ATTEMPTS } from "../_shared/rate_limit.ts";
import { alreadyAdded, domainStatus, findDomain, LINK_TOKEN, mailboxLinkPath, maskEmail, newLinkToken, readDomain, reason, removalOk, RESEND, tokenHash, UUID } from "./logic.ts";
import { accountEmail, MAIL, type Mailbox, MAILBOXES, mailAuthorizeUrl, mailboxKind, mailTokenForm, newNonce, nonceHash, problem, signMailState, STATE_PROVIDER, STATE_SECONDS, verifyMailState } from "./oauth.ts";
// @ts-ignore: plain JavaScript module shared with the web app (the same catalogue the admin preview shows)
import { renderEmail } from "../_shared/businessEmails.js";

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

const mailClient = (p: Mailbox) => p === "gmail"
  ? { id: env("GOOGLE_MAIL_CLIENT_ID"), secret: env("GOOGLE_MAIL_CLIENT_SECRET") }
  : { id: env("MICROSOFT_MAIL_CLIENT_ID"), secret: env("MICROSOFT_MAIL_CLIENT_SECRET") };
const mailRedirect = () => env("MAILBOX_REDIRECT_URL") || `${env("SUPABASE_URL")}/functions/v1/business-email`;

// The mailbox sign in: start, the provider's redirect back, finish (the same pattern as calendar-connect).
async function mailbox(req: Request, body: Record<string, unknown> | null, base: string, server: string, anon: string): Promise<Response> {
  const linkSecret = env("ZELLA_LINK_SECRET"), app = env("ZELLA_APP_URL");
  if (linkSecret.length < 32 || !app) return json({ ok: false, error: "not_configured" }, 503);
  const page = `${app.replace(/\/+$/, "")}/app/settings/messages/business-email`;

  if (req.method === "GET") {
    const q = new URL(req.url).searchParams;
    const back = (outcome: string, why?: string) => Response.redirect(`${page}?mailbox=${outcome}${why ? `&reason=${encodeURIComponent(why)}` : ""}`, 302);
    const token = q.get("state") ?? "";
    if (!(await verifyMailState(linkSecret, token))) return back("error", "link_expired");
    if (q.get("error")) return back("cancelled", problem(q.get("error")));
    const code = q.get("code");
    if (!code || code.length > 4096) return back("error", "no_code");
    // nothing is exchanged here: the signed in app finishes it (a fragment never reaches a server or a Referer)
    return Response.redirect(`${page}#${new URLSearchParams({ mailbox_code: code, mailbox_state: token })}`, 302);
  }

  const who = await signedIn(req, base, anon, server);
  if (!who.ok) return who.res;
  const mine = await limit(base, server, [`business-email:user:${who.id}`, USER_LIMIT.max, USER_LIMIT.seconds]);
  if (mine) return mine;

  if (body?.action === "mailbox_start") {
    const p = body.provider as Mailbox, biz = String(body.business_id ?? "");
    if (!MAILBOXES.includes(p) || !UUID.test(biz)) return json({ ok: false, error: "bad_request" }, 400);
    const can = await rpcValue(base, server, "zella_business_email_mailbox_can_connect", { p_business_id: biz, p_actor: who.id });
    if (can === null) return json({ ok: false, error: "try_again" }, 502);
    if (can !== true) return json({ ok: false, error: "not_allowed" }, 403);
    const theirs = await limit(base, server, [`business-email:business:${idKey(biz)}`, BUSINESS_LIMIT.max, BUSINESS_LIMIT.seconds]);
    if (theirs) return theirs;
    const c = mailClient(p);
    if (!c.id || !c.secret) return json({ ok: false, error: "provider_not_configured", provider: p }, 503);
    const n = newNonce();
    const issued = await rpcValue(base, server, "zella_oauth_state_issue", { p_nonce_hash: await nonceHash(n), p_user_id: who.id, p_business_id: biz, p_provider: STATE_PROVIDER[p], p_seconds: STATE_SECONDS });
    if (issued !== true) return json({ ok: false, error: "try_again" }, 502);
    return json({ ok: true, url: mailAuthorizeUrl(p, c.id, mailRedirect(), await signMailState(linkSecret, { b: biz, p, u: who.id, n })) }, 200);
  }

  // mailbox_finish
  const code = typeof body?.code === "string" ? body.code : "", token = typeof body?.state === "string" ? body.state : "";
  if (!code || code.length > 4096 || !token || token.length > 2048) return json({ ok: false, error: "bad_request" }, 400);
  const s = await verifyMailState(linkSecret, token);
  if (!s) return json({ ok: false, error: "link_expired" }, 400);
  // the person finishing must be the person who started: someone else approving another owner's sign in is refused
  if (s.u !== who.id) return json({ ok: false, error: "not_your_sign_in" }, 403);
  const theirs = await limit(base, server, [`business-email:business:${idKey(s.b)}`, BUSINESS_LIMIT.max, BUSINESS_LIMIT.seconds]);
  if (theirs) return theirs;
  const used = await rpcValue(base, server, "zella_oauth_state_consume", { p_nonce_hash: await nonceHash(s.n), p_user_id: s.u, p_business_id: s.b, p_provider: STATE_PROVIDER[s.p] });
  if (used === null) return json({ ok: false, error: "try_again" }, 502);
  if (used !== true) return json({ ok: false, error: "link_expired" }, 400);   // used already, expired, or never issued
  const c = mailClient(s.p);
  if (!c.id || !c.secret) return json({ ok: false, error: "provider_not_configured" }, 503);
  let t: Record<string, unknown> = {}, okExchange = false;
  try {
    const tok = await fetch(MAIL[s.p].token, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: mailTokenForm(s.p, c.id, c.secret, mailRedirect(), code), signal: AbortSignal.timeout(T) });
    okExchange = tok.ok; t = await tok.json().catch(() => ({}));
  } catch (error) { console.error("token exchange", error instanceof Error ? error.name : "unknown"); return json({ ok: false, error: "provider_unavailable" }, 502); }
  if (!okExchange || typeof t.refresh_token !== "string") return json({ ok: false, error: okExchange ? "no_refresh_token" : problem(t.error ?? "token_exchange_failed") }, 400);
  const account = accountEmail(t.id_token);
  if (!account) return json({ ok: false, error: "no_account_email" }, 400);
  const saved = await rpc(base, server, "zella_business_email_mailbox_saved", { p_business_id: s.b, p_actor: s.u, p_provider: s.p, p_account_email: account,
    p_refresh_token: t.refresh_token, p_mailbox_kind: mailboxKind(s.p, t.id_token) });
  if (!saved) return json({ ok: false, error: "try_again" }, 502);
  if (saved.ok !== true) return json({ ok: false, error: reason(saved.reason) }, saved.reason === "NOT_ALLOWED" ? 403 : 400);
  // a domain this business set up before leaves Zella Voice's Resend account (best effort)
  const key = env("RESEND_DOMAINS_API_KEY");
  if (key && typeof saved.removed_domain_id === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(saved.removed_domain_id)) await resend(key, "DELETE", `/domains/${saved.removed_domain_id}`);
  return json({ ok: true, account: saved.account ?? account }, 200);
}

// a database rule that answers a single value (true, false); null when it couldn't be reached
async function rpcValue(base: string, server: string, name: string, body: unknown): Promise<unknown> {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/${name}`, { method: "POST", headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` },
      body: JSON.stringify(body), signal: AbortSignal.timeout(T) });
    if (!r.ok) { await r.body?.cancel().catch(() => {}); return null; }
    return await r.json();
  } catch (error) { console.error("database call", name, error instanceof Error ? error.name : "unknown"); return null; }
}

// Remove claimed Resend domains (the database's queue, sql/zella_business_email_pending_domains.sql): one DELETE each,
// each reported back with its claim token. Answers how many were removed and how many wait for a later try.
async function removeClaimed(base: string, server: string, key: string, claimed: unknown): Promise<{ removed: number; waiting: number }> {
  const out = { removed: 0, waiting: 0 };
  for (const c of Array.isArray(claimed) ? claimed : []) {
    if (!c || typeof c !== "object") continue;
    const x = c as Record<string, unknown>;
    if (!UUID.test(String(x.id)) || !UUID.test(String(x.claim_token)) || !/^[A-Za-z0-9_-]{1,100}$/.test(String(x.resend_domain_id))) continue;
    const d = await resend(key, "DELETE", `/domains/${x.resend_domain_id}`);
    const ok = removalOk(d.status);
    await rpcValue(base, server, "zella_business_email_domain_removal_done", { p_id: x.id, p_claim_token: x.claim_token, p_ok: ok, p_http_status: d.status || null });
    if (ok) out.removed++; else out.waiting++;
  }
  return out;
}

// The database's daily job wakes this (zella_business_email_kick_removals) with the secret it keeps in Vault; the
// database checks it (zella_business_email_jobs_check), so no secret lives here. No person, no sign in.
export const JOBS_LIMIT = { max: 30, seconds: 60 };
async function removals(req: Request, base: string, server: string): Promise<Response> {
  const secret = (req.headers.get("x-zella-secret") ?? "").slice(0, 200);
  if (!secret) return json({ ok: false, error: "unauthorized" }, 401);
  const checked = await rpcValue(base, server, "zella_business_email_jobs_check", { p_secret: secret });
  if (checked === null) return json({ ok: false, error: "try_again" }, 502);
  if (checked !== true) return json({ ok: false, error: "unauthorized" }, 401);
  const limited = await limit(base, server, ["business-email:jobs", JOBS_LIMIT.max, JOBS_LIMIT.seconds]);
  if (limited) return limited;
  const key = env("RESEND_DOMAINS_API_KEY");
  if (!key) return json({ ok: false, error: "provider_not_configured" }, 503);   // nothing claimed: the queue keeps them
  const claimed = await rpcValue(base, server, "zella_business_email_domain_removals_claim", { p_limit: 10, p_id: null });
  if (claimed === null) return json({ ok: false, error: "try_again" }, 502);
  const r = await removeClaimed(base, server, key, claimed);
  console.log(JSON.stringify({ business_email_removals: r }));   // counts only
  return json({ ok: true, ...r }, 200);
}

// The admin's "Connect your mailbox" link and removal of a pending domain, and the owner opening the link.
async function adminAndLink(req: Request, body: Record<string, unknown>, base: string, server: string, anon: string): Promise<Response> {
  const action = body.action;
  const biz = typeof body.business_id === "string" ? body.business_id : "";
  const token = typeof body.token === "string" ? body.token : "";
  const why = typeof body.reason === "string" ? body.reason.trim() : "";
  if (action === "mailbox_link_open" ? !LINK_TOKEN.test(token) : !UUID.test(biz)) return json({ ok: false, error: "bad_request" }, 400);
  if (action === "domain_remove_pending" && (why.length < 3 || why.length > 300)) return json({ ok: false, error: "reason_required" }, 400);

  const who = await signedIn(req, base, anon, server);
  if (!who.ok) return who.res;
  const mine = await limit(base, server, [`business-email:user:${who.id}`, USER_LIMIT.max, USER_LIMIT.seconds]);
  if (mine) return mine;

  if (action === "mailbox_link_open") {
    const r = await rpc(base, server, "zella_business_email_mailbox_link_redeem", { p_token_hash: await tokenHash(token), p_actor: who.id });
    if (!r) return json({ ok: false, error: "try_again" }, 502);
    if (r.ok !== true) return json({ ok: false, error: reason(r.reason) }, r.reason === "MAILBOX_LINK_NOT_YOURS" || r.reason === "NOT_OWNER" ? 403 : 400);
    return json({ ok: true, business_id: r.business_id, business_name: r.business_name }, 200);
  }

  // both admin actions: a Zella Voice admin with businesses.manage, asked of the database before anything else
  const can = await rpcValue(base, server, "zella_business_email_platform_admin", { p_business_id: biz, p_actor: who.id });
  if (can === null) return json({ ok: false, error: "try_again" }, 502);
  if (can !== true) return json({ ok: false, error: "not_allowed" }, 403);
  const theirs = await limit(base, server, [`business-email:business:${idKey(biz)}`, BUSINESS_LIMIT.max, BUSINESS_LIMIT.seconds]);
  if (theirs) return theirs;

  if (action === "domain_remove_pending") {
    const r = await rpc(base, server, "zella_business_email_domain_remove_pending", { p_business_id: biz, p_actor: who.id, p_reason: why });
    if (!r) return json({ ok: false, error: "try_again" }, 502);
    if (r.ok !== true) return json({ ok: false, error: reason(r.reason) }, r.reason === "NOT_ALLOWED" ? 403 : 409);
    // removed from the business now; at Resend straight away when possible, otherwise the queue keeps it
    let cleanup = "queued";
    const key = env("RESEND_DOMAINS_API_KEY");
    if (key && typeof r.removal_id === "string" && UUID.test(r.removal_id)) {
      const claimed = await rpcValue(base, server, "zella_business_email_domain_removals_claim", { p_limit: 1, p_id: r.removal_id });
      const done = claimed === null ? null : await removeClaimed(base, server, key, claimed);
      cleanup = done && done.removed === 1 ? "removed" : "queued";
    } else if (!r.removal_id) cleanup = "none";
    return json({ ok: true, provider_cleanup: cleanup }, 200);
  }

  // mailbox_link_send
  const app = env("ZELLA_APP_URL").replace(/\/+$/, "");
  if (!/^https:\/\/[^\s/]+/.test(app)) return json({ ok: false, error: "not_configured" }, 503);
  const t = newLinkToken();
  const r = await rpc(base, server, "zella_business_email_mailbox_link_issue", { p_business_id: biz, p_actor: who.id, p_token_hash: await tokenHash(t) });
  if (!r) return json({ ok: false, error: "try_again" }, 502);
  if (r.ok !== true) return json({ ok: false, error: reason(r.reason) }, r.reason === "NOT_ALLOWED" ? 403 : 409);
  let m: { subject: string; html: string; text: string };
  try {
    // strict: a fact the email needs and the database didn't give stops it, never a made up value
    m = renderEmail("S8", { business: String(r.business_name ?? ""), role: "owner", appUrl: app, linkPath: mailboxLinkPath(biz, t),
      linkExpires: String(r.expires_on ?? ""), ownerInvited: r.owner_invited === true } as never, { strict: true });
  } catch (error) { console.error("render S8", error instanceof Error ? error.message.split(":")[0] : "unknown"); return json({ ok: false, error: "email_not_queued" }, 502); }
  const queued = await rpcValue(base, server, "zella_queue_platform_email", { p_business: biz, p_code: "S8", p_dedupe_key: `email:S8:${r.link_id}:1`, p_to: r.to,
    p_subject: m.subject, p_html: m.html, p_text: m.text, p_mandatory: true, p_user: r.owner_id, p_cc: [] });
  // the link exists but its email didn't queue: the admin sends a new one (which replaces it)
  if (typeof queued !== "string" || !UUID.test(queued)) return json({ ok: false, error: "email_not_queued" }, 502);
  return json({ ok: true, to: maskEmail(r.to), expires_on: r.expires_on, email_live: r.email_live === true, owner_invited: r.owner_invited === true }, 200);
}

export const handle = withCors(async (req: Request): Promise<Response> => {
  const base = env("SUPABASE_URL"), server = env("ZELLA_SERVER_SECRET_KEY"), anon = env("SUPABASE_ANON_KEY");
  if (!base || !server || !anon) return json({ ok: false, error: "not_configured" }, 503);
  if (req.method === "GET") return mailbox(req, null, base, server, anon);
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const read = await readJsonLimited(req, 8_000);   // SEC-12
  if (!read.ok) return json({ ok: false, error: read.error }, read.error === "too_large" ? 413 : 400);
  const body = asObject(read.value);
  if (body?.action === "domain_removals") return removals(req, base, server);
  if (body?.action === "mailbox_start" || body?.action === "mailbox_finish") return mailbox(req, body, base, server, anon);
  if (body?.action === "mailbox_link_send" || body?.action === "mailbox_link_open" || body?.action === "domain_remove_pending") return adminAndLink(req, body, base, server, anon);
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
