// UI-06 part d: the two step reset, with a mocked auth.admin.mfa client. No real reset anywhere.
import { assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { DETAIL_PERMISSIONS, detailHandlers } from "./detail.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => String(v), InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";
const REASON = "Owner lost their phone, checked on a call";

function world(opts: { member?: boolean; platformAdmin?: boolean; auditFails?: boolean; elsewhere?: boolean; factors?: { id: string; status: string }[] } = {}) {
  const st = { inserts: [] as Record<string, unknown>[], deleted: [] as { id: string; userId: string }[], listedFor: [] as string[] };
  const factors = opts.factors ?? [{ id: "f1", status: "verified" }, { id: "f2", status: "unverified" }, { id: "f3", status: "verified" }];
  const client = {
    auth: { admin: { mfa: {
      listFactors: ({ userId }: { userId: string }) => { st.listedFor.push(userId); return Promise.resolve({ data: { factors }, error: null }); },
      deleteFactor: (a: { id: string; userId: string }) => { st.deleted.push(a); return Promise.resolve({ data: null, error: null }); },
    } } },
    from: (table: string) => {
      const c: Record<string, unknown> = {};
      c.select = () => c; c.eq = () => c; c.neq = () => c; c.in = () => c; c.limit = () => c;
      // the person's memberships in other businesses (the list read)
      c.then = (resolve: (v: unknown) => unknown) => resolve({ data: table === "business_members" && opts.elsewhere ? [{ business_id: "other" }] : [], error: null });
      c.maybeSingle = () => Promise.resolve({ data: table === "business_members" ? (opts.member === false ? null : { user_id: "m1", role: "owner", status: "active" })
        : table === "platform_admins" ? (opts.platformAdmin ? { user_id: "m1" } : null) : null, error: null });
      c.insert = (row: Record<string, unknown>) => { st.inserts.push(row); return Promise.resolve({ error: opts.auditFails ? { message: "down" } : null }); };
      return c;
    },
  };
  return { st, client: client as unknown as SupabaseClient };
}
const reset = (w: ReturnType<typeof world>, extra: Record<string, unknown> = {}, adminId = "admin-1") =>
  detailHandlers(w.client, { businessId: BIZ, userId: "m1", reason: REASON, identityChecked: true, ...extra }, kit, adminId).handlers.member_mfa_reset() as Promise<Record<string, unknown>>;

Deno.test("two step reset: businesses.manage, reason and identity check required", async () => {
  assertEquals(DETAIL_PERMISSIONS.member_mfa_reset, "businesses.manage");
  await assertRejects(() => reset(world(), { reason: "lost it" }), InputError, "at least");
  await assertRejects(() => reset(world(), { identityChecked: false }), InputError, "Confirm");
  await assertRejects(() => reset(world(), { identityChecked: "yes" }), InputError, "Confirm");
});

Deno.test("two step reset: only that member's verified authenticators, audit first, count only", async () => {
  const w = world();
  const r = await reset(w);
  assertEquals(r.removed, 2);
  assertEquals(w.st.listedFor, ["m1"]);
  assertEquals(w.st.deleted, [{ id: "f1", userId: "m1" }, { id: "f3", userId: "m1" }]);
  assertEquals(w.st.inserts.length, 1);
  const row = JSON.stringify(w.st.inserts[0]);
  assertFalse(/f1|f3|secret|totp/.test(row), row);
  assertEquals((w.st.inserts[0].old_data as Record<string, unknown>).verified_factors, 2);
  assertEquals(detailHandlers(w.client, {}, kit).audited.member_mfa_reset({}), null);
});

Deno.test("two step reset: fails closed when the audit row can't be written", async () => {
  const w = world({ auditFails: true });
  const err = await assertRejects(() => reset(w), InputError) as InputError;
  assertEquals([err.status, w.st.deleted.length], [503, 0]);
});

Deno.test("two step reset: never a platform admin, yourself, another business's person, or someone without one", async () => {
  const admin = world({ platformAdmin: true });
  assertEquals(((await assertRejects(() => reset(admin), InputError)) as InputError).status, 403);
  assertEquals(admin.st.deleted.length, 0);
  assertEquals(((await assertRejects(() => reset(world(), {}, "m1"), InputError)) as InputError).status, 403);
  assertEquals(((await assertRejects(() => reset(world({ member: false })), InputError)) as InputError).status, 404);
  const none = world({ factors: [{ id: "f2", status: "unverified" }] });
  assertEquals(((await assertRejects(() => reset(none), InputError)) as InputError).status, 409);
  assertEquals(none.st.inserts.length, 0);
});

Deno.test("two step reset: never for someone who also belongs to another business (it protects that one too)", async () => {
  const w = world({ elsewhere: true });
  const err = await assertRejects(() => reset(w), InputError) as InputError;
  assertEquals([err.status, w.st.deleted.length, w.st.inserts.length], [409, 0, 0]);
});
