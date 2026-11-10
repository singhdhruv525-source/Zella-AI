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

Deno.test("start: an owner gets the provider's sign-in address with a signed state", mock((c) => c.url.endsWith("/auth/v1/user") ? j({ id: U }) : c.url.endsWith("zella_calendar_can_manage") ? j(true) : j({}, 500), async (calls) => {
  const r = await start({ action: "start", business_id: B, provider: "outlook" });
  assertEquals(r.status, 200);
  const url = new URL((await r.json()).url);
  assertEquals(url.origin, "https://login.microsoftonline.com");
  assertEquals(url.searchParams.get("redirect_uri"), "http://db.test/functions/v1/calendar-connect");
  assertEquals(calls[1].headers.Authorization, "Bearer user-jwt"); // permission checked with the person's own sign-in
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
Deno.test("start: provider not configured yet says so", mock((c) => c.url.endsWith("/auth/v1/user") ? j({ id: U }) : j(true), async () => {
  Deno.env.set("MICROSOFT_CALENDAR_CLIENT_ID", "");
  try { const r = await start({ action: "start", business_id: B, provider: "outlook" }); assertEquals([r.status, (await r.json()).error], [503, "provider_not_configured"]); }
  finally { Deno.env.set("MICROSOFT_CALENDAR_CLIENT_ID", "mid"); }
}));
Deno.test("return: the code is exchanged, the token stored by the database with the server key, the person sent back", mock((c) =>
  c.url.startsWith("https://oauth2.googleapis.com/token") ? j({ access_token: "at", refresh_token: "rt-secret", id_token: idToken }) : c.url.endsWith("zella_calendar_connect_provider") ? j("conn-id") : j({}, 500), async (calls) => {
  const r = await back(`code=abc&state=${await signState(SECRET, { b: B, p: "google", u: U })}`);
  assertEquals(r.status, 302);
  assertEquals(r.headers.get("location"), "https://app.test/app/settings/calendar/connections?calendar=connected");
  const form = new URLSearchParams(calls[0].body);
  assertEquals([form.get("code"), form.get("client_secret"), form.get("grant_type")], ["abc", "gsecret", "authorization_code"]);
  const saved = JSON.parse(calls[1].body);
  assertEquals([saved.p_business_id, saved.p_provider, saved.p_actor, saved.p_account_email, saved.p_refresh_token], [B, "google", U, "owner@biz.test", "rt-secret"]);
  assertEquals(calls[1].headers.Authorization, "Bearer server-key");
  assert(!r.headers.get("location")!.includes("rt-secret"));
}));
Deno.test("return: a forged or expired state never reaches the provider", mock(() => j({}), async (calls) => {
  assertEquals((await back("code=abc&state=forged.sig")).headers.get("location"), "https://app.test/app/settings/calendar/connections?calendar=error&reason=link_expired");
  assertEquals((await back(`code=abc&state=${await signState(SECRET, { b: B, p: "google", u: U }, Date.now() / 1000 - 900)}`)).headers.get("location")?.includes("link_expired"), true);
  assertEquals(calls.length, 0);
}));
Deno.test("return: the person declined at the provider", mock(() => j({}), async (calls) => {
  const r = await back(`error=access_denied&state=${await signState(SECRET, { b: B, p: "outlook", u: U })}`);
  assertEquals(r.headers.get("location"), "https://app.test/app/settings/calendar/connections?calendar=cancelled&reason=access_denied");
  assertEquals(calls.length, 0);
}));
Deno.test("return: no refresh token (offline access not granted) is an error, nothing stored", mock((c) => c.url.includes("microsoftonline") ? j({ access_token: "at" }) : j({}, 500), async (calls) => {
  const r = await back(`code=abc&state=${await signState(SECRET, { b: B, p: "outlook", u: U })}`);
  assertEquals(r.headers.get("location")?.endsWith("reason=no_refresh_token"), true);
  assertEquals(calls.length, 1);
}));
Deno.test("return: the person lost their owner/admin role meanwhile: refused by the database", mock((c) =>
  c.url.includes("microsoftonline") ? j({ refresh_token: "rt" }) : j({ message: "NOT_ALLOWED" }, 400), async () => {
  const r = await back(`code=abc&state=${await signState(SECRET, { b: B, p: "outlook", u: U })}`);
  assertEquals(r.headers.get("location")?.endsWith("reason=not_allowed"), true);
}));
Deno.test("return: the provider refuses the code", mock(() => j({ error: "invalid_grant" }, 400), async () => {
  const r = await back(`code=abc&state=${await signState(SECRET, { b: B, p: "google", u: U })}`);
  assertEquals(r.headers.get("location")?.endsWith("reason=invalid_grant"), true);
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
