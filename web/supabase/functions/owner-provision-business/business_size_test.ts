import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { DETAIL_PERMISSIONS, detailHandlers } from "./detail.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => {
  if (typeof v !== "string" || !/^[0-9a-f-]{36}$/.test(v)) throw new InputError("A valid business is required"); return v;
}, InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";

// One businesses row; the update applies only when its filters match (the compare and set).
function world(size: string | null, opts: { missing?: boolean; changeBeforeUpdate?: string | null } = {}) {
  const st = { size, updates: 0 };
  const client = { from: () => {
    const filters: [string, string, unknown][] = [];
    let patch: Record<string, unknown> | null = null;
    const chain: Record<string, unknown> = {
      select: () => chain,
      update: (p: Record<string, unknown>) => ((patch = p), chain),
      eq: (c: string, v: unknown) => (filters.push(["eq", c, v]), chain),
      is: (c: string, v: unknown) => (filters.push(["is", c, v]), chain),
      maybeSingle: () => Promise.resolve({ data: opts.missing ? null : { id: BIZ, business_size: st.size }, error: null }),
      then: (resolve: (v: unknown) => unknown) => {
        if (!patch) return resolve({ data: [], error: null });
        if (opts.changeBeforeUpdate !== undefined) st.size = opts.changeBeforeUpdate;
        const match = filters.every(([op, c, v]) => c === "id" ? v === BIZ : c === "business_size" ? (op === "is" ? st.size === null : st.size === v) : true);
        if (match) { st.size = patch.business_size as string | null; st.updates++; }
        return resolve({ data: match ? [{ id: BIZ }] : [], error: null });
      },
    };
    return chain;
  } };
  return { st, client: client as unknown as SupabaseClient };
}
const save = (w: ReturnType<typeof world>, size: unknown, businessId: unknown = BIZ) =>
  detailHandlers(w.client, { businessId, size }, kit).handlers.business_size_save() as Promise<Record<string, unknown>>;
const audit = (r: Record<string, unknown>) => detailHandlers(world(null).client, {}, kit).audited.business_size_save(r);

Deno.test("business size: needs businesses.manage", () => {
  assertEquals(DETAIL_PERMISSIONS.business_size_save, "businesses.manage");
});

Deno.test("business size: saves, and records before and after", async () => {
  const w = world("small");
  const r = await save(w, "large");
  assertEquals([r.before, r.size, r.changed, w.st.size, w.st.updates], ["small", "large", true, "large", 1]);
  assertEquals(audit(r), { action: "business.size_changed", business_id: BIZ, entity_type: "business", entity_id: BIZ, old_data: { size: "small" }, new_data: { size: "large" } });
  const cleared = await save(world("medium"), "");
  assertEquals([cleared.size, cleared.before], [null, "medium"]);
  const set = await save(world(null), "small");
  assertEquals([set.size, set.before, set.changed], ["small", null, true]);
});

Deno.test("business size: the same value changes nothing and records nothing", async () => {
  const w = world("small");
  const r = await save(w, "small");
  assertEquals([r.changed, w.st.updates], [false, 0]);
  assertEquals(audit(r), null);
});

Deno.test("business size: wrong values, wrong business and a change meanwhile are refused", async () => {
  await assertRejects(() => save(world("small"), "huge"), InputError, "Choose Small");
  await assertRejects(() => save(world("small"), "large", "not-an-id"), InputError, "valid business");
  const missing = await assertRejects(() => save(world(null, { missing: true }), "large"), InputError) as InputError;
  assertEquals(missing.status, 404);
  const w = world("small", { changeBeforeUpdate: "medium" });
  const raced = await assertRejects(() => save(w, "large"), InputError) as InputError;
  assertEquals([raced.status, w.st.size, w.st.updates], [409, "medium", 0]);
});
