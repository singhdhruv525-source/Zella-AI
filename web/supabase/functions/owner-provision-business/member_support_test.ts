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

function world(members: { user_id: string; role: string; status: string }[], raceTo?: string) {
  const st = { members: members.map((m) => ({ ...m })) };
  const client = { from: () => {
    const f: [string, unknown][] = []; let patch: Record<string, unknown> | null = null;
    const c: Record<string, unknown> = {};
    c.select = () => c; c.eq = (k: string, v: unknown) => (f.push([k, v]), c); c.update = (p: Record<string, unknown>) => ((patch = p), c);
    c.then = (resolve: (v: unknown) => unknown) => {
      if (!patch) return resolve({ data: st.members, error: null });
      const m = st.members.find((x) => x.user_id === f.find((y) => y[0] === "user_id")?.[1]);
      if (m && raceTo) m.status = raceTo;
      const ok = m && m.status === f.find((y) => y[0] === "status")?.[1];
      if (ok) m.status = String(patch.status);
      return resolve({ data: ok ? [{ user_id: m.user_id }] : [], error: null });
    };
    return c;
  } };
  return { st, client: client as unknown as SupabaseClient };
}
const setStatus = (w: ReturnType<typeof world>, userId: string, status: string, reason = REASON) =>
  detailHandlers(w.client, { businessId: BIZ, userId, status, reason }, kit, "admin-1").handlers.member_set_status() as Promise<Record<string, unknown>>;

Deno.test("member_set_status: deactivates and reactivates with old and new in the audit row", async () => {
  const w = world([OWNER, STAFF]);
  const r = await setStatus(w, "s1", "suspended");
  assertEquals(w.st.members[1].status, "suspended");
  const entry = detailHandlers(w.client, {}, kit).audited.member_set_status(r);
  assertEquals([entry?.action, (entry?.old_data as Record<string, unknown>).status, (entry?.new_data as Record<string, unknown>).status], ["member.suspended", "active", "suspended"]);
  const back = await setStatus(w, "s1", "active");
  assertEquals(detailHandlers(w.client, {}, kit).audited.member_set_status(back)?.action, "member.reactivated");
});

Deno.test("member_set_status: refuses a short reason, the last owner, another business's person and a change meanwhile", async () => {
  await assertRejects(() => setStatus(world([OWNER, STAFF]), "s1", "suspended", "short"), InputError, "at least");
  const last = await assertRejects(() => setStatus(world([OWNER, STAFF]), "o1", "suspended"), InputError) as InputError;
  assertEquals(last.status, 409);
  const other = await assertRejects(() => setStatus(world([OWNER]), "s1", "suspended"), InputError) as InputError;
  assertEquals(other.status, 404);
  const w = world([OWNER, STAFF], "suspended");
  const raced = await assertRejects(() => setStatus(w, "s1", "suspended"), InputError) as InputError;
  assertEquals(raced.status, 409);
});
