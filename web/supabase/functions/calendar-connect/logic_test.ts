import { assert, assertEquals } from "jsr:@std/assert@1";
import { accountEmail, authorizeUrl, newNonce, nonceHash, problem, signState, STATE_SECONDS, tokenForm, verifyState } from "./logic.ts";
const S = "a-test-secret-that-is-long-enough-0123456789";
const B = "c0000000-0000-0000-0000-000000000004", U = "a0000000-0000-0000-0000-000000000002";

Deno.test("state round-trips and carries business, provider and person", async () => {
  const s = await verifyState(S, await signState(S, { b: B, p: "outlook", u: U }));
  assertEquals([s?.b, s?.p, s?.u], [B, "outlook", U]);
});
Deno.test("state: altered, wrongly signed, expired or malformed is refused", async () => {
  const t = await signState(S, { b: B, p: "google", u: U });
  const [body, sig] = t.split(".");
  const other = btoa(JSON.stringify({ b: B, p: "google", u: "a0000000-0000-0000-0000-000000000009", exp: 9e9, n: "x" })).replace(/=+$/, "");
  assertEquals(await verifyState(S, `${other}.${sig}`), null);
  assertEquals(await verifyState("another-secret-another-secret-0123456789", t), null);
  assertEquals(await verifyState(S, await signState(S, { b: B, p: "google", u: U }, Date.now() / 1000 - 700)), null);
  assertEquals(await verifyState(S, body), null);
  assertEquals(await verifyState(S, ""), null);
  assertEquals(await verifyState(S, await signState(S, { b: B, p: "yahoo" as "google", u: U })), null);
});
Deno.test("authorize addresses ask for offline access and only calendar events", () => {
  const g = new URL(authorizeUrl("google", "gid", "https://x.test/cb", "st"));
  assertEquals([g.origin, g.searchParams.get("access_type"), g.searchParams.get("prompt"), g.searchParams.get("state")], ["https://accounts.google.com", "offline", "consent", "st"]);
  assert(g.searchParams.get("scope")!.includes("calendar.events") && !g.searchParams.get("scope")!.includes("auth/calendar "));
  const m = new URL(authorizeUrl("outlook", "mid", "https://x.test/cb", "st"));
  assertEquals(m.origin, "https://login.microsoftonline.com");
  assert(m.searchParams.get("scope")!.split(" ").includes("offline_access") && m.searchParams.get("scope")!.includes("Calendars.ReadWrite"));
});
Deno.test("token exchange form", () => {
  assertEquals(tokenForm("google", "i", "s", "r", "c").get("grant_type"), "authorization_code");
  assertEquals(tokenForm("google", "i", "s", "r", "c").has("scope"), false);
  assert(tokenForm("outlook", "i", "s", "r", "c").get("scope")!.includes("offline_access"));
});
Deno.test("account email from the ID token; nothing else trusted", () => {
  const jwt = (o: unknown) => `x.${btoa(JSON.stringify(o)).replace(/=+$/, "")}.y`;
  assertEquals(accountEmail(jwt({ email: "a@b.test" })), "a@b.test");
  assertEquals(accountEmail(jwt({ preferred_username: "m@corp.test" })), "m@corp.test");
  assertEquals(accountEmail(jwt({ sub: "1" })), null);
  assertEquals(accountEmail("garbage"), null);
  assertEquals(accountEmail(undefined), null);
});
Deno.test("problem names are short and plain", () => {
  assertEquals(problem("access_denied"), "access_denied");
  assertEquals(problem("<script>"), "script");
  assertEquals(problem(42), "failed");
});
Deno.test("state: short lived (5 minutes) and carries a random value whose hash is stored", async () => {
  assertEquals(STATE_SECONDS, 300);
  assertEquals(await verifyState(S, await signState(S, { b: B, p: "google", u: U }, Date.now() / 1000 - 301)), null);
  const n = newNonce();
  assert(n !== newNonce() && /^[A-Za-z0-9_-]{32}$/.test(n));
  assertEquals((await verifyState(S, await signState(S, { b: B, p: "google", u: U, n })))?.n, n);
  assert(/^[0-9a-f]{64}$/.test(await nonceHash(n)) && (await nonceHash(n)) !== (await nonceHash(newNonce())));
});
