import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { DRAFT_ABANDON_DAYS_DEFAULT, LIFECYCLE_PERMISSIONS, createDraft, draftAges, lifecycleHandlers, trackSetup, type LifecycleKit } from "./lifecycle.ts";
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
    ["BUSY: an invitation for this business is being accepted right now", 409, "Try again"],
  ];
  for (const [message, status, words] of cases) {
    const err = await assertRejects(() => lifecycleHandlers(deleteAdmin({ data: null, error: { message } }, [], []), deleteFields, kit, "actor", "zella_owner").handlers.business_delete_draft(), InputError);
    assertEquals((err as InputError).status, status);
    assertEquals(err.message.includes(words), true, err.message);
  }
  await assertRejects(() => lifecycleHandlers(deleteAdmin({ data: null, error: new Error("database down") }, [], []), deleteFields, kit, "actor", "zella_owner").handlers.business_delete_draft(), Error, "database down");
});

// A small stand in for the tables draftAges reads: platform_settings, audit_logs and platform_alerts.
function agesAdmin(opts: { setting?: unknown; audit?: { business_id: string; created_at: string }[]; raised?: string[]; alertFails?: boolean; drafts?: Record<string, unknown>[] }) {
  const alerts: Record<string, unknown>[] = [];
  const admin = {
    from: (table: string) => {
      const q: Record<string, unknown> = {};
      const chain = {
        select: () => chain, eq: (k: string, v: unknown) => { q[k] = v; return chain; }, in: () => chain, order: () => chain,
        maybeSingle: async () => ({ data: opts.setting === undefined ? null : { value: opts.setting }, error: null }),
        limit: async () => ({ data: (opts.audit ?? []).filter((a) => !q.business_id || a.business_id === q.business_id).sort((x, y) => y.created_at.localeCompare(x.created_at)), error: null }),
        is: () => chain, neq: () => chain,
        range: async (from: number) => ({ data: table === "businesses" && from === 0 ? (opts.drafts ?? []) : [], error: null }),
        then: (resolve: (v: unknown) => void) => resolve(table === "platform_alerts"
          ? (opts.alertFails ? { data: null, error: new Error("alerts down") } : { data: (opts.raised ?? []).map((business_id) => ({ business_id })), error: null })
          : { data: [], error: null }),
      };
      return chain;
    },
    rpc: async (fn: string, args: Record<string, unknown>) => { alerts.push({ fn, ...args }); return { data: null, error: null }; },
  } as unknown as SupabaseClient;
  return { admin, alerts };
}
const NOW = Date.parse("2026-11-16T12:00:00Z");
const daysAgo = (d: number) => new Date(NOW - d * 86_400_000).toISOString();
const A = "a1000000-0000-0000-0000-000000000001", B = "a1000000-0000-0000-0000-000000000002", C = "a1000000-0000-0000-0000-000000000003";

Deno.test("draftAges: a draft untouched for 30 days is Abandoned, a recent audit entry counts as a change", async () => {
  const rows = [
    { id: A, name: "Old Draft", created_at: daysAgo(60), updated_at: daysAgo(45) },
    { id: B, name: "Saved Lately", created_at: daysAgo(60), updated_at: daysAgo(45) },
    { id: C, name: "New Draft", created_at: daysAgo(2), updated_at: daysAgo(2) },
  ];
  const { admin, alerts } = agesAdmin({ audit: [{ business_id: B, created_at: daysAgo(3) }, { business_id: A, created_at: daysAgo(40) }] });
  const { days, ages } = await draftAges(admin, rows, NOW);
  assertEquals(days, DRAFT_ABANDON_DAYS_DEFAULT);
  assertEquals(DRAFT_ABANDON_DAYS_DEFAULT, 30);
  assertEquals([ages.get(A)?.abandoned, ages.get(B)?.abandoned, ages.get(C)?.abandoned], [true, false, false]);
  assertEquals(ages.get(A)?.lastActivityAt, daysAgo(40));
  assertEquals(ages.get(B)?.lastActivityAt, daysAgo(3));
  assertEquals(alerts.length, 1);
  assertEquals(alerts[0].p_kind, "draft_abandoned");
  assertEquals(alerts[0].p_business_id, A);
  assertEquals(alerts[0].p_dedupe_key, `draft_abandoned:${A}`);
});

Deno.test("draftAges: alerts once ever per business, and the setting changes the days within limits", async () => {
  const rows = [{ id: A, name: "Old Draft", created_at: daysAgo(60), updated_at: daysAgo(20) }];
  const once = agesAdmin({ raised: [A], setting: 14 });
  const r = await draftAges(once.admin, rows, NOW);
  assertEquals([r.days, r.ages.get(A)?.abandoned, once.alerts.length], [14, true, 0]);
  for (const bad of [3, 1000, "soon", null]) {
    const x = agesAdmin({ setting: bad });
    assertEquals((await draftAges(x.admin, rows, NOW)).days, 30);
  }
  const fails = agesAdmin({ alertFails: true, setting: 14 });
  assertEquals((await draftAges(fails.admin, rows, NOW)).ages.get(A)?.abandoned, true);   // the page still loads
  assertEquals((await draftAges(agesAdmin({}).admin, [], NOW)).ages.size, 0);
});

Deno.test("privacy_overview lists cancelled businesses with their retention date and which are past it (BIZ-13c)", async () => {
  const { settingsHandlers } = await import("./settings.ts");
  const past = new Date(Date.now() - 86_400_000).toISOString(), later = new Date(Date.now() + 86_400_000 * 20).toISOString();
  const seen: string[] = [];
  const admin = {
    from: (table: string) => {
      const chain: Record<string, unknown> = {};
      const result = () => table === "businesses"
        ? { data: [{ id: A, name: "Old Co", cancelled_at: past, retention_until: past }, { id: B, name: "New Co", cancelled_at: past, retention_until: later }, { id: C, name: "No Date Co", cancelled_at: past, retention_until: null }], error: null }
        : { data: [], error: null };
      for (const m of ["select", "eq", "order", "limit", "in", "is"]) chain[m] = () => chain;
      chain.not = (col: string, op: string, v: unknown) => { seen.push(`${col} ${op} ${v}`); return chain; };
      chain.maybeSingle = async () => ({ data: null, error: null });
      chain.then = (resolve: (v: unknown) => void) => resolve(result());
      return chain;
    },
  } as unknown as SupabaseClient;
  const kitS = { ...kit, validTimezone: () => true, EMAIL_RE: /@/, UUID_RE: /./ };
  const r = await settingsHandlers(admin, {}, { userId: "u", role: "zella_owner", aal: "aal2", mfa: true }, kitS).handlers.privacy_overview() as Record<string, unknown>;
  assertEquals(seen, ["cancelled_at is null"]);
  assertEquals(r.retentionDays, 90);
  assertEquals(r.retentionSetting, "default");
  assertEquals((r.cancelled as { name: string; past_retention: boolean }[]).map((b) => [b.name, b.past_retention]), [["Old Co", true], ["New Co", false], ["No Date Co", false]]);
});

// A table stand in: every query on a table answers with that table's rows (or error); calls are recorded.
function tables(data: Record<string, unknown>, rpc: (fn: string, args: Record<string, unknown>) => { data: unknown; error: unknown } = () => ({ data: null, error: null })) {
  const calls: { table?: string; fn?: string; args?: Record<string, unknown> }[] = [];
  const admin = {
    from: (table: string) => {
      calls.push({ table });
      const answer = () => { const d = data[table]; return d instanceof Error || (d && typeof d === "object" && "code" in (d as object)) ? { data: null, error: d } : { data: d ?? null, error: null }; };
      const chain: Record<string, unknown> = {};
      for (const m of ["select", "eq", "neq", "in", "is", "order", "limit", "not"]) chain[m] = () => chain;
      // a page read: the table's rows on the first page, then nothing (as a short last page)
      chain.range = async (from: number) => { const r = answer(); return from === 0 || r.error ? r : { data: [], error: null }; };
      chain.maybeSingle = async () => { const r = answer(); return { ...r, data: Array.isArray(r.data) ? r.data[0] ?? null : r.data }; };
      chain.then = (resolve: (v: unknown) => void) => resolve(answer());
      return chain;
    },
    rpc: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return rpc(fn, args); },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

Deno.test("documents_missing lists drafts and live businesses that miss a required document, with the last request", async () => {
  const { admin } = tables({
    business_verification_documents: [
      { business_id: A, kind: "business_registration", status: "verified" }, { business_id: A, kind: "owner_identity", status: "pending_review" },
      { business_id: B, kind: "business_registration", status: "rejected" },
    ],
    businesses: [
      { id: A, name: "Complete Co", onboarding_status: "active", is_active: true, created_at: daysAgo(9) },
      { id: B, name: "Live Co", onboarding_status: "active", is_active: true, created_at: daysAgo(8) },
      { id: C, name: "Draft Co", onboarding_status: "owner_setup", is_active: false, created_at: daysAgo(1) },
    ],
    audit_logs: [{ business_id: B, created_at: daysAgo(2) }],
  });
  const r = await lifecycleHandlers(admin, {}, kit).handlers.documents_missing() as { rows: Record<string, unknown>[]; cooldownHours: number };
  assertEquals(r.rows.map((x) => [x.name, x.live, x.missing, x.last_requested_at]), [
    ["Live Co", true, ["business_registration", "owner_identity"], daysAgo(2)],
    ["Draft Co", false, ["business_registration", "owner_identity"], null],
  ]);
  assertEquals(r.cooldownHours, 24);
  const none = tables({ business_verification_documents: { code: "42P01", message: "relation does not exist" } });
  assertEquals(await lifecycleHandlers(none.admin, {}, kit).handlers.documents_missing(), { available: false, rows: [], required: ["business_registration", "owner_identity"] });
});

Deno.test("document_request queues S4 to the owner and is audited; it waits out the cooldown and refuses when nothing is missing", async () => {
  const base = { businesses: [{ id: A, name: "Draft Co", email: "front@draft.test", cancelled_at: null }], business_verification_documents: [], business_invitations: [{ email: "Owner@Draft.test" }], audit_logs: [] };
  const { admin, calls } = tables(base, () => ({ data: "email-1", error: null }));
  const h = lifecycleHandlers(admin, { businessId: A }, kit);
  const r = await h.handlers.document_request() as Record<string, unknown>;
  assertEquals([r.email, r.emailId, r.to, r.missing], ["queued", "email-1", "o…@draft.test", ["business_registration", "owner_identity"]]);
  const q = calls.find((c) => c.fn === "zella_queue_platform_email")!.args!;
  assertEquals([q.p_code, q.p_to, q.p_mandatory, String(q.p_dedupe_key).startsWith(`email:S4:${A}:`)], ["S4", "owner@draft.test", true, true]);
  assertEquals(String(q.p_html).includes("Draft Co"), true);
  // the key follows the last request, so two at once (or a retry after the audit failed) queue the email once
  assertEquals(q.p_dedupe_key, `email:S4:${A}:after:first`);
  const old = new Date(Date.now() - 30 * 3_600_000).toISOString();
  const again = tables({ ...base, audit_logs: [{ business_id: A, created_at: old }] }, () => ({ data: "email-2", error: null }));
  await lifecycleHandlers(again.admin, { businessId: A }, kit).handlers.document_request();
  const twice = tables({ ...base, audit_logs: [{ business_id: A, created_at: old }] }, () => ({ data: "email-2", error: null }));
  await lifecycleHandlers(twice.admin, { businessId: A }, kit).handlers.document_request();
  const keys = [again, twice].map((w) => w.calls.find((c) => c.fn === "zella_queue_platform_email")!.args!.p_dedupe_key);
  assertEquals(keys, [`email:S4:${A}:after:${old}`, `email:S4:${A}:after:${old}`]);
  assertEquals(h.audited.document_request(r), { action: "business.documents_requested", business_id: A, entity_type: "business", entity_id: A, new_data: { missing: r.missing, email: "queued", email_id: "email-1" } });

  const recent = tables({ ...base, audit_logs: [{ business_id: A, created_at: new Date(Date.now() - 3_600_000).toISOString() }] });
  const err = await assertRejects(() => lifecycleHandlers(recent.admin, { businessId: A }, kit).handlers.document_request(), InputError);
  assertEquals((err as InputError).status, 429);
  assertEquals(recent.calls.some((c) => c.fn), false);

  const complete = tables({ ...base, business_verification_documents: [{ kind: "business_registration", status: "verified" }, { kind: "owner_identity", status: "pending_review" }] });
  assertEquals(((await assertRejects(() => lifecycleHandlers(complete.admin, { businessId: A }, kit).handlers.document_request(), InputError)) as InputError).status, 409);
  const gone = tables({ ...base, businesses: [{ id: A, name: "Gone", cancelled_at: daysAgo(1) }] });
  assertEquals(((await assertRejects(() => lifecycleHandlers(gone.admin, { businessId: A }, kit).handlers.document_request(), InputError)) as InputError).status, 404);
  await assertRejects(() => lifecycleHandlers(admin, { businessId: "nope" }, kit).handlers.document_request(), InputError, "valid business");
});

Deno.test("document_request without the outbox is still recorded, and says email isn't installed", async () => {
  const { admin } = tables({ businesses: [{ id: A, name: "Draft Co", email: "front@draft.test", cancelled_at: null }], business_verification_documents: [], business_invitations: [], audit_logs: [] },
    () => ({ data: null, error: { code: "PGRST202", message: "Could not find the function" } }));
  const r = await lifecycleHandlers(admin, { businessId: A }, kit).handlers.document_request() as Record<string, unknown>;
  assertEquals([r.email, r.emailId, r.to], ["not_installed", null, "f…@draft.test"]);
  const noAddress = tables({ businesses: [{ id: A, name: "Draft Co", email: null, cancelled_at: null }], business_verification_documents: [], business_invitations: [], audit_logs: [] });
  assertEquals(((await lifecycleHandlers(noAddress.admin, { businessId: A }, kit).handlers.document_request()) as Record<string, unknown>).email, "no_address");
});

// SET-ONB-RETRY part 1: what trackSetup records
function trackAdmin(prior: { status: string; error: string | null } | null = null) {
  const log: string[] = [];
  // the step row as the database has it: a pending mark carries its own updated_at, as zella_track_provisioning writes
  const state: { row: Record<string, unknown> | null; marks: number } = { row: prior, marks: 0 };
  const admin = {
    rpc: async (fn: string, a: Record<string, unknown>) => {
      log.push(`${fn}:${a.p_step}:${a.p_status}${a.p_error ? `:${a.p_error}` : ""}`);
      state.row = { status: a.p_status, error: a.p_error ?? null, updated_at: `t${++state.marks}` };
      return { data: null, error: null };
    },
    from: () => {
      const chain: Record<string, unknown> = {};
      // a write applies (and is logged) only if the row matches its status and updated_at filters, as in the database
      const where: Record<string, unknown> = {}; let write: (() => void) | null = null;
      chain.select = () => chain;
      chain.eq = (k: string, v: unknown) => { where[k] = v; return chain; };
      const matches = () => ["status", "updated_at"].every((k) => !(k in where) || state.row?.[k] === where[k]);
      chain.maybeSingle = async () => ({ data: state.row, error: null });
      chain.update = (v: Record<string, unknown>) => { write = () => { log.push(`restore:${v.status}`); state.row = { ...state.row, ...v }; }; return chain; };
      chain.delete = () => { write = () => { log.push("delete pending"); state.row = null; }; return chain; };
      chain.then = (resolve: (v: unknown) => void) => { if (write && matches()) write(); resolve({ data: null, error: null }); };
      return chain;
    },
  } as unknown as SupabaseClient;
  return { admin, log, state };
}

Deno.test("trackSetup: an older attempt that ends late never overwrites what a newer attempt recorded", async () => {
  const refused = trackAdmin({ status: "failed", error: "old" });
  await assertRejects(() => trackSetup(refused.admin, "setup_save_modules", { businessId: A }, async () => {
    refused.state.row = { status: "done", error: null, updated_at: "newer" };   // another attempt finished meanwhile
    throw new InputError("Pick a module", 400);
  }), InputError);
  assertEquals(refused.log.includes("restore:failed"), false);
  const failed = trackAdmin();
  await assertRejects(() => trackSetup(failed.admin, "setup_save_modules", { businessId: A }, async () => {
    failed.state.row = { status: "done", error: null, updated_at: "newer" };
    throw new Error("database down");
  }), Error, "database down");
  assertEquals(failed.log, ["zella_track_provisioning:modules:pending"]);
});

Deno.test("trackSetup: each setup save is recorded pending, then done", async () => {
  for (const [action, step] of [["setup_save_modules", "modules"], ["setup_save_receptionist", "receptionist"], ["setup_save_operations", "operations"], ["setup_save_automations", "automations"]]) {
    const { admin, log } = trackAdmin();
    assertEquals(await trackSetup(admin, action, { businessId: A }, async () => ({ businessId: A, ok: 1 })), { businessId: A, ok: 1 });
    assertEquals(log, [`zella_track_provisioning:${step}:pending`, `zella_track_provisioning:${step}:done`]);
  }
});

Deno.test("trackSetup: an unexpected error is a failed step; a refused input puts the step back", async () => {
  const failing = trackAdmin();
  await assertRejects(() => trackSetup(failing.admin, "setup_save_integrations", { businessId: A }, async () => { throw new Error("database down"); }), Error, "database down");
  assertEquals(failing.log, ["zella_track_provisioning:integrations:pending", "zella_track_provisioning:integrations:failed:database down"]);
  const refusedNew = trackAdmin();
  await assertRejects(() => trackSetup(refusedNew.admin, "setup_save_modules", { businessId: A }, async () => { throw new InputError("Pick a module", 400); }), InputError);
  assertEquals(refusedNew.log, ["zella_track_provisioning:modules:pending", "delete pending"]);
  const refusedOld = trackAdmin({ status: "failed", error: "earlier" });
  await assertRejects(() => trackSetup(refusedOld.admin, "setup_save_modules", { businessId: A }, async () => { throw new InputError("Pick a module", 400); }), InputError);
  assertEquals(refusedOld.log, ["zella_track_provisioning:modules:pending", "restore:failed"]);
});

Deno.test("trackSetup: a new draft is recorded once it exists; other actions are not tracked", async () => {
  const created = trackAdmin();
  await trackSetup(created.admin, "setup_save_business", {}, async () => ({ businessId: B, created: true }));
  assertEquals(created.log, ["zella_track_provisioning:business:done"]);
  const other = trackAdmin();
  await trackSetup(other.admin, "business_detail", { businessId: A }, async () => ({}));
  assertEquals(other.log, []);
});

Deno.test("trackSetup: finishing records the owner invitation email as its own step", async () => {
  const ok = trackAdmin();
  await trackSetup(ok.admin, "setup_finish", { businessId: A }, async () => ({ businessId: A, completed: true, invitationStatus: "sent" }));
  assertEquals(ok.log, ["zella_track_provisioning:finish:pending", "zella_track_provisioning:owner_invitation:done", "zella_track_provisioning:finish:done"]);
  const bad = trackAdmin();
  await trackSetup(bad.admin, "setup_finish", { businessId: A }, async () => ({ businessId: A, completed: false, invitationStatus: "failed", invitationError: "mail provider refused" }));
  assertEquals(bad.log, ["zella_track_provisioning:finish:pending", "zella_track_provisioning:owner_invitation:failed:mail provider refused", "zella_track_provisioning:finish:failed:The owner invitation email failed"]);
  const closed = trackAdmin();
  await trackSetup(closed.admin, "setup_finish", { businessId: A }, async () => ({ businessId: A, completed: false, invitationStatus: "closed" }));
  assertEquals(closed.log, ["zella_track_provisioning:finish:pending", "delete pending"]);
});

Deno.test("trackSetup: a recording failure never changes the save's answer", async () => {
  const admin = { rpc: async () => { throw new Error("rpc down"); }, from: () => { throw new Error("table down"); } } as unknown as SupabaseClient;
  assertEquals(await trackSetup(admin, "setup_save_modules", { businessId: A }, async () => ({ businessId: A })), { businessId: A });
});

Deno.test("trackSetup: a refusal answered with 503 (setup can't finish yet) is not a failed step either", async () => {
  const { admin, log } = trackAdmin();
  await assertRejects(() => trackSetup(admin, "setup_finish", { businessId: A }, async () => { throw new InputError("The plan could not be checked", 503); }), InputError);
  assertEquals(log, ["zella_track_provisioning:finish:pending", "delete pending"]);
});

Deno.test("retry_step: only internal steps, with the admin as actor; database answers in words", async () => {
  const calls: Call[] = [];
  const ok = rpcAdmin(() => ({ data: { status: "done", added: 2, note: null }, error: null }), calls);
  assertEquals(await lifecycleHandlers(ok, { businessId: A, step: "modules" }, kit, "actor", "support_admin").handlers.retry_step(),
    { businessId: A, step: "modules", status: "done", added: 2, note: null });
  assertEquals(calls[0], { fn: "zella_retry_provisioning", args: { p_business: A, p_step: "modules", p_actor: "actor" } });
  for (const [step, words] of [["owner_invitation", "Send owner invite"], ["finish", "Continue setup"], ["integrations", "Continue setup"]]) {
    const c: Call[] = [];
    await assertRejects(() => lifecycleHandlers(rpcAdmin(() => ({ data: null, error: null }), c), { businessId: A, step }, kit, "actor").handlers.retry_step(), InputError, words);
    assertEquals(c.length, 0);
  }
  for (const [message, code, status] of [["NOT_FOUND", "P0001", 404], ["CANCELLED", "P0001", 409], ["missing", "PGRST202", 503]] as const) {
    const err = await assertRejects(() => lifecycleHandlers(rpcAdmin(() => ({ data: null, error: { message, code } }), []), { businessId: A, step: "receptionist" }, kit, "actor").handlers.retry_step(), InputError);
    assertEquals((err as InputError).status, status);
  }
  await assertRejects(() => lifecycleHandlers(ok, { businessId: "x", step: "modules" }, kit).handlers.retry_step(), InputError, "valid business");
});

// SET-DL-EXPORT: the request and approve actions
Deno.test("export_request and export_decide: who may, and the database's answers in words", async () => {
  const calls: Call[] = [];
  const ok = rpcAdmin((c) => ({ data: c.fn === "zella_export_request" ? "job-1" : "approved", error: null }), calls);
  assertEquals(await lifecycleHandlers(ok, { businessId: A, reason: "Owner asked for a copy" }, kit, "admin-1", "support_admin").handlers.export_request(), { id: "job-1", businessId: A, status: "requested" });
  assertEquals(calls[0], { fn: "zella_export_request", args: { p_business: A, p_actor: "admin-1", p_reason: "Owner asked for a copy" } });
  await assertRejects(() => lifecycleHandlers(ok, { businessId: A, reason: "x" }, kit, "admin-1").handlers.export_request(), InputError, "reason");
  for (const role of ["super_admin", "support_admin", null]) {
    const c: Call[] = [];
    const err = await assertRejects(() => lifecycleHandlers(rpcAdmin(() => ({ data: "approved", error: null }), c), { id: B, approve: true }, kit, "u", role).handlers.export_decide(), InputError);
    assertEquals([(err as InputError).status, c.length], [403, 0]);
  }
  assertEquals(await lifecycleHandlers(ok, { id: B, approve: true }, kit, "owner-2", "zella_owner").handlers.export_decide(), { id: B, status: "approved" });
  await assertRejects(() => lifecycleHandlers(ok, { id: B, approve: "yes" }, kit, "owner-2", "zella_owner").handlers.export_decide(), InputError, "approve or reject");
  for (const [message, status] of [["OWN_REQUEST", 403], ["EXPORT_OPEN", 409], ["NOT_REQUESTED", 409], ["REASON_REQUIRED", 400]] as const) {
    const bad = rpcAdmin(() => ({ data: null, error: { message } }), []);
    const fn = message === "EXPORT_OPEN" ? lifecycleHandlers(bad, { businessId: A, reason: "a reason" }, kit, "u", "zella_owner").handlers.export_request
      : lifecycleHandlers(bad, { id: B, approve: false, reason: "r" }, kit, "u", "zella_owner").handlers.export_decide;
    assertEquals(((await assertRejects(fn, InputError)) as InputError).status, status);
  }
});

Deno.test("export_download: only the requester or an owner, only while ready, links that end with the export", async () => {
  const future = new Date(Date.now() + 3 * 86_400_000).toISOString();
  const job = { id: A, business_id: B, status: "ready", requested_by: "admin-1", progress: { parts: [`${A}/tables/calls.json`, "other/x.json"] }, manifest_path: `${A}/manifest.json`, expires_at: future };
  const signedWith: unknown[] = [];
  const mk = (j: Record<string, unknown>) => ({
    from: () => { const c: Record<string, unknown> = {}; for (const m of ["select", "eq"]) c[m] = () => c; c.maybeSingle = async () => ({ data: j, error: null }); return c; },
    storage: { from: (bucket: string) => ({ createSignedUrls: async (paths: string[], secs: number) => { signedWith.push([bucket, paths, secs]); return { data: paths.map((p) => ({ path: p, signedUrl: `https://signed/${p}` })), error: null }; } }) },
  }) as unknown as SupabaseClient;
  const r = await lifecycleHandlers(mk(job), { id: A }, kit, "admin-1", "support_admin").handlers.export_download() as Record<string, unknown>;
  assertEquals((r.links as unknown[]).length, 2);
  const [bucket, paths, secs] = signedWith[0] as [string, string[], number];
  assertEquals([bucket, paths], ["business-exports", [`${A}/manifest.json`, `${A}/tables/calls.json`]]);
  assertEquals(secs > 3 * 86_400 - 60 && secs <= 3 * 86_400, true);
  assertEquals(await lifecycleHandlers(mk(job), { id: A }, kit, "owner-9", "zella_owner").handlers.export_download().then(() => "ok"), "ok");
  assertEquals(((await assertRejects(() => lifecycleHandlers(mk(job), { id: A }, kit, "someone", "super_admin").handlers.export_download(), InputError)) as InputError).status, 403);
  assertEquals(((await assertRejects(() => lifecycleHandlers(mk({ ...job, status: "running" }), { id: A }, kit, "admin-1").handlers.export_download(), InputError)) as InputError).status, 409);
  assertEquals(((await assertRejects(() => lifecycleHandlers(mk({ ...job, expires_at: new Date(Date.now() - 1000).toISOString() }), { id: A }, kit, "admin-1").handlers.export_download(), InputError)) as InputError).status, 409);
  const h = lifecycleHandlers(mk(job), {}, kit);
  assertEquals(h.audited.export_download(r).action, "export.downloaded");
});

Deno.test("draftAges with everyDraft also checks drafts the page doesn't show, and alerts an old abandoned one", async () => {
  const shown = [{ id: B, name: "New Draft", created_at: daysAgo(2), updated_at: daysAgo(1) }];
  const { admin, alerts } = agesAdmin({ drafts: [shown[0], { id: C, name: "Old Hidden Draft", created_at: daysAgo(90), updated_at: daysAgo(80) }] });
  const { ages } = await draftAges(admin, shown, NOW, { everyDraft: true });
  assertEquals([ages.get(B)?.abandoned, ages.get(C)?.abandoned], [false, true]);
  assertEquals(alerts.map((a) => a.p_business_id), [C]);
  const plain = agesAdmin({ drafts: [{ id: C, name: "Old Hidden Draft", created_at: daysAgo(90), updated_at: daysAgo(80) }] });
  assertEquals((await draftAges(plain.admin, shown, NOW)).ages.has(C), false, "without everyDraft only the rows given");
});

Deno.test("documents_missing reads every business, 1000 at a time, so the oldest is never left out", async () => {
  const many = Array.from({ length: 1001 }, (_, i) => ({ id: `b${String(i).padStart(5, "0")}`, name: `Business ${i}`, onboarding_status: "owner_setup", is_active: false, created_at: daysAgo(i) }));
  const pages: number[] = [];
  const admin = {
    from: (table: string) => {
      const chain: Record<string, unknown> = {};
      for (const m of ["select", "eq", "neq", "in", "is", "order", "limit", "not"]) chain[m] = () => chain;
      chain.range = async (from: number, to: number) => {
        if (table === "businesses") pages.push(from);
        return { data: table === "businesses" ? many.slice(from, to + 1) : [], error: null };
      };
      chain.then = (resolve: (v: unknown) => void) => resolve({ data: [], error: null });
      return chain;
    },
    rpc: async () => ({ data: null, error: null }),
  } as unknown as SupabaseClient;
  const r = await lifecycleHandlers(admin, {}, kit).handlers.documents_missing() as { rows: { id: string }[] };
  assertEquals(pages, [0, 1000]);
  assertEquals(r.rows.length, 1001);
  assertEquals(r.rows.at(-1)!.id, "b01000");
});
