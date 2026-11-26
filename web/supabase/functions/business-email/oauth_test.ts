// The mailbox sign in's pure pieces: the signed state, the provider addresses and forms. Fake secrets only.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { verifyState } from "../calendar-connect/logic.ts";
import { mailAuthorizeUrl, mailTokenForm, signMailState, STATE_PROVIDER, verifyMailState } from "./oauth.ts";

const SECRET = "local-link-secret-test-only-0123456789abcdef";
const B = "c0000000-0000-4000-8000-000000000004", U = "a0000000-0000-4000-8000-000000000002", N = "abcdefghijklmnop0123456789ABCDEF";

Deno.test("state: signed, five minutes, names the business, the mailbox and the person", async () => {
  const t = await signMailState(SECRET, { b: B, p: "gmail", u: U, n: N }, 1000);
  const s = await verifyMailState(SECRET, t, 1000);
  assertEquals([s?.k, s?.b, s?.p, s?.u, s?.n, s?.exp], ["mail", B, "gmail", U, N, 1300]);
  assertEquals(await verifyMailState(SECRET, t, 1301), null);                      // expired
  assertEquals(await verifyMailState("another-secret-0123456789abcdef0123", t, 1000), null);
  assertEquals(await verifyMailState(SECRET, t.slice(0, -2) + "xx", 1000), null);   // altered
  assertEquals(await verifyMailState(SECRET, t + ".x", 1000), null);
});
Deno.test("state: a mailbox sign in and a calendar sign in never stand in for each other", async () => {
  for (const p of ["outlook", "gmail"] as const) assertEquals(await verifyState(SECRET, await signMailState(SECRET, { b: B, p, u: U, n: N })), null);   // the calendar's check refuses them
  const { signState } = await import("../calendar-connect/logic.ts");
  assertEquals(await verifyMailState(SECRET, await signState(SECRET, { b: B, p: "outlook", u: U, n: N })), null);   // and a calendar state is no mailbox state
  assertEquals(STATE_PROVIDER, { gmail: "gmail", outlook: "outlook_mail" });   // and the database keeps them apart
});
Deno.test("Google: gmail.send only (never reading the mailbox), offline, consent", () => {
  const u = new URL(mailAuthorizeUrl("gmail", "gid", "https://fn.test/business-email", "st", "owner@salon.example"));
  assertEquals([u.origin, u.searchParams.get("scope"), u.searchParams.get("access_type"), u.searchParams.get("prompt"), u.searchParams.get("login_hint")],
    ["https://accounts.google.com", "openid email https://www.googleapis.com/auth/gmail.send", "offline", "consent", "owner@salon.example"]);
  assert(!u.searchParams.get("scope")!.includes("readonly") && !u.searchParams.get("scope")!.includes("mail.google.com"));
});
Deno.test("Microsoft: Mail.Send and a refresh token, nothing more", () => {
  const u = new URL(mailAuthorizeUrl("outlook", "mid", "https://fn.test/business-email", "st"));
  assertEquals([u.origin, u.searchParams.get("scope"), u.searchParams.get("login_hint")], ["https://login.microsoftonline.com", "offline_access openid email Mail.Send", null]);
  assertEquals(mailTokenForm("outlook", "mid", "msecret", "https://r.test", "code1").get("scope"), "offline_access openid email Mail.Send");
  assertEquals(mailTokenForm("gmail", "gid", "gsecret", "https://r.test", "code1").get("scope"), null);
});
