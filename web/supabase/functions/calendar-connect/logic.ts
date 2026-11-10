// Calendar sign-in (OAuth 2.0 authorization code) for Google Calendar and Outlook / Microsoft 365. Pure functions,
// unit-tested in logic_test.ts. Nothing here logs or returns a token.
export type Provider = "google" | "outlook";
export const PROVIDERS: Provider[] = ["google", "outlook"];
export const STATE_SECONDS = 600;

export const PROVIDER = {
  google: {
    authorize: "https://accounts.google.com/o/oauth2/v2/auth",
    token: "https://oauth2.googleapis.com/token",
    // read and write events on calendars the person chooses to share with the app; their email address
    scope: "openid email https://www.googleapis.com/auth/calendar.events",
    extra: { access_type: "offline", prompt: "consent", include_granted_scopes: "true" },
  },
  outlook: {
    authorize: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    token: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    scope: "offline_access openid email Calendars.ReadWrite",
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

export type State = { b: string; p: Provider; u: string; exp: number; n: string };
// the sign-in state: which business, provider and person, signed so it can't be altered, and short-lived
export async function signState(secret: string, s: Omit<State, "exp" | "n">, now = Date.now() / 1000): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify({ ...s, exp: Math.floor(now) + STATE_SECONDS, n: b64url(crypto.getRandomValues(new Uint8Array(12))) })));
  return `${body}.${await hmac(secret, body)}`;
}
export async function verifyState(secret: string, token: string, now = Date.now() / 1000): Promise<State | null> {
  const [body, sig] = String(token ?? "").split(".");
  if (!body || !sig || !same(sig, await hmac(secret, body))) return null;
  try {
    const s = JSON.parse(new TextDecoder().decode(fromB64url(body))) as State;
    const uuid = /^[0-9a-f-]{36}$/i;
    if (!uuid.test(s.b) || !uuid.test(s.u) || !PROVIDERS.includes(s.p) || typeof s.exp !== "number" || s.exp < now) return null;
    return s;
  } catch { return null; }
}

export function authorizeUrl(p: Provider, clientId: string, redirectUri: string, state: string): string {
  const c = PROVIDER[p];
  return `${c.authorize}?${new URLSearchParams({ client_id: clientId, redirect_uri: redirectUri, response_type: "code", scope: c.scope, state, ...c.extra })}`;
}
export function tokenForm(p: Provider, clientId: string, clientSecret: string, redirectUri: string, code: string): URLSearchParams {
  return new URLSearchParams({ client_id: clientId, client_secret: clientSecret, code, redirect_uri: redirectUri, grant_type: "authorization_code",
    ...(p === "outlook" ? { scope: PROVIDER.outlook.scope } : {}) });
}
// the account's email from the ID token returned by the token endpoint over TLS (OpenID Connect: no signature check is
// needed for a token received directly from the provider's token endpoint)
export function accountEmail(idToken: unknown): string | null {
  if (typeof idToken !== "string") return null;
  try {
    const c = JSON.parse(new TextDecoder().decode(fromB64url(idToken.split(".")[1] ?? "")));
    const e = c.email ?? c.preferred_username ?? c.upn;
    return typeof e === "string" && e.includes("@") ? e.slice(0, 200) : null;
  } catch { return null; }
}
// short, safe names for what went wrong (shown to the owner in the address; never provider text)
export function problem(code: unknown): string {
  return typeof code === "string" ? code.replace(/[^a-z_]/gi, "").slice(0, 40) || "failed" : "failed";
}
