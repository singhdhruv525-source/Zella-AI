// The mailbox sign in (OAuth 2.0 authorization code) for Gmail and Outlook, the same pattern as calendar-connect
// (sql/zella_oauth_states.sql): a signed, five minute state that names the business, the provider and the person, with
// a random value whose hash the database keeps and uses up once. Pure, unit tested in oauth_test.ts. Nothing here logs
// or returns a token.
import { accountEmail, newNonce, nonceHash, problem } from "../calendar-connect/logic.ts";
export { accountEmail, newNonce, nonceHash, problem };

export type Mailbox = "gmail" | "outlook";
export const MAILBOXES: Mailbox[] = ["gmail", "outlook"];
// the provider names in oauth_states: kept apart from the calendar's ("google", "outlook"), so a calendar sign in can
// never finish as a mailbox one, or the other way round
export const STATE_PROVIDER: Record<Mailbox, string> = { gmail: "gmail", outlook: "outlook_mail" };
export const STATE_SECONDS = 300;

export const MAIL = {
  gmail: {
    authorize: "https://accounts.google.com/o/oauth2/v2/auth",
    token: "https://oauth2.googleapis.com/token",
    // send email as the person (gmail.send only: Zella Voice never reads the mailbox), and their address
    scope: "openid email https://www.googleapis.com/auth/gmail.send",
    extra: { access_type: "offline", prompt: "consent", include_granted_scopes: "true" },
  },
  outlook: {
    authorize: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    token: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    scope: "offline_access openid email Mail.Send",
    extra: { response_mode: "query", prompt: "select_account" },
  },
} as const;

const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
async function hmac(secret: string, data: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(data))));
}
function same(a: string, b: string) { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; }

// k: "mail" marks a mailbox sign in, and p is signed as the state provider ("gmail" or "outlook_mail"), which the
// calendar's own check refuses: a mailbox state can never finish a calendar sign in, nor the other way round. Verified,
// it is given back as the mailbox ("gmail" or "outlook").
export type MailState = { k: "mail"; b: string; p: Mailbox; u: string; exp: number; n: string };
export async function signMailState(secret: string, s: { b: string; p: Mailbox; u: string; n: string }, now = Date.now() / 1000): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify({ k: "mail", ...s, p: STATE_PROVIDER[s.p], exp: Math.floor(now) + STATE_SECONDS })));
  return `${body}.${await hmac(secret, body)}`;
}
const FROM_STATE: Record<string, Mailbox> = { gmail: "gmail", outlook_mail: "outlook" };
export async function verifyMailState(secret: string, token: string, now = Date.now() / 1000): Promise<MailState | null> {
  const [body, sig, extra] = String(token ?? "").split(".");
  if (!body || !sig || extra !== undefined || !same(sig, await hmac(secret, body))) return null;
  try {
    const s = JSON.parse(new TextDecoder().decode(fromB64url(body)));
    const uuid = /^[0-9a-f-]{36}$/i;
    const p = Object.prototype.hasOwnProperty.call(FROM_STATE, s?.p) ? FROM_STATE[s.p] : null;
    if (!s || s.k !== "mail" || !p || !uuid.test(s.b) || !uuid.test(s.u) || typeof s.exp !== "number" || s.exp < now
        || typeof s.n !== "string" || !/^[A-Za-z0-9_-]{16,64}$/.test(s.n)) return null;
    return { k: "mail", b: s.b, p, u: s.u, exp: s.exp, n: s.n };
  } catch { return null; }
}

// The mailbox's type, from the provider's own sign in (owner, 27 Nov 2026: the daily cap is 80% of that type's limit;
// a type that can't be determined gets the provider's lowest cap). The ID token comes straight from the provider's
// token endpoint over TLS, so its claims are read, not verified again. Google: a Workspace account carries "hd" (its
// domain); a gmail.com address is free Gmail. Microsoft: a personal account (Outlook.com) signs in to Microsoft's
// consumer tenant; any other tenant is Microsoft 365. Anything else: null (not known).
export const MICROSOFT_CONSUMER_TENANT = "9188040d-6c67-4c5b-b112-36a304b66dad";
export function idClaims(idToken: unknown): Record<string, unknown> | null {
  if (typeof idToken !== "string" || idToken.length > 16_000) return null;
  try {
    const c = JSON.parse(new TextDecoder().decode(fromB64url(idToken.split(".")[1] ?? "")));
    return c && typeof c === "object" && !Array.isArray(c) ? c as Record<string, unknown> : null;
  } catch { return null; }
}
export function mailboxKind(p: Mailbox, idToken: unknown): "personal" | "work" | null {
  const c = idClaims(idToken);
  if (!c) return null;
  if (p === "gmail") {
    if (typeof c.hd === "string" && /^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/i.test(c.hd)) return "work";
    return typeof c.email === "string" && /@(gmail|googlemail)\.com$/i.test(c.email) ? "personal" : null;
  }
  const tid = typeof c.tid === "string" ? c.tid.toLowerCase() : "";
  if (tid === MICROSOFT_CONSUMER_TENANT) return "personal";
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(tid) ? "work" : null;
}

export function mailAuthorizeUrl(p: Mailbox, clientId: string, redirectUri: string, state: string, loginHint?: string): string {
  const c = MAIL[p];
  return `${c.authorize}?${new URLSearchParams({ client_id: clientId, redirect_uri: redirectUri, response_type: "code", scope: c.scope, state, ...c.extra,
    ...(loginHint && /^[^@\s]+@[^@\s]+$/.test(loginHint) ? { login_hint: loginHint } : {}) })}`;
}
export function mailTokenForm(p: Mailbox, clientId: string, clientSecret: string, redirectUri: string, code: string): URLSearchParams {
  return new URLSearchParams({ client_id: clientId, client_secret: clientSecret, code, redirect_uri: redirectUri, grant_type: "authorization_code",
    ...(p === "outlook" ? { scope: MAIL.outlook.scope } : {}) });
}
