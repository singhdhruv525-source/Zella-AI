import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { onboardingHandlers, type OnboardingKit } from "./onboarding.ts";
const B = "11111111-2222-3333-4444-555555555555";
class InputError extends Error {}
const kit = {
  text: (v: unknown) => typeof v === "string" ? v : "", bool: (v: unknown, fallback = false) => typeof v === "boolean" ? v : fallback,
  obj: (v: unknown) => v && typeof v === "object" ? v : {}, requireId: () => B,
  getBusiness: async () => ({}), getReceptionist: async () => ({ agent: { id: "a" }, config: null }), InputError,
} as unknown as OnboardingKit;
Deno.test("invalid operations and team cannot write", async () => {
  const admin = { from: () => { throw new Error("unexpected write"); }, rpc: () => { throw new Error("unexpected RPC"); } } as unknown as SupabaseClient;
  for (const value of [undefined, null, [], "bad"]) {
    const { handlers } = onboardingHandlers(admin, { operations: value }, "u", kit);
    await assertRejects(handlers.setup_save_operations, InputError);
  }
  for (const value of [undefined, null, {}, Array(51).fill({})]) {
    const { handlers } = onboardingHandlers(admin, { team: value }, "u", kit);
    await assertRejects(handlers.setup_save_team, InputError);
  }
});
Deno.test("hours use the atomic RPC and stop on its failure", async () => {
  let called = false;
  const admin = {
    rpc: async (fn: string, args: unknown) => { called = true; assertEquals(fn, "zella_replace_business_hours"); assertEquals(args, { p_business_id: B, p_hours: [] }); return { error: new Error("insert failed") }; },
    from: () => { throw new Error("unexpected write"); },
  } as unknown as SupabaseClient;
  await assertRejects(onboardingHandlers(admin, { operations: {} }, "u", kit).handlers.setup_save_operations, Error, "insert failed");
  assertEquals(called, true);
});
Deno.test("document confirmation rejects missing and mismatched storage metadata before writes", async () => {
  const name = "11111111-2222-3333-4444-555555555555.pdf";
  for (const metadata of [undefined, { size: 1, mimetype: "application/pdf" }, { size: 2, mimetype: "text/html" }, { size: "2", mimetype: "application/pdf" }]) {
    const admin = { storage: { from: () => ({ list: async () => ({ data: [{ name, metadata }], error: null }) }) }, from: () => { throw new Error("unexpected write"); } } as unknown as SupabaseClient;
    const fields = { kind: "owner_identity", mimeType: "application/pdf", size: 2, path: `${B}/owner_identity/${name}` };
    await assertRejects(onboardingHandlers(admin, fields, "u", kit).handlers.setup_document_confirm, InputError, "metadata");
  }
});
