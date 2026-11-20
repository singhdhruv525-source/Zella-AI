// calendar-connect with the database, Auth and the providers mocked.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
import { signState } from "./logic.ts";

const SECRET = "local-link-secret-test-only-0123456789abcdef";
for (const [k, v] of Object.entries({ SUPABASE_URL: "http://db.test", ZELLA_SERVER_SECRET_KEY: "server-key", SUPABASE_ANON_KEY: "anon-key", ZELLA_LINK_SECRET: SECRET,
  ZELLA_APP_URL: "https://app.test", GOOGLE_CALENDAR_CLIENT_ID: "gid", GOOGLE_CALENDAR_CLIENT_SECRET: "gsecret", MICROSOFT_CALENDAR_CLIENT_ID: "mid", MICROSOFT_CALENDAR_CLIENT_SECRET: "msecret" })) Deno.env.set(k, v);
const B = "c0000000-0000-0000-0000-000000000004", U = "a0000000-0000-0000-0000-000000000002";
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
const realFetch = globalThis.fetch;
function mock(route: (c: Call) => Response, fn: (calls: Call[]) => Promise<void>) {
  return async () => {
    const calls: Call[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit = {}) => { const c = { url: String(url), method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: String(init.body ?? "") }; calls.push(c); return route(c); }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; }
  };
}
const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s });
const start = (body: unknown, auth = "Bearer user-jwt") => handle(new Request("http://fn/calendar-connect", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", authorization: auth } }));
const back = (qs: string) => handle(new Request(`http://fn/calendar-connect?${qs}`));
const idToken = `h.${btoa(JSON.stringify({ email: "owner@biz.test" })).replace(/=+$/, "")}.s`;

const route = (extra: (c: Call) => Response | null = () => null) => (c: Call) => extra(c) ?? (c.url.endsWith("/auth/v1/user") ? j({ id: c.headers.Authorization === "Bearer other-jwt" ? OTHER : U })
  : c.url.endsWith("zella_calendar_can_manage") || c.url.endsWith("zella_oauth_state_issue") || c.url.endsWith("zella_oauth_state_consume") ? j(true) : j({}, 500));
const OTHER = "a0000000-0000-0000-0000-000000000009";
const finish = (code: string, state: string, auth = "Bearer user-jwt") => handle(new Request("http://fn/calendar-connect", { method: "POST", body: JSON.stringify({ action: "finish", code, state }), headers: { "content-type": "application/json", authorization: auth } }));
const N = "abcdefghijklmnop0123456789ABCDEF";

Deno.test("start: an owner gets the provider's sign-in address; a single use value is stored for them", mock(route(), async (calls) => {
  const r = await start({ action: "start", business_id: B, provider: "outlook" });
  assertEquals(r.status, 200);
  const url = new URL((await r.json()).url);
  assertEquals(url.origin, "https://login.microsoftonline.com");
  assertEquals(url.searchParams.get("redirect_uri"), "http://db.test/functions/v1/calendar-connect");
  assertEquals(calls[1].headers.Authorization, "Bearer user-jwt"); // permission checked with the person's own sign-in
  const issued = JSON.parse(calls[2].body);
  assertEquals([calls[2].url.endsWith("zella_oauth_state_issue"), calls[2].headers.Authorization, issued.p_user_id, issued.p_business_id, issued.p_provider, issued.p_seconds],
    [true, "Bearer server-key", U, B, "outlook", 300]);
  assert(/^[0-9a-f]{64}$/.test(issued.p_nonce_hash) && !url.toString().includes(issued.p_nonce_hash));
}));
Deno.test("start: the sign in isn't handed out when it can't be recorded", mock(route((c) => c.url.endsWith("zella_oauth_state_issue") ? j({}, 500) : null), async () => {
  assertEquals((await start({ action: "start", business_id: B, provider: "google" })).status, 502);
}));
Deno.test("start: staff (database says no) are refused", mock((c) => c.url.endsWith("/auth/v1/user") ? j({ id: U }) : j(false), async () => {
  assertEquals((await start({ action: "start", business_id: B, provider: "google" })).status, 403);
}));
Deno.test("start: not signed in, a bad sign-in, or the server key as a user", mock((c) => c.url.endsWith("/auth/v1/user") ? j({}, 401) : j(true), async (calls) => {
  assertEquals((await start({ action: "start", business_id: B, provider: "google" }, "")).status, 401);
  assertEquals((await start({ action: "start", business_id: B, provider: "google" }, "Bearer server-key")).status, 401);
  assertEquals((await start({ action: "start", business_id: B, provider: "google" }, "Bearer expired")).status, 401);
  assertEquals(calls.length, 1);
}));
Deno.test("start: unknown provider or bad request", mock(() => j(true), async () => {
  assertEquals((await start({ action: "start", business_id: B, provider: "yahoo" })).status, 400);
  assertEquals((await start({ action: "start", business_id: "x", provider: "google" })).status, 400);
}));
Deno.test("start: provider not configured yet says so", mock(route(), async () => {
  Deno.env.set("MICROSOFT_CALENDAR_CLIENT_ID", "");
  try { const r = await start({ action: "start", business_id: B, provider: "outlook" }); assertEquals([r.status, (await r.json()).error], [503, "provider_not_configured"]); }
  finally { Deno.env.set("MICROSOFT_CALENDAR_CLIENT_ID", "mid"); }
}));
Deno.test("return: nothing is exchanged; the code and state go on to the app in the fragment", mock(() => j({}), async (calls) => {
  const st = await signState(SECRET, { b: B, p: "google", u: U, n: N });
  const r = await back(`code=abc&state=${st}`);
  assertEquals(r.status, 302);
  const loc = new URL(r.headers.get("location")!);
  assertEquals([loc.origin + loc.pathname, loc.search], ["https://app.test/app/settings/calendar/connections", ""]);
  const f = new URLSearchParams(loc.hash.slice(1));
  assertEquals([f.get("calendar_code"), f.get("calendar_state")], ["abc", st]);
  assertEquals(calls.length, 0);
}));
Deno.test("return: a forged or expired state never reaches the app", mock(() => j({}), async (calls) => {
  assertEquals((await back("code=abc&state=forged.sig")).headers.get("location"), "https://app.test/app/settings/calendar/connections?calendar=error&reason=link_expired");
  assertEquals((await back(`code=abc&state=${await signState(SECRET, { b: B, p: "google", u: U }, Date.now() / 1000 - 400)}`)).headers.get("location")?.includes("link_expired"), true);
  assertEquals(calls.length, 0);
}));
Deno.test("return: the person declined at the provider", mock(() => j({}), async (calls) => {
  const r = await back(`error=access_denied&state=${await signState(SECRET, { b: B, p: "outlook", u: U })}`);
  assertEquals(r.headers.get("location"), "https://app.test/app/settings/calendar/connections?calendar=cancelled&reason=access_denied");
  assertEquals(calls.length, 0);
}));
Deno.test("finish: the person who started it: the value is used up, the code exchanged and the token stored", mock(route((c) =>
  c.url.startsWith("https://oauth2.googleapis.com/token") ? j({ access_token: "at", refresh_token: "rt-secret", id_token: idToken }) : c.url.endsWith("zella_calendar_connect_provider") ? j("conn-id") : null), async (calls) => {
  const r = await finish("abc", await signState(SECRET, { b: B, p: "google", u: U, n: N }));
  const out = await r.json();
  assertEquals([r.status, out], [200, { ok: true }]);
  const used = calls.find((c) => c.url.endsWith("zella_oauth_state_consume"))!;
  const u = JSON.parse(used.body);
  assertEquals([used.headers.Authorization, u.p_user_id, u.p_business_id, u.p_provider], ["Bearer server-key", U, B, "google"]);
  assertEquals(u.p_nonce_hash, [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(N)))].map((x) => x.toString(16).padStart(2, "0")).join(""));
  assert(calls.indexOf(used) < calls.findIndex((c) => c.url.startsWith("https://oauth2.googleapis.com/token")), "used up before the provider is asked");
  const form = new URLSearchParams(calls.find((c) => c.url.startsWith("https://oauth2"))!.body);
  assertEquals([form.get("code"), form.get("client_secret"), form.get("grant_type")], ["abc", "gsecret", "authorization_code"]);
  const saved = JSON.parse(calls.find((c) => c.url.endsWith("zella_calendar_connect_provider"))!.body);
  assertEquals([saved.p_business_id, saved.p_provider, saved.p_actor, saved.p_account_email, saved.p_refresh_token], [B, "google", U, "owner@biz.test", "rt-secret"]);
  assert(!JSON.stringify(out).includes("rt-secret"));
}));
Deno.test("finish: someone else signed in can't finish another person's sign in (the CSRF in the audit)", mock(route(), async (calls) => {
  const r = await finish("abc", await signState(SECRET, { b: B, p: "google", u: U, n: N }), "Bearer other-jwt");
  assertEquals([r.status, (await r.json()).error], [403, "not_your_sign_in"]);
  assert(!calls.some((c) => c.url.includes("oauth2") || c.url.endsWith("zella_oauth_state_consume")));
}));
Deno.test("finish: not signed in is refused before anything else", mock(route(), async (calls) => {
  assertEquals((await finish("abc", await signState(SECRET, { b: B, p: "google", u: U, n: N }), "")).status, 401);
  assertEquals(calls.length, 0);
}));
Deno.test("finish: a used, expired or unknown value (the database says no) never reaches the provider", mock(route((c) => c.url.endsWith("zella_oauth_state_consume") ? j(false) : null), async (calls) => {
  const r = await finish("abc", await signState(SECRET, { b: B, p: "google", u: U, n: N }));
  assertEquals([r.status, (await r.json()).error], [400, "link_expired"]);
  assert(!calls.some((c) => c.url.includes("oauth2")));
}));
Deno.test("finish: a forged state or a bad body", mock(route(), async (calls) => {
  assertEquals((await finish("abc", "forged.sig")).status, 400);
  assertEquals((await finish("", await signState(SECRET, { b: B, p: "google", u: U }))).status, 400);
  assert(!calls.some((c) => c.url.includes("oauth2") || c.url.includes("rpc/")));
}));
Deno.test("finish: no refresh token (offline access not granted) is an error, nothing stored", mock(route((c) => c.url.includes("microsoftonline") ? j({ access_token: "at" }) : null), async (calls) => {
  const r = await finish("abc", await signState(SECRET, { b: B, p: "outlook", u: U, n: N }));
  assertEquals((await r.json()).error, "no_refresh_token");
  assert(!calls.some((c) => c.url.endsWith("zella_calendar_connect_provider")));
}));
Deno.test("finish: the person lost their owner/admin role meanwhile: refused by the database", mock(route((c) =>
  c.url.includes("microsoftonline") ? j({ refresh_token: "rt" }) : c.url.endsWith("zella_calendar_connect_provider") ? j({ message: "NOT_ALLOWED" }, 400) : null), async () => {
  assertEquals((await (await finish("abc", await signState(SECRET, { b: B, p: "outlook", u: U, n: N }))).json()).error, "not_allowed");
}));
Deno.test("finish: the provider refuses the code", mock(route((c) => c.url.includes("oauth2") ? j({ error: "invalid_grant" }, 400) : null), async () => {
  assertEquals((await (await finish("abc", await signState(SECRET, { b: B, p: "google", u: U, n: N }))).json()).error, "invalid_grant");
}));
Deno.test("other methods: 405", mock(() => j({}), async () => {
  assertEquals((await handle(new Request("http://fn/calendar-connect", { method: "PUT" }))).status, 405);
}));

Deno.test("start: invalid body shapes", mock(() => j(true), async (calls) => {
  for (const body of [null, [], "start", 1]) assertEquals((await start(body)).status, 400);
  assertEquals(calls.length, 0);
}));
Deno.test("start: network and malformed upstream responses fail closed", async () => {
  for (const stage of ["auth", "manage"]) {
    for (const malformed of [false, true]) {
      await mock((c) => {
        if (stage === "manage" && c.url.endsWith("/auth/v1/user")) return j({ id: U });
        if (malformed) return new Response("{");
        throw new Error("network");
      }, async () => {
        assertEquals((await start({ action: "start", business_id: B, provider: "google" })).status, 502);
      })();
    }
  }
});
