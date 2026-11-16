import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { LIFECYCLE_PERMISSIONS, createDraft, lifecycleHandlers, type LifecycleKit } from "./lifecycle.ts";
import { PERMISSIONS } from "./settings.ts";
import { ONBOARDING_PERMISSIONS } from "./onboarding.ts";
import { PLATFORM_PERMISSIONS } from "./platform.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
const kit: LifecycleKit = {
  text: (v, max = 300) => typeof v === "string" ? v.trim().slice(0, max) : "",
  bool: (v, fallback = false) => typeof v === "boolean" ? v : fallback,
  obj: (v) => v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {},
  requireId: (v) => String(v), InputError,
};
type Call = { fn: string; args: Record<string, unknown> };
const rpcAdmin = (answer: (call: Call) => { data: unknown; error: unknown }, calls: Call[]) =>
  ({ rpc: async (fn: string, args: Record<string, unknown>) => { const c = { fn, args }; calls.push(c); return answer(c); } }) as unknown as SupabaseClient;
const KEY = "c1000000-0000-0000-0000-000000000001";
const BIZ = "b1000000-0000-0000-0000-000000000001";

Deno.test("every lifecycle action has a permission, and none shadows an existing action", () => {
  for (const [action, permission] of Object.entries(LIFECYCLE_PERMISSIONS)) {
    assertEquals(typeof permission, "string");
    assertEquals(action in PERMISSIONS || action in ONBOARDING_PERMISSIONS || action in PLATFORM_PERMISSIONS, false, action);
  }
  const handlers = lifecycleHandlers(rpcAdmin(() => ({ data: null, error: null }), []), {}, kit).handlers;
  assertEquals(Object.keys(handlers).sort(), Object.keys(LIFECYCLE_PERMISSIONS).sort());
  assertEquals(LIFECYCLE_PERMISSIONS.setup_check_duplicates, "businesses.manage");
});

Deno.test("createDraft sends the creation key, so a retry gets the business the first try made", async () => {
  const calls: Call[] = [];
  const admin = rpcAdmin(() => ({ data: { business_id: BIZ, existing: true }, error: null }), calls);
  const r = await createDraft(admin, { name: "Glow" }, KEY);
  assertEquals(r.data, { business_id: BIZ, existing: true });
  assertEquals(calls, [{ fn: "zella_create_business_draft", args: { p_fields: { name: "Glow" }, p_creation_key: KEY } }]);
});

Deno.test("createDraft falls back to the old function before the migration, and without a key", async () => {
  const calls: Call[] = [];
  const admin = rpcAdmin((c) => "p_creation_key" in c.args
    ? { data: null, error: { code: "PGRST202", message: "Could not find the function" } }
    : { data: { business_id: BIZ }, error: null }, calls);
  assertEquals((await createDraft(admin, { name: "Glow" }, KEY)).data, { business_id: BIZ });
  assertEquals(calls.map((c) => Object.keys(c.args)), [["p_fields", "p_creation_key"], ["p_fields"]]);
  calls.length = 0;
  await createDraft(admin, { name: "Glow" }, "");
  assertEquals(calls.map((c) => Object.keys(c.args)), [["p_fields"]]);
});

Deno.test("createDraft passes other errors through without retrying the old way", async () => {
  const calls: Call[] = [];
  const admin = rpcAdmin(() => ({ data: null, error: { code: "P0001", message: "INDUSTRY_NOT_FOUND" } }), calls);
  const r = await createDraft(admin, {}, KEY);
  assertEquals(r.error?.message, "INDUSTRY_NOT_FOUND");
  assertEquals(calls.length, 1);
});

Deno.test("setup_check_duplicates lists matches and keeps only known match kinds", async () => {
  const calls: Call[] = [];
  const admin = rpcAdmin(() => ({
    data: [{ id: BIZ, name: "Glow Dental", onboarding_status: "business_info", is_active: false, created_at: "2026-11-01T00:00:00Z", matched: ["name", "website", "<script>"] }],
    error: null,
  }), calls);
  const run = lifecycleHandlers(admin, { creationKey: KEY, business: { name: " Glow Dental ", phone: "555 201 3344", website: "glow.example" } }, kit).handlers.setup_check_duplicates;
  assertEquals(await run(), {
    checked: true,
    duplicates: [{ id: BIZ, name: "Glow Dental", onboardingStatus: "business_info", isActive: false, createdAt: "2026-11-01T00:00:00Z", matched: ["name", "website"] }],
  });
  assertEquals(calls[0], { fn: "zella_business_duplicates", args: { p_name: "Glow Dental", p_phone: "555 201 3344", p_website: "glow.example", p_exclude: null, p_creation_key: KEY } });
});

Deno.test("setup_check_duplicates leaves the business itself out, refuses a bad id, and is empty before the migration", async () => {
  const calls: Call[] = [];
  const missing = rpcAdmin(() => ({ data: null, error: { code: "PGRST202", message: "missing" } }), calls);
  const handlers = (f: Record<string, unknown>) => lifecycleHandlers(missing, f, kit).handlers;
  assertEquals(await handlers({ business: { name: "Glow" }, businessId: BIZ }).setup_check_duplicates(), { duplicates: [], checked: false });
  assertEquals(calls[0].args.p_exclude, BIZ);
  await assertRejects(() => handlers({ business: { name: "Glow" }, businessId: "not-an-id" }).setup_check_duplicates(), InputError, "valid business");
  await assertRejects(() => handlers({ business: { name: "Glow" }, creationKey: "1; drop" }).setup_check_duplicates(), InputError, "creation key");
  calls.length = 0;
  assertEquals(await handlers({ business: {} }).setup_check_duplicates(), { duplicates: [], checked: false });
  assertEquals(calls.length, 0);
  const failing = rpcAdmin(() => ({ data: null, error: new Error("database down") }), []);
  await assertRejects(() => lifecycleHandlers(failing, { business: { name: "Glow" } }, kit).handlers.setup_check_duplicates(), Error, "database down");
});
