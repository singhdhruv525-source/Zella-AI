// business-email with Auth, the database and Resend mocked: nothing reaches a real provider. Fake keys only.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
import { signMailState } from "./oauth.ts";

for (const [k, v] of Object.entries({ SUPABASE_URL: "http://db.test", ZELLA_SERVER_SECRET_KEY: "server-key", SUPABASE_ANON_KEY: "anon-key",
  RESEND_DOMAINS_API_KEY: "re_test_key", ZELLA_APP_URL: "https://app.test", ZELLA_LINK_SECRET: "local-link-secret-test-only-0123456789abcdef",
  GOOGLE_MAIL_CLIENT_ID: "gid", GOOGLE_MAIL_CLIENT_SECRET: "gsecret", MICROSOFT_MAIL_CLIENT_ID: "mid", MICROSOFT_MAIL_CLIENT_SECRET: "msecret" })) Deno.env.set(k, v);
const B = "c0000000-0000-4000-8000-000000000004", U = "a0000000-0000-4000-8000-000000000002";
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
const realFetch = globalThis.fetch;
const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s });
const DOMAIN = { id: "d_1", name: "salon.example.test", status: "not_started", records: [{ record: "DKIM", name: "resend._domainkey", type: "TXT", ttl: "Auto", status: "not_started", value: "p=MIGf" }] };
// the database and Auth answer as an allowed owner unless a test says otherwise; Resend as a fresh domain
function mock(route: (c: Call) => Response | null, fn: (calls: Call[], limits: Call[]) => Promise<void>, limiter: (c: Call) => Response = () => j(true)) {
  return async () => {
    const calls: Call[] = [], limits: Call[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
      const c = { url: String(url), method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: String(init.body ?? "") };
      if (c.url.endsWith("/rpc/zella_rate_limit")) { limits.push(c); return limiter(c); }
      calls.push(c);
      return route(c) ?? base(c);
    }) as typeof fetch;
    try { await fn(calls, limits); } finally { globalThis.fetch = realFetch; }
  };
}
function base(c: Call): Response {
  if (c.url.endsWith("/auth/v1/user")) return j({ id: U });
  if (c.url.endsWith("zella_business_email_domain_begin")) return j({ ok: true, address: "hello@salon.example.test", domain: "salon.example.test", resend_domain_id: null, replaces_domain_id: null });
  if (c.url.endsWith("zella_business_email_domain_saved") || c.url.endsWith("zella_business_email_domain_checked")) return j({ ok: true, domain_status: "pending" });
  if (c.url.endsWith("zella_business_email_status")) return j({ route: "domain", address: "hello@salon.example.test" });
  if (c.url.endsWith("zella_business_email_disconnect")) return j({ ok: true, changed: true, removed_domain_id: "d_1" });
  if (c.url === "https://api.resend.com/domains" && c.method === "POST") return j(DOMAIN, 201);
  if (c.url.startsWith("https://api.resend.com/domains/d_1")) return c.method === "GET" ? j({ ...DOMAIN, status: "verified" }) : j({ object: "domain", id: "d_1" });
  return j({}, 500);
}
const post = (body: unknown, auth = "Bearer user-jwt") => handle(new Request("http://fn/business-email", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", authorization: auth, origin: "https://app.test" } }));
const start = { action: "domain_start", business_id: B, address: "hello@salon.example.test" };

Deno.test("start: the database says yes first, then Resend adds the domain, then its records are kept", mock(() => null, async (calls) => {
  const r = await post(start);
  const body = await r.json();
  assertEquals([r.status, body.ok, body.domain_status, body.records[0].type], [200, true, "pending", "TXT"]);
  assertEquals(calls.map((c) => c.url.replace("http://db.test/rest/v1/rpc/", "")), ["http://db.test/auth/v1/user", "zella_business_email_domain_begin", "https://api.resend.com/domains", "zella_business_email_domain_saved"]);
  assertEquals(JSON.parse(calls[1].body), { p_business_id: B, p_actor: U, p_address: "hello@salon.example.test" });   // the person from their sign in
  assertEquals([calls[1].headers.Authorization, calls[2].headers.Authorization, JSON.parse(calls[2].body)], ["Bearer server-key", "Bearer re_test_key", { name: "salon.example.test" }]);
  const saved = JSON.parse(calls[3].body);
  assertEquals([saved.p_resend_domain_id, saved.p_provider_status, saved.p_records.length], ["d_1", "not_started", 1]);
  assertEquals(r.headers.get("access-control-allow-origin"), "https://app.test");
}));
Deno.test("start: the actor in the body is never used", mock(() => null, async (calls) => {
  await post({ ...start, actor: "a0000000-0000-4000-8000-000000000999", p_actor: "a0000000-0000-4000-8000-000000000999" });
  assertEquals(JSON.parse(calls[1].body).p_actor, U);
}));
Deno.test("start: a refusal from the database stops before Resend", mock((c) => c.url.endsWith("domain_begin") ? j({ ok: false, reason: "DOMAIN_TAKEN" }) : null, async (calls) => {
  const r = await post(start);
  assertEquals([r.status, (await r.json()).error], [400, "domain_taken"]);
  assert(!calls.some((c) => c.url.includes("resend.com")));
}));
Deno.test("start: staff (database says no) get 403 and Resend is never asked", mock((c) => c.url.endsWith("domain_begin") ? j({ ok: false, reason: "NOT_ALLOWED" }) : null, async (calls) => {
  assertEquals((await post(start)).status, 403);
  assert(!calls.some((c) => c.url.includes("resend.com")));
}));
Deno.test("start: not signed in, a bad sign in, or the server key as a person", mock((c) => c.url.endsWith("/auth/v1/user") ? j({}, 401) : null, async (calls) => {
  assertEquals((await post(start, "")).status, 401);
  assertEquals((await post(start, "Bearer server-key")).status, 401);
  assertEquals((await post(start, "Bearer expired")).status, 401);
  assertEquals(calls.length, 1);
}));
Deno.test("bad requests are refused before anything is asked", mock(() => null, async (calls) => {
  assertEquals((await post({ action: "domain_start", business_id: "x", address: "a@b.test" })).status, 400);
  assertEquals((await post({ action: "drop", business_id: B })).status, 400);
  assertEquals((await post({ action: "domain_start", business_id: B })).status, 400);
  assertEquals((await post({ action: "domain_start", business_id: B, address: "a".repeat(300) })).status, 400);
  assertEquals((await handle(new Request("http://fn/business-email", { method: "POST", body: "x".repeat(9000), headers: { "content-type": "application/json", authorization: "Bearer user-jwt" } }))).status, 413);
  assertEquals(calls.length, 0);
}));
Deno.test("start: a domain Resend already has is found by its exact name", mock((c) => c.url === "https://api.resend.com/domains" && c.method === "POST" ? j({ name: "validation_error", message: "The domain has been registered already." }, 403)
  : c.url === "https://api.resend.com/domains" ? j({ data: [{ id: "d_9", name: "other.example.test" }, { id: "d_1", name: "salon.example.test" }] }) : null, async (calls) => {
  const r = await post(start);
  assertEquals(r.status, 200);
  assertEquals(JSON.parse(calls.find((c) => c.url.endsWith("domain_saved"))!.body).p_resend_domain_id, "d_1");
}));
Deno.test("start: Resend's own error text never reaches the page", mock((c) => c.url.includes("resend.com") ? j({ name: "x", message: "PRIVATE DETAIL" }, 422) : null, async () => {
  const r = await post(start);
  const t = await r.text();
  assertEquals(r.status, 502); assert(t.includes("provider_refused") && !t.includes("PRIVATE"));
}));
Deno.test("start: Resend down or slow is a plain try again, nothing saved", mock((c) => c.url.includes("resend.com") ? j({}, 503) : null, async (calls) => {
  assertEquals([(await post(start)).status], [502]);
  assert(!calls.some((c) => c.url.endsWith("domain_saved")));
}));
Deno.test("start: the domain set up before is reused, and a different old one is removed at Resend", mock((c) => c.url.endsWith("domain_begin")
  ? j({ ok: true, address: "hello@salon.example.test", domain: "salon.example.test", resend_domain_id: null, replaces_domain_id: "d_old" }) : c.url.endsWith("/domains/d_old") ? j({}, 200) : null, async (calls) => {
  assertEquals((await post(start)).status, 200);
  assert(calls.some((c) => c.method === "DELETE" && c.url === "https://api.resend.com/domains/d_old"));
}));
Deno.test("start: without the Resend key it says the provider isn't set up (after the permission check)", mock(() => null, async (calls) => {
  Deno.env.set("RESEND_DOMAINS_API_KEY", "");
  try { const r = await post(start); assertEquals([r.status, (await r.json()).error], [503, "provider_not_configured"]); assert(calls.some((c) => c.url.endsWith("domain_begin"))); }
  finally { Deno.env.set("RESEND_DOMAINS_API_KEY", "re_test_key"); }
}));
Deno.test("verify: reads what is set up with the person's own sign in, asks Resend to check, records the answer", mock((c) => c.url.endsWith("domain_begin")
  ? j({ ok: true, address: "hello@salon.example.test", domain: "salon.example.test", resend_domain_id: "d_1" }) : c.url.endsWith("domain_checked") ? j({ ok: true, domain_status: "verified" }) : null, async (calls) => {
  const r = await post({ action: "domain_verify", business_id: B });
  assertEquals([r.status, (await r.json()).domain_status], [200, "verified"]);
  const status = calls.find((c) => c.url.endsWith("zella_business_email_status"))!;
  assertEquals([status.headers.apikey, status.headers.Authorization], ["anon-key", "Bearer user-jwt"]);
  assert(calls.some((c) => c.method === "POST" && c.url === "https://api.resend.com/domains/d_1/verify"));
  assertEquals(JSON.parse(calls.find((c) => c.url.endsWith("domain_checked"))!.body).p_provider_status, "verified");
}));
Deno.test("verify: nothing set up says so", mock((c) => c.url.endsWith("zella_business_email_status") ? j({ route: null }) : null, async (calls) => {
  const r = await post({ action: "domain_verify", business_id: B });
  assertEquals([r.status, (await r.json()).error], [409, "not_set_up"]);
  assert(!calls.some((c) => c.url.includes("resend.com")));
}));
Deno.test("verify: someone who may not read it is refused", mock((c) => c.url.endsWith("zella_business_email_status") ? j({ message: "NOT_ALLOWED" }, 400) : null, async () => {
  assertEquals((await post({ action: "domain_verify", business_id: B })).status, 403);
}));
Deno.test("disconnect: the database first, then the domain leaves Resend", mock(() => null, async (calls) => {
  const r = await post({ action: "disconnect", business_id: B });
  assertEquals([r.status, (await r.json()).provider_cleanup], [200, "removed"]);
  assertEquals(calls.map((c) => c.method + " " + c.url.replace("http://db.test/rest/v1/rpc/", "")).slice(1), ["POST zella_business_email_disconnect", "DELETE https://api.resend.com/domains/d_1"]);
}));
Deno.test("disconnect: a Resend failure is said, the business is disconnected anyway", mock((c) => c.url.includes("resend.com") ? j({}, 500) : null, async () => {
  const r = await post({ action: "disconnect", business_id: B });
  assertEquals([r.status, (await r.json()).provider_cleanup], [200, "not_removed"]);
}));
Deno.test("rate limits: per person first; over it, nothing is asked", mock(() => null, async (calls, limits) => {
  const r = await post(start);
  assertEquals(r.status, 429);
  assertEquals([limits.length, JSON.parse(limits[0].body).p_key, calls.length], [1, `business-email:user:${U}`, 1]);
}, () => j(false)));
Deno.test("rate limits: a counter that can't be checked refuses", mock(() => null, async () => {
  assertEquals((await post(start)).status, 502);
}, () => j({}, 500)));
Deno.test("only POST, and GET for the provider's redirect back", mock(() => null, async () => {
  assertEquals((await handle(new Request("http://fn/business-email", { method: "PUT" }))).status, 405);
}));

// ---------------- the mailbox sign in (Gmail, Outlook)
const SECRET = "local-link-secret-test-only-0123456789abcdef", N = "abcdefghijklmnop0123456789ABCDEF", OTHER = "a0000000-0000-4000-8000-000000000009";
const idToken = `h.${btoa(JSON.stringify({ email: "Salon@Gmail.example" })).replace(/=+$/, "")}.s`;
const mailRoute = (extra: (c: Call) => Response | null = () => null) => (c: Call) => extra(c) ?? (c.url.endsWith("/auth/v1/user") ? j({ id: c.headers.Authorization === "Bearer other-jwt" ? OTHER : U })
  : c.url.endsWith("zella_business_email_mailbox_can_connect") || c.url.endsWith("zella_oauth_state_issue") || c.url.endsWith("zella_oauth_state_consume") ? j(true)
  : c.url === "https://oauth2.googleapis.com/token" || c.url === "https://login.microsoftonline.com/common/oauth2/v2.0/token" ? j({ refresh_token: "fake-refresh", id_token: idToken })
  : c.url.endsWith("zella_business_email_mailbox_saved") ? j({ ok: true, account: "salon@gmail.example", removed_domain_id: "d_1" }) : null);
const finish = async (p: "gmail" | "outlook" = "gmail", auth = "Bearer user-jwt", state?: string) =>
  post({ action: "mailbox_finish", code: "code-1", state: state ?? await signMailState(SECRET, { b: B, p, u: U, n: N }) }, auth);

Deno.test("mailbox start: only the business's own owner or admin; a single use value is stored for them", mock(mailRoute(), async (calls) => {
  const r = await post({ action: "mailbox_start", business_id: B, provider: "gmail" });
  assertEquals(r.status, 200);
  const url = new URL((await r.json()).url);
  assertEquals([url.origin, url.searchParams.get("redirect_uri"), url.searchParams.get("scope")], ["https://accounts.google.com", "http://db.test/functions/v1/business-email", "openid email https://www.googleapis.com/auth/gmail.send"]);
  assertEquals(JSON.parse(calls[1].body), { p_business_id: B, p_actor: U });
  const issued = JSON.parse(calls[2].body);
  assertEquals([calls[2].url.endsWith("zella_oauth_state_issue"), issued.p_user_id, issued.p_business_id, issued.p_provider, issued.p_seconds], [true, U, B, "gmail", 300]);
  assert(/^[0-9a-f]{64}$/.test(issued.p_nonce_hash) && !url.toString().includes(issued.p_nonce_hash));
}));
Deno.test("mailbox start: Outlook is kept apart from the calendar's sign ins", mock(mailRoute(), async (calls) => {
  const r = await post({ action: "mailbox_start", business_id: B, provider: "outlook" });
  assertEquals([r.status, new URL((await r.json()).url).searchParams.get("scope")], [200, "offline_access openid email Mail.Send"]);
  assertEquals(JSON.parse(calls[2].body).p_provider, "outlook_mail");
}));
Deno.test("mailbox start: a Zella Voice admin or staff (database says no) is refused; nothing is stored", mock(mailRoute((c) => c.url.endsWith("mailbox_can_connect") ? j(false) : null), async (calls) => {
  assertEquals((await post({ action: "mailbox_start", business_id: B, provider: "gmail" })).status, 403);
  assert(!calls.some((c) => c.url.endsWith("zella_oauth_state_issue")));
}));
Deno.test("mailbox start: Yahoo or a bad business is a bad request; an app not set up says so", mock(mailRoute(), async () => {
  assertEquals((await post({ action: "mailbox_start", business_id: B, provider: "yahoo" })).status, 400);
  assertEquals((await post({ action: "mailbox_start", business_id: "x", provider: "gmail" })).status, 400);
  Deno.env.set("GOOGLE_MAIL_CLIENT_ID", "");
  try { const r = await post({ action: "mailbox_start", business_id: B, provider: "gmail" }); assertEquals([r.status, (await r.json()).error], [503, "provider_not_configured"]); }
  finally { Deno.env.set("GOOGLE_MAIL_CLIENT_ID", "gid"); }
}));
Deno.test("return: nothing is exchanged; the code and state go on to the app in the fragment", mock(() => null, async (calls) => {
  const st = await signMailState(SECRET, { b: B, p: "gmail", u: U, n: N });
  const r = await handle(new Request(`http://fn/business-email?code=abc&state=${encodeURIComponent(st)}`));
  const to = new URL(r.headers.get("location")!);
  assertEquals([r.status, to.origin + to.pathname, new URLSearchParams(to.hash.slice(1)).get("mailbox_code"), to.search], [302, "https://app.test/app/settings/messages/business-email", "abc", ""]);
  assertEquals(calls.length, 0);
  const bad = await handle(new Request("http://fn/business-email?code=abc&state=forged"));
  assertEquals(new URL(bad.headers.get("location")!).searchParams.get("reason"), "link_expired");
  const no = await handle(new Request(`http://fn/business-email?error=access_denied&state=${encodeURIComponent(st)}`));
  assertEquals(new URL(no.headers.get("location")!).searchParams.get("mailbox"), "cancelled");
}));
Deno.test("mailbox finish: the value is used up, the code exchanged, the token stored by the database, an old domain removed", mock(mailRoute(), async (calls) => {
  const r = await finish();
  assertEquals([r.status, (await r.json()).account], [200, "salon@gmail.example"]);
  const order = calls.map((c) => c.url.replace("http://db.test/rest/v1/rpc/", ""));
  assertEquals(order, ["http://db.test/auth/v1/user", "zella_oauth_state_consume", "https://oauth2.googleapis.com/token", "zella_business_email_mailbox_saved", "https://api.resend.com/domains/d_1"]);
  const saved = JSON.parse(calls[3].body);
  assertEquals([saved.p_business_id, saved.p_actor, saved.p_provider, saved.p_account_email, saved.p_refresh_token], [B, U, "gmail", "Salon@Gmail.example", "fake-refresh"]);
  const form = new URLSearchParams(calls[2].body);
  assertEquals([form.get("client_id"), form.get("code"), form.get("redirect_uri")], ["gid", "code-1", "http://db.test/functions/v1/business-email"]);
}));
Deno.test("mailbox finish: someone else can't finish another person's sign in", mock(mailRoute(), async (calls) => {
  const r = await finish("gmail", "Bearer other-jwt");
  assertEquals([r.status, (await r.json()).error], [403, "not_your_sign_in"]);
  assert(!calls.some((c) => c.url.endsWith("zella_oauth_state_consume")));
}));
Deno.test("mailbox finish: a calendar state, a used value or an expired one is refused before the provider is asked", mock(mailRoute((c) => c.url.endsWith("zella_oauth_state_consume") ? j(false) : null), async (calls) => {
  assertEquals((await finish()).status, 400);
  assertEquals((await finish("gmail", "Bearer user-jwt", "forged.sig")).status, 400);
  assert(!calls.some((c) => c.url.includes("oauth2.googleapis.com")));
}));
Deno.test("mailbox finish: no refresh token, or no account address, stores nothing", mock(mailRoute((c) => c.url.includes("oauth2.googleapis.com") ? j({ access_token: "a" }) : null), async (calls) => {
  assertEquals([(await (await finish()).json()).error], ["no_refresh_token"]);
  assert(!calls.some((c) => c.url.endsWith("mailbox_saved")));
}));
Deno.test("mailbox finish: the provider's refusal is a short name, never its text", mock(mailRoute((c) => c.url.includes("oauth2.googleapis.com") ? j({ error: "invalid_grant", error_description: "PRIVATE DETAIL" }, 400) : null), async () => {
  const t = await (await finish()).text();
  assert(t.includes("invalid_grant") && !t.includes("PRIVATE"));
}));
Deno.test("mailbox finish: Outlook uses Microsoft's token address and the outlook_mail sign in", mock(mailRoute(), async (calls) => {
  assertEquals((await finish("outlook")).status, 200);
  assertEquals(JSON.parse(calls.find((c) => c.url.endsWith("state_consume"))!.body).p_provider, "outlook_mail");
  assert(calls.some((c) => c.url === "https://login.microsoftonline.com/common/oauth2/v2.0/token"));
}));
