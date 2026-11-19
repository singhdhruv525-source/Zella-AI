// BIZ-21 part b: cancel an owner invitation (with a reason; the invited seat goes, so the person can be invited again),
// and the resend cooldown. sendOwnerEmail is never reached here.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { CANCEL_PERMISSION, DETAIL_PERMISSIONS, RESEND_COOLDOWN_MINUTES, detailHandlers, resendAllowedAt } from "./detail.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => String(v), InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";

// One owner invitation and one invited seat, as zella_admin_invitation_cancel (sql/zella_business_member_admin.sql,
// tested on the database by tests/member_admin) answers: only the latest open invitation, revoked with its seat at once.
function world(status: string, opts: { latest?: string; missing?: boolean; seatFails?: boolean } = {}) {
  const st = { status, seat: true, calls: [] as unknown[] };
  const client = {
    rpc: (fn: string, a: { p_business_id: string; p_invitation_id: string }) => {
      st.calls.push([fn, a]);
      if (opts.missing) return Promise.resolve({ data: null, error: { message: "Could not find the function public.zella_admin_invitation_cancel (PGRST202)" } });
      if (a.p_invitation_id !== "inv1") return Promise.resolve({ data: null, error: { message: "NOT_FOUND" } });
      if (st.status === "accepted") return Promise.resolve({ data: null, error: { message: "ACCEPTED" } });
      if ((opts.latest ?? "inv1") !== "inv1" || !["pending", "failed", "expired", "sent"].includes(st.status)) return Promise.resolve({ data: null, error: { message: "STALE" } });
      if (opts.seatFails) return Promise.resolve({ data: null, error: { message: "seat delete failed" } });   // nothing changed
      const before = st.status; st.status = "revoked"; st.seat = false;
      return Promise.resolve({ data: { before, seat_removed: true, email: "ola@people.example" }, error: null });
    },
  };
  return { st, client: client as unknown as SupabaseClient };
}
const cancel = (w: ReturnType<typeof world>, reason: unknown = "Owner asked us to stop the invite", invitationId: unknown = "inv1") =>
  detailHandlers(w.client, { businessId: BIZ, reason, invitationId }, kit, "admin-1").handlers.invitation_cancel() as Promise<Record<string, unknown>>;

Deno.test("cancel: the defaults", () => {
  assertEquals(DETAIL_PERMISSIONS.invitation_cancel, CANCEL_PERMISSION);
  assertEquals(CANCEL_PERMISSION, "businesses.manage");
  assertEquals(RESEND_COOLDOWN_MINUTES, 5);
});

Deno.test("cancel: revokes the invitation the page showed with its invited seat, records old and new", async () => {
  for (const status of ["pending", "sent", "failed", "expired"]) {
    const w = world(status);
    const r = await cancel(w);
    assertEquals([w.st.status, w.st.seat, r.seatRemoved, r.before], ["revoked", false, true, status], status);
    assertEquals(w.st.calls, [["zella_admin_invitation_cancel", { p_business_id: BIZ, p_invitation_id: "inv1" }]]);
    const entry = detailHandlers(w.client, {}, kit).audited.invitation_cancel(r);
    assertEquals(entry?.action, "invitation.revoked");
    assertEquals(entry?.old_data, { status });
    assertEquals((entry?.new_data as Record<string, unknown>).email, "o…@people.example");
  }
});

Deno.test("cancel: needs a reason and the shown invitation; accepted, stale, unknown or failed changes nothing", async () => {
  await assertRejects(() => cancel(world("sent"), "no"), InputError, "at least 10");
  const accepted = await assertRejects(() => cancel(world("accepted")), InputError) as InputError;
  assertEquals(accepted.status, 409);
  // a newer invitation exists: the old dialog never revokes it
  const newer = world("sent", { latest: "inv2" });
  const stale = await assertRejects(() => cancel(newer), InputError) as InputError;
  assertEquals([stale.status, newer.st.status, newer.st.seat], [409, "sent", true]);
  const none = await assertRejects(() => cancel(world("sent"), undefined, "inv9"), InputError) as InputError;
  assertEquals(none.status, 404);
  // the seat removal failed in the database: the invitation stays open, so cancelling again finishes it
  const failing = world("sent", { seatFails: true });
  await assertRejects(() => cancel(failing));
  assertEquals([failing.st.status, failing.st.seat], ["sent", true]);
  const missing = await assertRejects(() => cancel(world("sent", { missing: true })), InputError) as InputError;
  assertEquals(missing.status, 503);
});

Deno.test("resend cooldown: counted from the last invitation that went out", () => {
  const now = new Date("2026-11-16T12:00:00Z");
  assertEquals(resendAllowedAt(null, now), null);
  assertEquals(resendAllowedAt("2026-11-16T11:54:59Z", now), null);
  assertEquals(resendAllowedAt("2026-11-16T11:58:00Z", now)?.toISOString(), "2026-11-16T12:03:00.000Z");
});
