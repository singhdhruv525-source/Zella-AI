import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { DETAIL_PERMISSIONS, detailHandlers } from "./detail.ts";
import { MEMBER_SUPPORT_PERMISSION, reasonProblem, statusProblem } from "./member_support.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => String(v), InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";
const OWNER = { user_id: "o1", role: "owner", status: "active" };
const OWNER2 = { user_id: "o2", role: "owner", status: "active" };
const STAFF = { user_id: "s1", role: "staff", status: "active" };
const GONE = { user_id: "s2", role: "staff", status: "suspended" };
const REASON = "Owner asked to remove this person";

Deno.test("member support: the defaults", () => {
  assertEquals(MEMBER_SUPPORT_PERMISSION, "businesses.manage");
  assertEquals(DETAIL_PERMISSIONS.member_set_status, "businesses.manage");
  assertEquals(reasonProblem("too short") !== null, true);
  assertEquals(reasonProblem(REASON), null);
});

Deno.test("status rules: never the last active owner; only real changes", () => {
  assertEquals(statusProblem([OWNER, STAFF], "o1", "suspended")?.status, 409);
  assertEquals(statusProblem([OWNER, OWNER2], "o1", "suspended"), null);
  assertEquals(statusProblem([OWNER, STAFF], "s1", "suspended"), null);
  assertEquals(statusProblem([OWNER, GONE], "s2", "active"), null);
  assertEquals(statusProblem([OWNER, STAFF], "s1", "active")?.status, 409);
  assertEquals(statusProblem([OWNER], "x9", "suspended")?.status, 404);   // wrong business
  assertEquals(statusProblem([OWNER, STAFF], "s1", "inactive")?.status, 400);
  assertEquals(statusProblem([OWNER, { user_id: "i1", role: "staff", status: "invited" }], "i1", "active")?.status, 409);
});

// The members as the page read them, and zella_admin_member_set_status as the database answers (one locked step;
// tested on the database by tests/member_admin): STALE when the status isn't the expected one, LAST_OWNER, NOT_MEMBER.
function world(members: { user_id: string; role: string; status: string }[], raceTo?: string) {
  const st = { members: members.map((m) => ({ ...m })), calls: [] as unknown[] };
  const reply = (data: unknown, message?: string) => Promise.resolve(message ? { data: null, error: { message } } : { data, error: null });
  const client = {
    from: () => {
      const c: Record<string, unknown> = {};
      c.select = () => c; c.eq = () => c;
      c.then = (resolve: (v: unknown) => unknown) => resolve({ data: st.members.map((m) => ({ ...m })), error: null });
      return c;
    },
    rpc: (fn: string, a: { p_user_id: string; p_status: string; p_expected: string; p_seen_at: string | null }) => {
      st.calls.push([fn, a]);
      const m = st.members.find((x) => x.user_id === a.p_user_id);
      if (m && raceTo) m.status = raceTo;   // changed by someone else after the page read it
      if (!m) return reply(null, "NOT_MEMBER");
      if (m.status !== a.p_expected) return reply(null, "STALE");
      if (a.p_status === "suspended" && m.role === "owner" && !st.members.some((x) => x !== m && x.role === "owner" && x.status === "active")) return reply(null, "LAST_OWNER");
      const before = m.status; m.status = a.p_status;
      return reply({ role: m.role, before });
    },
  };
  return { st, client: client as unknown as SupabaseClient };
}
const SEEN = "2026-11-19T06:00:00.000Z";
const setStatus = (w: ReturnType<typeof world>, userId: string, status: string, reason = REASON, expected?: string) =>
  detailHandlers(w.client, { businessId: BIZ, userId, status, reason, expected: expected ?? w.st.members.find((m) => m.user_id === userId)?.status ?? "active", seenAt: SEEN }, kit, "admin-1")
    .handlers.member_set_status() as Promise<Record<string, unknown>>;

Deno.test("member_set_status: deactivates and reactivates; the database writes the audit row", async () => {
  const w = world([OWNER, STAFF]);
  const r = await setStatus(w, "s1", "suspended");
  assertEquals(w.st.members[1].status, "suspended");
  // the database function gets the admin and the reason and writes the audit row in its own transaction
  assertEquals(w.st.calls[0], ["zella_admin_member_set_status", { p_business_id: BIZ, p_user_id: "s1", p_status: "suspended", p_expected: "active", p_seen_at: SEEN, p_actor: "admin-1", p_reason: REASON }]);
  assertEquals([r.before, r.status], ["active", "suspended"]);
  assertEquals(detailHandlers(w.client, {}, kit).audited.member_set_status(r), null);
  const back = await setStatus(w, "s1", "active");
  assertEquals([back.before, back.status], ["suspended", "active"]);
});

Deno.test("member_set_status: refuses a short reason, the last owner, another business's person, a stale page and a change meanwhile", async () => {
  await assertRejects(() => setStatus(world([OWNER, STAFF]), "s1", "suspended", "short"), InputError, "at least");
  const last = await assertRejects(() => setStatus(world([OWNER, STAFF]), "o1", "suspended"), InputError) as InputError;
  assertEquals(last.status, 409);
  const other = await assertRejects(() => setStatus(world([OWNER]), "s1", "suspended"), InputError) as InputError;
  assertEquals(other.status, 404);
  const stale = await assertRejects(() => setStatus(world([OWNER, GONE]), "s2", "active", REASON, "active"), InputError) as InputError;
  assertEquals(stale.status, 409);
  const w = world([OWNER, STAFF], "suspended");
  const raced = await assertRejects(() => setStatus(w, "s1", "suspended"), InputError) as InputError;
  assertEquals(raced.status, 409);
  // without what the page showed, nothing is sent
  const blind = world([OWNER, STAFF]);
  await assertRejects(() => detailHandlers(blind.client, { businessId: BIZ, userId: "s1", status: "suspended", reason: REASON }, kit, "admin-1").handlers.member_set_status(), InputError);
  assertEquals(blind.st.calls.length, 0);
});
