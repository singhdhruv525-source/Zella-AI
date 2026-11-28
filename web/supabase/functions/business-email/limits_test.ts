// business-email, the owner's decisions of 27 Nov 2026: the mailbox's type for its daily cap, the admin's "Connect
// your mailbox" link, and removing pending domains. Auth, the database and Resend are mocked: nothing reaches a real
// provider and no email is sent. Fake keys and tokens only.
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { handle } from "./index.ts";
import { LINK_TOKEN, mailboxLinkPath, maskEmail, newLinkToken, reason, removalOk, tokenHash } from "./logic.ts";
import { MICROSOFT_CONSUMER_TENANT, mailboxKind, signMailState } from "./oauth.ts";

for (const [k, v] of Object.entries({ SUPABASE_URL: "http://db.test", ZELLA_SERVER_SECRET_KEY: "server-key", SUPABASE_ANON_KEY: "anon-key",
  RESEND_DOMAINS_API_KEY: "re_test_key", ZELLA_APP_URL: "https://app.test", ZELLA_LINK_SECRET: "local-link-secret-test-only-0123456789abcdef",
  GOOGLE_MAIL_CLIENT_ID: "gid", GOOGLE_MAIL_CLIENT_SECRET: "gsecret", MICROSOFT_MAIL_CLIENT_ID: "mid", MICROSOFT_MAIL_CLIENT_SECRET: "msecret" })) Deno.env.set(k, v);
const B = "c0000000-0000-4000-8000-000000000004", U = "a0000000-0000-4000-8000-000000000002", OWNER = "a0000000-0000-4000-8000-000000000007";
const LINK = "e0000000-0000-4000-8000-000000000001", REMOVAL = "f0000000-0000-4000-8000-000000000001", CLAIM = "f0000000-0000-4000-8000-0000000000c1";
type Call = { url: string; method: string; headers: Record<string, string>; body: string };
const realFetch = globalThis.fetch;
const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s });
const rpcName = (c: Call) => c.url.replace("http://db.test/rest/v1/rpc/", "");
function mock(route: (c: Call) => Response | null, fn: (calls: Call[]) => Promise<void>) {
  return async () => {
    const calls: Call[] = [];
    globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
      const c = { url: String(url), method: init.method ?? "GET", headers: (init.headers ?? {}) as Record<string, string>, body: String(init.body ?? "") };
      if (c.url.endsWith("/rpc/zella_rate_limit")) return j(true);
      calls.push(c);
      return route(c) ?? base(c);
    }) as typeof fetch;
    try { await fn(calls); } finally { globalThis.fetch = realFetch; }
  };
}
// a Zella Voice admin with businesses.manage, unless a test says otherwise
function base(c: Call): Response {
  if (c.url.endsWith("/auth/v1/user")) return j({ id: U });
  if (c.url.endsWith("zella_business_email_platform_admin")) return j(true);
  if (c.url.endsWith("zella_business_email_mailbox_link_issue")) return j({ ok: true, link_id: LINK, owner_id: OWNER, owner_invited: false, to: "owner@salon.example.test",
    business_name: "Test Salon", expires_on: "4 Dec 2026", email_live: false });
  if (c.url.endsWith("zella_queue_platform_email")) return j("d0000000-0000-4000-8000-000000000001");
  if (c.url.endsWith("zella_business_email_mailbox_link_redeem")) return j({ ok: true, business_id: B, business_name: "Test Salon" });
  if (c.url.endsWith("zella_business_email_domain_remove_pending")) return j({ ok: true, removal_id: REMOVAL, domain: "salon.example.test" });
  if (c.url.endsWith("zella_business_email_domain_removals_claim")) return j([{ id: REMOVAL, resend_domain_id: "d_1", claim_token: CLAIM }]);
  if (c.url.endsWith("zella_business_email_domain_removal_done")) return j("done");
  if (c.url.endsWith("zella_business_email_jobs_check")) return j(true);
  if (c.url.startsWith("https://api.resend.com/domains/") && c.method === "DELETE") return j({ object: "domain", id: "d_1", deleted: true });
  return j({}, 500);
}
const post = (body: unknown, headers: Record<string, string> = { authorization: "Bearer user-jwt" }) =>
  handle(new Request("http://fn/business-email", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", ...headers } }));
const idt = (claims: Record<string, unknown>) => `h.${btoa(JSON.stringify(claims)).replace(/=+$/, "")}.s`;

// ---------------- the mailbox's type (its daily cap)
Deno.test("type: Workspace from Google's hd claim, free Gmail from a gmail.com address, otherwise not known", () => {
  assertEquals(mailboxKind("gmail", idt({ email: "hello@salon.example", hd: "salon.example" })), "work");
  assertEquals(mailboxKind("gmail", idt({ email: "salon@gmail.com" })), "personal");
  assertEquals(mailboxKind("gmail", idt({ email: "salon@googlemail.com" })), "personal");
  assertEquals(mailboxKind("gmail", idt({ email: "hello@salon.example" })), null);
  assertEquals(mailboxKind("gmail", idt({ email: "x@salon.example", hd: "bad domain!" })), null);
  assertEquals(mailboxKind("gmail", "not a token"), null);
  assertEquals(mailboxKind("gmail", undefined), null);
});
Deno.test("type: Outlook.com from Microsoft's consumer tenant, Microsoft 365 from any other tenant, otherwise not known", () => {
  assertEquals(mailboxKind("outlook", idt({ email: "salon@outlook.com", tid: MICROSOFT_CONSUMER_TENANT })), "personal");
  assertEquals(mailboxKind("outlook", idt({ email: "hello@salon.example", tid: "72f988bf-86f1-41af-91ab-2d7cd011db47" })), "work");
  assertEquals(mailboxKind("outlook", idt({ email: "hello@salon.example" })), null);
  assertEquals(mailboxKind("outlook", idt({ email: "hello@salon.example", tid: "common" })), null);
});
Deno.test("mailbox finish: the type from the sign in goes to the database with the mailbox", mock((c) =>
  c.url.endsWith("zella_oauth_state_consume") ? j(true)
  : c.url === "https://oauth2.googleapis.com/token" ? j({ refresh_token: "fake-refresh", id_token: idt({ email: "hello@salon.example", hd: "salon.example" }) })
  : c.url.endsWith("zella_business_email_mailbox_saved") ? j({ ok: true, account: "hello@salon.example", mailbox_type: "google_workspace", removed_domain_id: null }) : null, async (calls) => {
  const state = await signMailState("local-link-secret-test-only-0123456789abcdef", { b: B, p: "gmail", u: U, n: "abcdefghijklmnop0123456789ABCDEF" });
  const r = await post({ action: "mailbox_finish", code: "code-1", state });
  assertEquals(r.status, 200);
  const saved = JSON.parse(calls.find((c) => c.url.endsWith("zella_business_email_mailbox_saved"))!.body);
  assertEquals([saved.p_mailbox_kind, saved.p_actor, saved.p_refresh_token], ["work", U, "fake-refresh"]);
}));

// ---------------- the "Connect your mailbox" link
Deno.test("link token: 32 random bytes, URL safe, never the same twice; only its SHA 256 hash is kept", async () => {
  const a = newLinkToken(), b = newLinkToken();
  assert(LINK_TOKEN.test(a) && LINK_TOKEN.test(b));
  assertNotEquals(a, b);
  assert(/^[0-9a-f]{64}$/.test(await tokenHash(a)));
  assertEquals(await tokenHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assertEquals(mailboxLinkPath("C0000000-0000-4000-8000-000000000004", a), `/app/settings/messages/business-email?business=c0000000-0000-4000-8000-000000000004#mailbox_link=${a}`);
  assertEquals([maskEmail("owner@salon.example"), maskEmail("o@x.example"), maskEmail("nope")], ["ow***@salon.example", "o***@x.example", ""]);
});
Deno.test("link send: the database says yes first, keeps only the hash, and the email S8 with the link is queued in the platform outbox", mock(() => null, async (calls) => {
  const r = await post({ action: "mailbox_link_send", business_id: B, p_actor: OWNER, actor: OWNER });
  const body = await r.json();
  assertEquals([r.status, body.ok, body.to, body.expires_on, body.email_live], [200, true, "ow***@salon.example.test", "4 Dec 2026", false]);
  assertEquals(calls.map(rpcName), ["http://db.test/auth/v1/user", "zella_business_email_platform_admin", "zella_business_email_mailbox_link_issue", "zella_queue_platform_email"]);
  const issued = JSON.parse(calls[2].body);
  assertEquals([issued.p_business_id, issued.p_actor], [B, U]);   // the admin from their own sign in, never the body
  assert(/^[0-9a-f]{64}$/.test(issued.p_token_hash));
  const q = JSON.parse(calls[3].body);
  assertEquals([q.p_business, q.p_code, q.p_dedupe_key, q.p_to, q.p_mandatory, q.p_user], [B, "S8", `email:S8:${LINK}:1`, "owner@salon.example.test", true, OWNER]);
  const token = /#mailbox_link=([A-Za-z0-9_-]{43})/.exec(q.p_text)?.[1] ?? "";
  assertEquals(await tokenHash(token), issued.p_token_hash);   // the email carries the token whose hash the database keeps
  assert(q.p_html.includes(`https://app.test/app/settings/messages/business-email?business=${B}#mailbox_link=${token}`));
  assert(!calls[2].body.includes(token) && !JSON.stringify(body).includes(token));   // the token goes only into the email
  assert(!calls.some((c) => c.url.includes("resend.com") || c.url.includes("googleapis") || c.url.includes("microsoftonline")));
  assert(!/[–—]/.test(q.p_subject + q.p_text));
}));
Deno.test("link send: an invited owner is told to accept the invitation first", mock((c) => c.url.endsWith("mailbox_link_issue")
  ? j({ ok: true, link_id: LINK, owner_id: OWNER, owner_invited: true, to: "owner@salon.example.test", business_name: "Test Salon", expires_on: "4 Dec 2026", email_live: true }) : null, async (calls) => {
  const body = await (await post({ action: "mailbox_link_send", business_id: B })).json();
  assertEquals([body.owner_invited, body.email_live], [true, true]);
  assert(JSON.parse(calls.find((c) => c.url.endsWith("zella_queue_platform_email"))!.body).p_text.includes("First accept your invitation"));
}));
Deno.test("link send: not a Zella Voice admin with businesses.manage (owners included): 403, nothing issued or queued", mock((c) => c.url.endsWith("platform_admin") ? j(false) : null, async (calls) => {
  const r = await post({ action: "mailbox_link_send", business_id: B });
  assertEquals([r.status, (await r.json()).error], [403, "not_allowed"]);
  assert(!calls.some((c) => c.url.endsWith("mailbox_link_issue") || c.url.endsWith("zella_queue_platform_email")));
}));
Deno.test("link send: a database refusal (already connected, too many links) is said; nothing is queued", mock((c) => c.url.endsWith("mailbox_link_issue") ? j({ ok: false, reason: "ALREADY_CONNECTED" }) : null, async (calls) => {
  const r = await post({ action: "mailbox_link_send", business_id: B });
  assertEquals([r.status, (await r.json()).error], [409, "already_connected"]);
  assert(!calls.some((c) => c.url.endsWith("zella_queue_platform_email")));
  assertEquals(reason("TOO_MANY_LINKS"), "too_many_links");
}));
Deno.test("link send: the outbox didn't take the email: said, so the admin sends a new link", mock((c) => c.url.endsWith("zella_queue_platform_email") ? j({ message: "x" }, 500) : null, async () => {
  const r = await post({ action: "mailbox_link_send", business_id: B });
  assertEquals([r.status, (await r.json()).error], [502, "email_not_queued"]);
}));
Deno.test("link send: signed in only; a bad business is a bad request", mock(() => null, async (calls) => {
  assertEquals((await post({ action: "mailbox_link_send", business_id: B }, {})).status, 401);
  assertEquals((await post({ action: "mailbox_link_send", business_id: "x" })).status, 400);
  assert(!calls.some((c) => c.url.includes("/rpc/")));
}));
Deno.test("link open: the owner signed in; the hash and the person from the sign in go to the database, never the token", mock(() => null, async (calls) => {
  const t = newLinkToken();
  const r = await post({ action: "mailbox_link_open", token: t });
  assertEquals([r.status, (await r.json()).business_id], [200, B]);
  const red = JSON.parse(calls.find((c) => c.url.endsWith("mailbox_link_redeem"))!.body);
  assertEquals([red.p_token_hash, red.p_actor], [await tokenHash(t), U]);
  assert(!calls.some((c) => c.body.includes(t)));
}));
const refusals = ["MAILBOX_LINK_NOT_YOURS", "NOT_OWNER", "MAILBOX_LINK_USED", "MAILBOX_LINK_EXPIRED"];
let refusal = 0;
Deno.test("link open: someone else's link, a lost owner role, used or expired: refused in short names", mock((c) => c.url.endsWith("mailbox_link_redeem")
  ? j({ ok: false, reason: refusals[refusal++] }) : null, async () => {
  const got = [];
  for (let i = 0; i < refusals.length; i++) { const r = await post({ action: "mailbox_link_open", token: newLinkToken() }); got.push(`${r.status} ${(await r.json()).error}`); }
  assertEquals(got, ["403 mailbox_link_not_yours", "403 not_owner", "400 mailbox_link_used", "400 mailbox_link_expired"]);
}));
Deno.test("link open: a malformed token is refused before anything is asked", mock(() => null, async (calls) => {
  assertEquals((await post({ action: "mailbox_link_open", token: "short" })).status, 400);
  assertEquals(calls.length, 0);
}));

// ---------------- pending domains
Deno.test("remove pending: an admin with a reason; removed from the business, then at Resend at once, reported with its claim", mock(() => null, async (calls) => {
  const r = await post({ action: "domain_remove_pending", business_id: B, reason: "Another business proved it owns the domain" });
  assertEquals([r.status, (await r.json()).provider_cleanup], [200, "removed"]);
  assertEquals(calls.map(rpcName), ["http://db.test/auth/v1/user", "zella_business_email_platform_admin", "zella_business_email_domain_remove_pending",
    "zella_business_email_domain_removals_claim", "https://api.resend.com/domains/d_1", "zella_business_email_domain_removal_done"]);
  assertEquals(JSON.parse(calls[2].body), { p_business_id: B, p_actor: U, p_reason: "Another business proved it owns the domain" });
  assertEquals(JSON.parse(calls[3].body), { p_limit: 1, p_id: REMOVAL });
  assertEquals([calls[4].method, calls[4].headers.Authorization], ["DELETE", "Bearer re_test_key"]);
  assertEquals(JSON.parse(calls[5].body), { p_id: REMOVAL, p_claim_token: CLAIM, p_ok: true, p_http_status: 200 });
}));
Deno.test("remove pending: Resend down: the business is still back on the fallback, and the removal waits in the queue", mock((c) => c.url.includes("api.resend.com") ? j({}, 503) : null, async (calls) => {
  const r = await post({ action: "domain_remove_pending", business_id: B, reason: "proof shown" });
  assertEquals([r.status, (await r.json()).provider_cleanup], [200, "queued"]);
  assertEquals(JSON.parse(calls.find((c) => c.url.endsWith("removal_done"))!.body).p_ok, false);
}));
Deno.test("remove pending: no reason, or not an admin: refused; nothing is removed and Resend is never asked", mock((c) => c.url.endsWith("platform_admin") ? j(false) : null, async (calls) => {
  assertEquals((await post({ action: "domain_remove_pending", business_id: B, reason: "  " })).status, 400);
  const r = await post({ action: "domain_remove_pending", business_id: B, reason: "proof shown" });
  assertEquals([r.status, (await r.json()).error], [403, "not_allowed"]);
  assert(!calls.some((c) => c.url.includes("resend.com") || c.url.endsWith("domain_remove_pending")));
}));
Deno.test("remove pending: the database says it isn't pending (a verified domain): 409, nothing removed", mock((c) => c.url.endsWith("domain_remove_pending") ? j({ ok: false, reason: "NOT_PENDING" }) : null, async (calls) => {
  const r = await post({ action: "domain_remove_pending", business_id: B, reason: "proof shown" });
  assertEquals([r.status, (await r.json()).error], [409, "not_pending"]);
  assert(!calls.some((c) => c.url.includes("resend.com")));
}));
Deno.test("removals job: only with the database's secret; each claimed domain removed at Resend; 404 counts as removed", mock((c) =>
  c.url.endsWith("removals_claim") ? j([{ id: REMOVAL, resend_domain_id: "d_1", claim_token: CLAIM }, { id: LINK, resend_domain_id: "d_2", claim_token: CLAIM },
    { id: B, resend_domain_id: "bad id!", claim_token: CLAIM }])
  : c.url === "https://api.resend.com/domains/d_2" ? j({ message: "gone" }, 404) : null, async (calls) => {
  const r = await post({ action: "domain_removals" }, { "x-zella-secret": "vault-secret-test" });
  assertEquals(await r.json(), { ok: true, removed: 2, waiting: 0 });
  assertEquals(JSON.parse(calls[0].body), { p_secret: "vault-secret-test" });
  assertEquals(calls.filter((c) => c.method === "DELETE").map((c) => c.url), ["https://api.resend.com/domains/d_1", "https://api.resend.com/domains/d_2"]);
  assert(!calls.some((c) => c.url.endsWith("/auth/v1/user")));
}));
Deno.test("removals job: no secret or a wrong one: 401, nothing claimed or removed", mock((c) => c.url.endsWith("jobs_check") ? j(false) : null, async (calls) => {
  assertEquals((await post({ action: "domain_removals" }, {})).status, 401);
  assertEquals((await post({ action: "domain_removals" }, { "x-zella-secret": "wrong" })).status, 401);
  assert(!calls.some((c) => c.url.endsWith("removals_claim") || c.url.includes("resend.com")));
}));
Deno.test("removals job: without the Resend key nothing is claimed, so the queue keeps every removal", mock(() => null, async (calls) => {
  Deno.env.set("RESEND_DOMAINS_API_KEY", "");
  try { assertEquals((await post({ action: "domain_removals" }, { "x-zella-secret": "vault-secret-test" })).status, 503); }
  finally { Deno.env.set("RESEND_DOMAINS_API_KEY", "re_test_key"); }
  assert(!calls.some((c) => c.url.endsWith("removals_claim")));
  assert(removalOk(204) && removalOk(404) && !removalOk(500) && !removalOk(0));
}));
