import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { platformHandlers, type PlatformKit } from "./platform.ts";
class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit: PlatformKit = {
  text: (v, max = 300) => typeof v === "string" ? v.trim().slice(0, max) : "",
  bool: (v, fallback = false) => typeof v === "boolean" ? v : fallback,
  obj: (v) => v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {},
  requireId: () => "business", InputError,
};
Deno.test("live switches enforce role, reason and boolean values before writing", async () => {
  for (const field of ["live", "ai_live"]) {
    for (const role of [null, "admin", "zella_owner", "super_admin"]) {
      for (const [value, reason] of [[true, "  approved  "], [true, " a "], [false, ""], ["true", "approved"], [1, "approved"], [null, "approved"]]) {
        const writes: unknown[] = [];
        const admin = { from: () => ({
          select: () => ({ in: async () => ({ data: [], error: null }) }),
          upsert: async (rows: unknown) => { writes.push(rows); return { error: null }; },
        }) } as unknown as SupabaseClient;
        const run = platformHandlers(admin, { automation: { [field]: value }, reason }, kit, "user", role).handlers.spam_admin_automation_save;
        const authorized = role === "zella_owner" || role === "super_admin";
        if (typeof value !== "boolean" || (value && (!authorized || String(reason).trim().length < 3))) {
          const err = await assertRejects(run, InputError);
          assertEquals((err as InputError).status, value === true && !authorized ? 403 : 400);
          assertEquals(writes, []);
        } else {
          assertEquals(await run(), { before: {}, after: { [field === "live" ? "spam_workflow_live" : "spam_ai_live"]: value }, reason: String(reason).trim() || null });
          assertEquals(writes.length, 1);
        }
      }
    }
  }
});
Deno.test("applying a CRM preset requires an inserted count and preserves RPC errors", async () => {
  for (const count of [0, 2, -1]) {
    const admin = {
      from: (table: string) => ({ select: () => ({ eq: () => ({
        maybeSingle: async () => ({ data: { id: "business" }, error: null }),
        limit: async () => ({ data: [], error: null }),
      }) }) }),
      rpc: async () => ({ data: count, error: count === -1 ? new Error("RPC failure") : null }),
    } as unknown as SupabaseClient;
    const run = platformHandlers(admin, { applyPreset: true }, kit).handlers.business_records_save;
    if (count === -1) await assertRejects(run, Error, "RPC failure");
    else if (!count) await assertRejects(run, InputError, "No record types");
    else assertEquals(await run(), { businessId: "business", changes: [{ applied_preset: true, count: 2 }] });
  }
});
