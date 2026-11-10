// deno test web/supabase/functions/staff-invite/logic_test.ts   (fakes only: no Supabase, no email)
import { assertEquals } from "jsr:@std/assert@1";
import { type AuthUser, type Deps, type Invitation, sendInvitation } from "./logic.ts";

const OWNER = "u-owner", ADMIN = "u-admin";
function fake(over: Partial<Deps> = {}, inv: Partial<Invitation> = {}) {
  const calls: string[] = [];
  const invitation: Invitation = { id: "i1", business_id: "b1", email: "Person@Example.com", owner_name: "Pat", role: "staff", status: "pending", expires_at: null, ...inv };
  const deps: Deps = {
    getInvitation: async () => invitation,
    callerRole: async (_b, u) => (u === OWNER ? "owner" : u === ADMIN ? "admin" : null),
    businessOpen: async () => true,
    findUser: async () => null,
    isActiveMember: async () => false,
    inviteNewUser: async (email) => { calls.push(`invite:${email}`); return { id: "u-new", email }; },
    sendSignInLink: async (email) => { calls.push(`link:${email}`); },
    finalize: async (_i, actor, user, existing) => { calls.push(`finalize:${actor}:${user}:${existing}`); return "sent"; },
    fail: async (_i, e) => { calls.push(`fail:${e}`); return "failed"; },
    now: () => new Date("2026-11-04T12:00:00Z"),
    ...over,
  };
  return { deps, calls };
}

Deno.test("new person: invitation email, then atomic finalize", async () => {
  const { deps, calls } = fake();
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r, { status: 200, body: { sent: true, existingAccount: false } });
  assertEquals(calls, ["invite:person@example.com", "finalize:u-owner:u-new:false"]);
});

Deno.test("existing account (even one that signed in before) gets an email sign-in link, never a silent bind", async () => {
  const user: AuthUser = { id: "u-old", email: "person@example.com", email_confirmed_at: "2026-01-01", last_sign_in_at: "2026-11-01" };
  const { deps, calls } = fake({ findUser: async () => user });
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r.body, { sent: true, existingAccount: true });
  assertEquals(calls, ["link:person@example.com", "finalize:u-owner:u-old:true"]);
});

Deno.test("account that was only ever invited gets the invitation email again", async () => {
  const user: AuthUser = { id: "u-inv", email: "person@example.com", email_confirmed_at: null, last_sign_in_at: null };
  const { deps, calls } = fake({ findUser: async () => user, inviteNewUser: async (e) => { calls.push(`invite:${e}`); return user; } });
  await sendInvitation(deps, OWNER, "i1");
  assertEquals(calls, ["invite:person@example.com", "finalize:u-owner:u-inv:false"]);
});

Deno.test("cancelled while sending: finalize says CLOSED, answered 409, no 'failed' written", async () => {
  const { deps, calls } = fake({ finalize: async () => "CLOSED" });
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r.status, 409);
  assertEquals(r.body.code, "CLOSED");
  assertEquals(calls.some((c) => c.startsWith("fail:")), false);
});

Deno.test("send error is recorded through the conditional fail (never a plain update)", async () => {
  const { deps, calls } = fake({ inviteNewUser: async () => { throw new Error("SMTP down"); } });
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r.status, 502);
  assertEquals(calls, ["fail:SMTP down"]);
});

Deno.test("rate limit has its own message", async () => {
  const { deps } = fake({ sendSignInLink: async () => { throw new Error("For security purposes, you can only request this after 60 seconds"); },
    findUser: async () => ({ id: "u1", email: "person@example.com", email_confirmed_at: "x", last_sign_in_at: "x" }) });
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r.body.error, "Too many emails were sent in a short time. Wait a minute and try again.");
});

Deno.test("finalize throwing records a safe failure and says so", async () => {
  const { deps, calls } = fake({ finalize: async () => { throw new Error("timeout"); } });
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r.status, 500);
  assertEquals(calls.at(-1), "fail:finalize: timeout");
});

Deno.test("refusals before any email", async () => {
  const cases: [Partial<Deps>, Partial<Invitation>, string, number][] = [
    [{}, {}, "u-stranger", 403],
    [{}, { role: "owner" }, OWNER, 403],
    [{}, { role: "admin" }, ADMIN, 403],
    [{}, { status: "revoked" }, OWNER, 409],
    [{}, { status: "accepted" }, OWNER, 409],
    [{}, { expires_at: "2026-11-01T00:00:00Z" }, OWNER, 409],
    [{ businessOpen: async () => false }, {}, OWNER, 409],
    [{ getInvitation: async () => null }, {}, OWNER, 404],
    [{ findUser: async () => ({ id: "u-m", email: "person@example.com" }), isActiveMember: async () => true }, {}, OWNER, 409],
  ];
  for (const [over, inv, caller, status] of cases) {
    const { deps, calls } = fake(over, inv);
    const r = await sendInvitation(deps, caller, "i1");
    assertEquals(r.status, status, JSON.stringify(inv) + JSON.stringify(Object.keys(over)));
    assertEquals(calls.filter((c) => c.startsWith("invite:") || c.startsWith("link:")), [], "an email was sent for a refused request");
  }
});

Deno.test("each finalize refusal maps to a clear answer", async () => {
  for (const [code, status] of [["NOT_ALLOWED", 403], ["EXPIRED", 409], ["BUSINESS_CLOSED", 409], ["EMAIL_MISMATCH", 409], ["ALREADY_MEMBER", 409], ["NOT_FOUND", 404], ["WEIRD", 409]] as const) {
    const { deps } = fake({ finalize: async () => code });
    const r = await sendInvitation(deps, OWNER, "i1");
    assertEquals(r.status, status, code);
    assertEquals(typeof r.body.error, "string");
  }
});

Deno.test("failure bookkeeping throwing still returns the email error", async () => {
  const { deps } = fake({ findUser: async () => { throw new Error("rate limit"); }, fail: async () => { throw new Error("RPC down"); } });
  const r = await sendInvitation(deps, OWNER, "i1");
  assertEquals(r.status, 502);
  assertEquals(r.body.error, "Too many emails were sent in a short time. Wait a minute and try again.");
});
Deno.test("membership lookup errors stop email delivery", async () => {
  const { deps, calls } = fake({ findUser: async () => ({ id: "u" }), isActiveMember: async () => { throw new Error("query failed"); } });
  assertEquals((await sendInvitation(deps, OWNER, "i1")).status, 502);
  assertEquals(calls, ["fail:query failed"]);
});
