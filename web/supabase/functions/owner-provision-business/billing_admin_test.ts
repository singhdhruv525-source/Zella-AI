// CFG-22: grant a pack through the admin's own client (never the server key), with the database's refusals in words.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { DETAIL_PERMISSIONS, PACK_GRANT_ERRORS, detailHandlers, packGrantError } from "./detail.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit = { text: (v: unknown, max = 500) => String(v ?? "").trim().slice(0, max), requireId: (v: unknown) => String(v), InputError };
const BIZ = "3e000000-0000-0000-0000-00000000b000";

function clients(answer: { data?: unknown; error?: { message: string } | null }) {
  const calls: { who: string; name: string; args: Record<string, unknown> }[] = [];
  const make = (who: string) => ({
    rpc: (name: string, args: Record<string, unknown>) => (calls.push({ who, name, args }), Promise.resolve({ data: answer.data ?? null, error: answer.error ?? null })),
    from: () => { const c: Record<string, unknown> = {}; c.select = () => c; c.eq = () => c; c.order = () => c;
      c.then = (r: (v: unknown) => unknown) => r({ data: [{ code: "minutes_100", resource: "minutes", quantity: 100, price_cents: 2900 }], error: null }); return c; },
  }) as unknown as SupabaseClient;
  return { admin: make("server"), caller: make("caller"), calls };
}
const grant = (c: ReturnType<typeof clients>, extra: Record<string, unknown> = {}) =>
  detailHandlers(c.admin, { businessId: BIZ, packCode: "minutes_100", reason: "Goodwill for an outage", idempotencyKey: "dialog-key-1234", ...extra }, kit, "admin-1", c.caller)
    .handlers.business_pack_grant() as Promise<Record<string, unknown>>;

Deno.test("packs: permissions", () => {
  assertEquals(DETAIL_PERMISSIONS.business_pack_catalog, "billing.view");
  assertEquals(DETAIL_PERMISSIONS.business_pack_grant, "billing.manage");
});

Deno.test("grant: runs as the admin (caller client), never the server key, with the dialog's key", async () => {
  const c = clients({ data: { result: "granted", pack_purchase_id: "pp1" } });
  const r = await grant(c);
  assertEquals(r.result, "granted");
  assertEquals(c.calls.map((x) => [x.who, x.name]), [["caller", "zella_admin_pack_grant"]]);
  assertEquals(c.calls[0].args.p_idempotency_key, "dialog-key-1234");
  assertEquals(detailHandlers(c.admin, {}, kit).audited.business_pack_grant({}), null);
});

Deno.test("grant: the database's refusals read as words", async () => {
  for (const code of Object.keys(PACK_GRANT_ERRORS)) {
    const c = clients({ error: { message: code } });
    const err = await assertRejects(() => grant(c), InputError) as InputError;
    assertEquals([err.message, err.status], PACK_GRANT_ERRORS[code], code);
  }
  assertEquals(packGrantError("something else"), null);
  await assertRejects(() => grant(clients({}), { reason: "no" }), InputError, "at least 5");
  await assertRejects(() => grant(clients({}), { packCode: "" }), InputError, "Choose a pack");
});

Deno.test("catalog: active packs", async () => {
  const c = clients({});
  const r = await detailHandlers(c.admin, {}, kit).handlers.business_pack_catalog() as { packs: unknown[] };
  assertEquals(r.packs.length, 1);
});
