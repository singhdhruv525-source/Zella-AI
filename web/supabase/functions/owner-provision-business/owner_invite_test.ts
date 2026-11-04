// deno test --no-lock web/supabase/functions/owner-provision-business/owner_invite_test.ts   (no network)
import { assertEquals } from "jsr:@std/assert@1";
import { finishPlan, setupProblems } from "./owner_invite.ts";

const inv = (id: string, status: string, role: string, created: string, extra = {}) =>
  ({ id, email: `${id}@x.test`, owner_name: id, status, role, created_at: created, ...extra });

Deno.test("finish plan for every invitation state", () => {
  const now = new Date("2026-11-04T12:00:00Z");
  assertEquals(finishPlan(null, now).kind, "missing");
  assertEquals(finishPlan(inv("x", "revoked", "owner", ""), now).kind, "revoked");
  assertEquals(finishPlan(inv("x", "accepted", "owner", ""), now).kind, "accepted");
  assertEquals(finishPlan(inv("x", "expired", "owner", ""), now).kind, "send");   // open: may be sent again
  assertEquals(finishPlan(inv("x", "sent", "owner", "", { expires_at: "2026-11-01T00:00:00Z" }), now).kind, "expired");
  assertEquals(finishPlan(inv("x", "sent", "owner", "", { expires_at: "2026-11-10T00:00:00Z" }), now).kind, "sent");
  assertEquals(finishPlan(inv("x", "pending", "owner", ""), now).kind, "send");
  assertEquals(finishPlan(inv("x", "failed", "owner", ""), now).kind, "send");
});

Deno.test("server-side required setup", () => {
  assertEquals(setupProblems({ name: "Glow", industryId: "i", openDays: 1, documentsReady: true, documentsMissing: [] }), []);
  assertEquals(setupProblems({ name: " ", industryId: null, openDays: 0, documentsReady: false, documentsMissing: ["photo_id"] }).length, 4);
});

// A fake world for finishSetupWith: one owner invitation, counts of emails and activations.
import { finishSetupWith, type FinishDeps } from "./owner_invite.ts";
function world(status: string, opts: { sendFails?: boolean; extra?: Partial<FinishDeps>; docs?: boolean; openDays?: number; expires?: string } = {}) {
  const st = { inv: { id: "i1", email: "owner@x.test", owner_name: "O", status, role: "owner", expires_at: opts.expires ?? null, auth_user_id: null as string | null },
    emails: 0, activated: 0 };
  const deps: FinishDeps = {
    business: () => Promise.resolve({ name: "Glow", industry_id: "ind", cancelled_at: null }),
    ownerInvitation: () => Promise.resolve({ ...st.inv }),
    documents: () => Promise.resolve({ ready: opts.docs ?? true, missing: opts.docs === false ? ["photo_id"] : [] }),
    openDays: () => Promise.resolve(opts.openDays ?? 5),
    claim: (_id) => { const ok = ["pending", "failed", "expired"].includes(st.inv.status); if (ok) st.inv.status = "sent"; return Promise.resolve(ok); },
    sendInvite: async () => { st.emails++; await new Promise((r) => setTimeout(r, 5)); return opts.sendFails ? { error: "smtp down" } : { userId: "u1" }; },
    release: (_id, _r) => { if (st.inv.status === "sent" && !st.inv.auth_user_id) st.inv.status = "failed"; return Promise.resolve(); },
    recordSent: (_id, uid) => { st.inv.auth_user_id = uid; return Promise.resolve(null); },
    activate: () => { st.activated++; return Promise.resolve(); },
    now: () => new Date("2026-11-04T12:00:00Z"),
    ...opts.extra,
  };
  return { st, deps };
}
const rejects = async (p: Promise<unknown>) => { try { await p; return null; } catch (e) { return e as { status: number; message: string }; } };

Deno.test("finish: pending sends once and activates; already sent/accepted send nothing", async () => {
  const w = world("pending");
  assertEquals((await finishSetupWith(w.deps)).invitationStatus, "sent");
  assertEquals([w.st.emails, w.st.activated, w.st.inv.status], [1, 1, "sent"]);
  // a retry after success sends nothing more
  assertEquals((await finishSetupWith(w.deps)).invitationStatus, "sent");
  assertEquals(w.st.emails, 1);
  const a = world("accepted"); await finishSetupWith(a.deps); assertEquals([a.st.emails, a.st.activated], [0, 1]);
});

Deno.test("finish: two clicks at once send one email; the second is told it's already running", async () => {
  const w = world("pending");
  const [r1, r2] = await Promise.allSettled([finishSetupWith(w.deps), finishSetupWith(w.deps)]);
  assertEquals(w.st.emails, 1);
  assertEquals([r1.status, r2.status].sort(), ["fulfilled", "rejected"]);
});

Deno.test("finish: email failure is not reported as finished, nothing activated, Retry sends again", async () => {
  const w = world("pending", { sendFails: true });
  const r = await finishSetupWith(w.deps);
  assertEquals([r.completed, r.invitationStatus, w.st.activated, w.st.inv.status], [false, "failed", 0, "failed"]);
  const ok = world("failed");
  assertEquals((await finishSetupWith(ok.deps)).completed, true);
});

Deno.test("finish: revoked, expired, missing invitation and missing required setup stop before any email", async () => {
  for (const [status, code, expires] of [["revoked", 409, null], ["sent", 409, "2026-11-01T00:00:00Z"]] as const) {
    const w = world(status, { expires: expires ?? undefined });
    assertEquals((await rejects(finishSetupWith(w.deps)))?.status, code, status);
    assertEquals([w.st.emails, w.st.activated], [0, 0]);
  }
  const none = world("pending", { extra: { ownerInvitation: () => Promise.resolve(null) } });
  assertEquals((await rejects(finishSetupWith(none.deps)))?.status, 400);
  for (const opts of [{ docs: false }, { openDays: 0 }]) {
    const w = world("pending", opts);
    const e = await rejects(finishSetupWith(w.deps));
    assertEquals([e?.status, w.st.emails, w.st.activated], [400, 0, 0]);
  }
});

Deno.test("finish: cancelled while the email was going out: not completed, nothing activated", async () => {
  const w = world("pending", { extra: { recordSent: () => Promise.resolve("closed" as const) } });
  const r = await finishSetupWith(w.deps);
  assertEquals([r.completed, r.invitationStatus, w.st.activated], [false, "closed", 0]);
});
