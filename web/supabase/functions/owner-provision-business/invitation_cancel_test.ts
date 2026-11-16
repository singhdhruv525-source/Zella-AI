// BIZ-21 part b: cancel an owner invitation (with a reason; the invited seat goes, so the person can be invited again),
// and the resend cooldown. sendOwnerEmail is never reached here.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { CANCEL_PERMISSION, DETAIL_PERMISSIONS, RESEND_COOLDOWN_MINUTES, detailHandlers, resendAllowedAt } from "./detail.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => String(v), InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";

// One owner invitation and one invited seat; updates and deletes apply only when their filters match.
function world(status: string, opts: { raceTo?: string } = {}) {
  const st = { status, seat: true, deletes: 0 };
  const client = { from: (table: string) => {
    const f: [string, string, unknown][] = [];
    let op: "select" | "update" | "delete" = "select";
    let patch: Record<string, unknown> = {};
    const c: Record<string, unknown> = {};
    for (const m of ["select", "order", "limit", "neq"]) c[m] = () => c;
    c.eq = (k: string, v: unknown) => (f.push(["eq", k, v]), c);
    c.in = (k: string, v: unknown) => (f.push(["in", k, v]), c);
    c.update = (p: Record<string, unknown>) => ((op = "update"), (patch = p), c);
    c.delete = () => ((op = "delete"), c);
    c.maybeSingle = () => Promise.resolve({ data: st.status === "revoked" ? null : { id: "inv1", email: "ola@people.example", status: st.status, auth_user_id: "u1" }, error: null });
    c.then = (resolve: (v: unknown) => unknown) => {
      if (table === "business_invitations" && op === "update") {
        if (opts.raceTo) st.status = opts.raceTo;
        const allowed = (f.find((x) => x[0] === "in" && x[1] === "status")?.[2] as string[]) ?? [];
        const ok = allowed.includes(st.status);
        if (ok) st.status = String(patch.status);
        return resolve({ data: ok ? [{ id: "inv1" }] : [], error: null });
      }
      if (table === "business_members" && op === "delete") {
        const ok = st.seat && f.some((x) => x[1] === "status" && x[2] === "invited") && f.some((x) => x[1] === "role" && x[2] === "owner");
        if (ok) { st.seat = false; st.deletes++; }
        return resolve({ data: ok ? [{ id: "m1" }] : [], error: null });
      }
      return resolve({ data: [], error: null });
    };
    return c;
  } };
  return { st, client: client as unknown as SupabaseClient };
}
const cancel = (w: ReturnType<typeof world>, reason: unknown = "Owner asked us to stop the invite") =>
  detailHandlers(w.client, { businessId: BIZ, reason }, kit, "admin-1").handlers.invitation_cancel() as Promise<Record<string, unknown>>;

Deno.test("cancel: the defaults", () => {
  assertEquals(DETAIL_PERMISSIONS.invitation_cancel, CANCEL_PERMISSION);
  assertEquals(CANCEL_PERMISSION, "businesses.manage");
  assertEquals(RESEND_COOLDOWN_MINUTES, 5);
});

Deno.test("cancel: revokes an open or sent invitation, removes the invited seat, records old and new", async () => {
  for (const status of ["pending", "sent", "failed", "expired"]) {
    const w = world(status);
    const r = await cancel(w);
    assertEquals([w.st.status, w.st.seat, r.seatRemoved, r.before], ["revoked", false, true, status], status);
    const entry = detailHandlers(w.client, {}, kit).audited.invitation_cancel(r);
    assertEquals(entry?.action, "invitation.revoked");
    assertEquals(entry?.old_data, { status });
    assertEquals((entry?.new_data as Record<string, unknown>).email, "o…@people.example");
  }
});

Deno.test("cancel: needs a reason; an accepted invitation, none, or one that changed meanwhile is refused", async () => {
  await assertRejects(() => cancel(world("sent"), "no"), InputError, "at least 10");
  const accepted = await assertRejects(() => cancel(world("accepted")), InputError) as InputError;
  assertEquals(accepted.status, 409);
  const none = await assertRejects(() => cancel(world("revoked")), InputError) as InputError;
  assertEquals(none.status, 404);
  const w = world("sent", { raceTo: "accepted" });   // accepted while the cancel was on its way
  const raced = await assertRejects(() => cancel(w), InputError) as InputError;
  assertEquals([raced.status, w.st.status, w.st.seat], [409, "accepted", true]);
});

Deno.test("resend cooldown: counted from the last invitation that went out", () => {
  const now = new Date("2026-11-16T12:00:00Z");
  assertEquals(resendAllowedAt(null, now), null);
  assertEquals(resendAllowedAt("2026-11-16T11:54:59Z", now), null);
  assertEquals(resendAllowedAt("2026-11-16T11:58:00Z", now)?.toISOString(), "2026-11-16T12:03:00.000Z");
});
