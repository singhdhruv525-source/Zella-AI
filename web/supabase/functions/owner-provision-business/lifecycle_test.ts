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
  requireId: (v) => { const id = String(v ?? ""); if (!/^[0-9a-f-]{36}$/.test(id)) throw new InputError("A valid business is required"); return id; }, InputError,
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

type Removed = string[][];
const deleteAdmin = (answer: { data: unknown; error: unknown }, calls: Call[], removed: Removed, removeError: unknown = null) => ({
  rpc: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return answer; },
  storage: { from: (bucket: string) => ({ remove: async (paths: string[]) => { removed.push([bucket, ...paths]); return { error: removeError }; } }) },
}) as unknown as SupabaseClient;
const okDelete = { data: { business_id: BIZ, name: "Glow", paths: [`${BIZ}/owner_identity/a.pdf`, `${BIZ}/x/b.png`, "other-business/c.pdf"] }, error: null };
const deleteFields = { businessId: BIZ, confirmName: "Glow", reason: "Made by mistake" };

Deno.test("business_delete_draft: only a Zella Voice owner or super admin, before any database call", async () => {
  for (const role of [null, "read_only_admin", "support_admin", "platform_operations", "billing_admin", "security_admin"]) {
    const calls: Call[] = [];
    const err = await assertRejects(() => lifecycleHandlers(deleteAdmin(okDelete, calls, []), deleteFields, kit, "user", role).handlers.business_delete_draft(), InputError);
    assertEquals((err as InputError).status, 403);
    assertEquals(calls.length, 0);
  }
});

Deno.test("business_delete_draft needs the typed name and a reason", async () => {
  for (const f of [{ ...deleteFields, confirmName: " " }, { ...deleteFields, reason: "x" }]) {
    const calls: Call[] = [];
    await assertRejects(() => lifecycleHandlers(deleteAdmin(okDelete, calls, []), f, kit, "user", "zella_owner").handlers.business_delete_draft(), InputError);
    assertEquals(calls.length, 0);
  }
});

Deno.test("business_delete_draft passes the actor, removes only that business's files, and reports what is left", async () => {
  for (const role of ["zella_owner", "super_admin"]) {
    const calls: Call[] = []; const removed: Removed = [];
    const r = await lifecycleHandlers(deleteAdmin(okDelete, calls, removed), deleteFields, kit, "actor", role).handlers.business_delete_draft();
    assertEquals(calls[0], { fn: "zella_delete_draft_business", args: { p_business_id: BIZ, p_actor: "actor", p_confirm_name: "Glow", p_reason: "Made by mistake" } });
    assertEquals(removed, [["business-documents", `${BIZ}/owner_identity/a.pdf`, `${BIZ}/x/b.png`]]);
    assertEquals(r, { businessId: BIZ, name: "Glow", deleted: true, filesRemoved: 2, filesLeft: 0 });
  }
  const removed: Removed = [];
  const r = await lifecycleHandlers(deleteAdmin(okDelete, [], removed, new Error("storage down")), deleteFields, kit, "actor", "zella_owner").handlers.business_delete_draft();
  assertEquals((r as Record<string, unknown>).filesLeft, 2);
});

Deno.test("business_delete_draft explains why a business is not a draft, and keeps database errors", async () => {
  const cases: [string, number, string][] = [
    ["NOT_A_DRAFT: calls,phone_numbers", 409, "it has calls, it has phone numbers"],
    ["NAME_MISMATCH", 400, "doesn't match"], ["NOT_FOUND", 404, "not found"], ["NOT_ALLOWED", 403, "super admin"],
  ];
  for (const [message, status, words] of cases) {
    const err = await assertRejects(() => lifecycleHandlers(deleteAdmin({ data: null, error: { message } }, [], []), deleteFields, kit, "actor", "zella_owner").handlers.business_delete_draft(), InputError);
    assertEquals((err as InputError).status, status);
    assertEquals(err.message.includes(words), true, err.message);
  }
  await assertRejects(() => lifecycleHandlers(deleteAdmin({ data: null, error: new Error("database down") }, [], []), deleteFields, kit, "actor", "zella_owner").handlers.business_delete_draft(), Error, "database down");
});
