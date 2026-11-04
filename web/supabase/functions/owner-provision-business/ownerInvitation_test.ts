// Mocked: an in-memory table that applies the same filters PostgREST would. No network, no database.
import { assertEquals } from "jsr:@std/assert@1";
import { latestOwnerInvitation, moveOwnerInvitation } from "./ownerInvitation.ts";

type Row = Record<string, unknown>;
function fakeAdmin(rows: Row[]) {
  return {
    from() {
      const filters: ((r: Row) => boolean)[] = [];
      let patch: Row | null = null, order: string | null = null, desc = false, lim = Infinity;
      const run = () => {
        let out = rows.filter((r) => filters.every((f) => f(r)));
        if (order) out = [...out].sort((a, b) => String(a[order!]).localeCompare(String(b[order!])) * (desc ? -1 : 1));
        out = out.slice(0, lim);
        if (patch) out.forEach((r) => Object.assign(r, patch));
        return out;
      };
      const q: Record<string, unknown> = {
        select: () => q, update: (p: Row) => { patch = p; return q; },
        eq: (k: string, v: unknown) => { filters.push((r) => r[k] === v); return q; },
        neq: (k: string, v: unknown) => { filters.push((r) => r[k] !== v); return q; },
        in: (k: string, v: unknown[]) => { filters.push((r) => v.includes(r[k])); return q; },
        order: (k: string, o: { ascending: boolean }) => { order = k; desc = !o.ascending; return q; },
        limit: (n: number) => { lim = n; return q; },
        maybeSingle: () => Promise.resolve({ data: run()[0] ?? null, error: null }),
        then: (res: (v: unknown) => void) => res({ data: run(), error: null }),
      };
      return q;
    },
  } as never;
}

Deno.test("finishing setup takes the owner invitation, not a newer staff invitation", async () => {
  const rows = [
    { id: "owner", business_id: "b", role: "owner", status: "pending", created_at: "2026-01-01" },
    { id: "staff", business_id: "b", role: "staff", status: "pending", created_at: "2026-02-01" },
  ];
  const { data } = await latestOwnerInvitation(fakeAdmin(rows), "b", "id");
  assertEquals((data as Row).id, "owner");
});

Deno.test("a cancelled owner invitation is not picked up again", async () => {
  const rows = [{ id: "owner", business_id: "b", role: "owner", status: "revoked", created_at: "2026-01-01" }];
  const { data } = await latestOwnerInvitation(fakeAdmin(rows), "b", "id");
  assertEquals(data, null);
});

Deno.test("a late 'sent' or 'failed' write can't reopen a cancelled or accepted invitation", async () => {
  for (const closed of ["revoked", "accepted"]) {
    const rows = [{ id: "i", role: "owner", status: closed }];
    assertEquals(await moveOwnerInvitation(fakeAdmin(rows), "i", { status: "sent" }), false);
    assertEquals(await moveOwnerInvitation(fakeAdmin(rows), "i", { status: "failed" }), false);
    assertEquals(rows[0].status, closed);
  }
});

Deno.test("open owner invitations move to sent; staff rows are never touched", async () => {
  const rows = [{ id: "i", role: "owner", status: "failed" }, { id: "s", role: "staff", status: "pending" }];
  assertEquals(await moveOwnerInvitation(fakeAdmin(rows), "i", { status: "sent" }), true);
  assertEquals(rows[0].status, "sent");
  assertEquals(await moveOwnerInvitation(fakeAdmin(rows), "s", { status: "sent" }), false);
  assertEquals(rows[1].status, "pending");
});
