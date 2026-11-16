// retention.ts with a stand in for the database: every guard refuses before the database is asked, and the
// database's own refusals keep their meaning and status. The SQL rules themselves are tested on the isolated
// database (tests/recording_policy, tests/data_retention, tests/business_purge).
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { PlatformKit } from "./platform.ts";
import { LEGAL_APPROVED_WORD, PURGE_SWITCH_WORD, RECORDING_ON_WORD, RETENTION_PERMISSIONS, retentionHandlers } from "./retention.ts";

class InputError extends Error { constructor(message: string, public status = 400) { super(message); } }
export const kit: PlatformKit = {
  text: (v, max = 300) => typeof v === "string" ? v.trim().slice(0, max) : "",
  bool: (v, fallback = false) => typeof v === "boolean" ? v : fallback,
  obj: (v) => v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {},
  requireId: (v) => { if (typeof v !== "string" || !/^[0-9a-f-]{36}$/.test(v)) throw new InputError("Missing id"); return v; }, InputError,
};
type Json = Record<string, unknown>;
export const BIZ = "b3000000-0000-0000-0000-000000000001";

// The database: records each call, answers with `answer` or refuses with an error message.
export function db(answer: (fn: string, args: Json) => { data?: unknown; error?: string } = () => ({ data: { ok: true } }),
  storage: (bucket: string, paths: string[]) => { data: { name: string }[] | null; error: { message: string } | null } = (_b, paths) => ({ data: paths.map((name) => ({ name })), error: null })) {
  const calls: [string, Json][] = [];
  const removed: [string, string[]][] = [];
  const admin = {
    storage: { from: (bucket: string) => ({ remove: (paths: string[]) => { removed.push([bucket, paths]); return Promise.resolve(storage(bucket, paths)); } }) },
    rpc: (fn: string, args: Json) => { calls.push([fn, args]); const a = answer(fn, args); return Promise.resolve({ data: a.data ?? null, error: a.error ? { message: a.error } : null }); },
    from: () => { throw new Error("retention.ts must not read tables directly"); },
  } as unknown as SupabaseClient;
  return { admin, calls, removed };
}
export const run = (d: ReturnType<typeof db>, action: string, fields: Json, role = "zella_owner") =>
  retentionHandlers(d.admin, fields, kit, "admin-user", role).handlers[action]();

Deno.test("recording actions each need the permission index.ts checks", () => {
  assertEquals([RETENTION_PERMISSIONS.recording_policy_get, RETENTION_PERMISSIONS.recording_policy_set, RETENTION_PERMISSIONS.recording_legal_set],
    ["businesses.view", "businesses.manage", "platform.configure"]);
});

Deno.test("switching a business's recording on needs the typed word; off doesn't", async () => {
  const d = db();
  await assertRejects(() => run(d, "recording_policy_set", { businessId: BIZ, on: true, reason: "Asked by owner" }), InputError, `Type ${RECORDING_ON_WORD}`);
  await assertRejects(() => run(d, "recording_policy_set", { businessId: BIZ, on: "true", reason: "Asked by owner", confirm: RECORDING_ON_WORD }), InputError);
  await assertRejects(() => run(d, "recording_policy_set", { businessId: "not-an-id", on: false, reason: "x" }), InputError);
  assertEquals(d.calls, []);
  await run(d, "recording_policy_set", { businessId: BIZ, on: false, reason: "Confirm off" });
  assertEquals(d.calls, [["zella_recording_policy_set", { p_actor: "admin-user", p_business: BIZ, p_on: false, p_reason: "Confirm off" }]]);
});

Deno.test("before legal review the database refuses recording on, and the refusal reaches the admin as 409", async () => {
  const d = db(() => ({ error: "RECORDING_NOT_APPROVED: recording stays off" }));
  const err = await assertRejects(() => run(d, "recording_policy_set", { businessId: BIZ, on: true, reason: "Asked by owner", confirm: RECORDING_ON_WORD }), InputError);
  assertEquals((err as InputError).status, 409);
});

Deno.test("only a Zella Voice owner records legal approval, with the typed word, before the database is asked", async () => {
  for (const role of ["super_admin", "platform_operations", "security_admin", "read_only_admin", ""]) {
    const d = db();
    const err = await assertRejects(() => run(d, "recording_legal_set", { approved: true, disclosure: "This call may be recorded.", reason: "Counsel", confirm: LEGAL_APPROVED_WORD }, role), InputError);
    assertEquals((err as InputError).status, 403); assertEquals(d.calls, []);
  }
  const d = db();
  await assertRejects(() => run(d, "recording_legal_set", { approved: true, disclosure: "This call may be recorded.", reason: "Counsel" }), InputError, `Type ${LEGAL_APPROVED_WORD}`);
  await assertRejects(() => run(d, "recording_legal_set", { approved: "yes", reason: "Counsel" }), InputError);
  assertEquals(d.calls, []);
  await run(d, "recording_legal_set", { approved: false, reason: "Withdrawn" });
  assertEquals(d.calls[0], ["zella_recording_legal_set", { p_actor: "admin-user", p_approved: false, p_disclosure: "", p_reason: "Withdrawn" }]);
});

Deno.test("database refusals keep their status; anything unknown stays a server error", async () => {
  for (const [code, status] of [["NOT_ALLOWED", 403], ["OWNER_REQUIRED", 403], ["BUSINESS_NOT_FOUND", 404], ["DISCLOSURE_REQUIRED", 400], ["REASON_REQUIRED", 400]] as const) {
    const err = await assertRejects(() => run(db(() => ({ error: code })), "recording_policy_set", { businessId: BIZ, on: false, reason: "x" }), InputError);
    assertEquals((err as InputError).status, status);
  }
  const err = await assertRejects(() => run(db(() => ({ error: "connection reset" })), "recording_policy_get", {}));
  assertEquals(err instanceof InputError, false);
});

Deno.test("retention: the dry run and overview only read; an unknown kind of data is refused before the database", async () => {
  const d = db();
  await assertRejects(() => run(d, "retention_preview", { dataClass: "everything" }), InputError);
  assertEquals(d.calls, []);
  await run(d, "retention_preview", { dataClass: "call_recordings" }, "read_only_admin");
  await run(d, "retention_overview", {}, "read_only_admin");
  assertEquals(d.calls.map(([f]) => f), ["zella_retention_preview", "zella_retention_overview"]);
  assertEquals(d.calls[0][1], { p_actor: "admin-user", p_class: "call_recordings", p_limit: 25 });
});

Deno.test("retention: only a Zella Voice owner changes a period, the purge switch or releases a hold, before the database is asked", async () => {
  for (const role of ["super_admin", "security_admin", "platform_operations", "read_only_admin", ""]) {
    const d = db();
    for (const [action, fields] of [["retention_policy_set", { dataClass: "audit_logs", days: 2555, legalStatus: "pending_legal_review", reason: "x" }],
      ["retention_switch_set", { on: true, reason: "Ready", confirm: PURGE_SWITCH_WORD }], ["legal_hold_release", { id: BIZ, reason: "Done" }]] as [string, Json][]) {
      const err = await assertRejects(() => run(d, action, fields, role), InputError);
      assertEquals((err as InputError).status, 403);
    }
    assertEquals(d.calls, []);
  }
});

Deno.test("retention: approving a period or switching purges on needs the typed words; bad days are refused", async () => {
  const d = db();
  await assertRejects(() => run(d, "retention_policy_set", { dataClass: "audit_logs", days: 2555, legalStatus: "approved", reason: "Counsel" }), InputError, `Type ${LEGAL_APPROVED_WORD}`);
  await assertRejects(() => run(d, "retention_policy_set", { dataClass: "audit_logs", days: 0, legalStatus: "pending_legal_review", reason: "x" }), InputError);
  await assertRejects(() => run(d, "retention_policy_set", { dataClass: "audit_logs", days: 1.5, legalStatus: "pending_legal_review", reason: "x" }), InputError);
  await assertRejects(() => run(d, "retention_switch_set", { on: true, reason: "Ready" }), InputError, `Type ${PURGE_SWITCH_WORD}`);
  await assertRejects(() => run(d, "retention_switch_set", { on: "yes", reason: "Ready" }), InputError);
  assertEquals(d.calls, []);
  await run(d, "retention_switch_set", { on: false, reason: "Off again" });
  await run(d, "legal_hold_place", { businessId: BIZ, reason: "Counsel asked" }, "security_admin");
  assertEquals(d.calls.map(([f]) => f), ["zella_retention_switch_set", "zella_legal_hold_place"]);
});

Deno.test("retention: the switch guard and hold refusals keep their status", async () => {
  for (const [code, status] of [["RETENTION_SWITCH_OWNER_ONLY", 403], ["ALREADY_ON_HOLD", 409], ["UNKNOWN_CLASS", 400], ["NOT_FOUND", 404]] as const) {
    const err = await assertRejects(() => run(db(() => ({ error: code })), "legal_hold_place", { businessId: BIZ, reason: "Counsel" }, "security_admin"), InputError);
    assertEquals((err as InputError).status, status);
  }
});

Deno.test("purge runs: the typed confirmation is checked before the database, and a run that isn't documents never touches storage", async () => {
  const RUN = "c3000000-0000-0000-0000-000000000001";
  for (const confirm of ["", "purge 2", "PURGE", "PURGE two", "DELETE 2"]) {
    const d = db();
    await assertRejects(() => run(d, "retention_run_execute", { id: RUN, confirm }, "security_admin"), InputError, "Type PURGE");
    assertEquals(d.calls, []);
  }
  const d = db(() => ({ data: { id: RUN, status: "done", removed_count: 3 } }));
  assertEquals(await run(d, "retention_run_execute", { id: RUN, confirm: "PURGE 3" }, "security_admin"), { id: RUN, status: "done", removed_count: 3 });
  assertEquals(d.calls, [["zella_retention_run_execute", { p_actor: "admin-user", p_run: RUN, p_confirm: "PURGE 3" }]]);
  assertEquals(d.removed, []);
});

Deno.test("purge runs: document files are removed from the documents bucket and exactly the removed ones are recorded", async () => {
  const RUN = "c3000000-0000-0000-0000-000000000002";
  const answer = (fn: string) => ({ data: fn === "zella_retention_run_execute" ? { id: RUN, status: "files_pending", file_paths: ["b/a.pdf", "b/b.pdf", "b/c.pdf"] } : { id: RUN, status: "done" } });
  const all = db(answer);
  await run(all, "retention_run_execute", { id: RUN, confirm: "PURGE 3" }, "zella_owner");
  assertEquals(all.removed, [["business-documents", ["b/a.pdf", "b/b.pdf", "b/c.pdf"]]]);
  assertEquals(all.calls[1], ["zella_retention_run_files_done", { p_actor: "admin-user", p_run: RUN, p_removed: ["b/a.pdf", "b/b.pdf", "b/c.pdf"], p_error: null }]);
  const some = db(answer, (_b, paths) => ({ data: paths.filter((p) => p !== "b/b.pdf").map((name) => ({ name })), error: null }));
  await run(some, "retention_run_execute", { id: RUN, confirm: "PURGE 3" }, "zella_owner");
  assertEquals(some.calls[1][1].p_removed, ["b/a.pdf", "b/c.pdf"]);
  assertEquals(some.calls[1][1].p_error, "1 files were not found in storage");
  const broken = db(answer, () => ({ data: null, error: { message: "storage unavailable" } }));
  await run(broken, "retention_run_execute", { id: RUN, confirm: "PURGE 3" }, "zella_owner");
  assertEquals(broken.calls[1][1].p_removed, []);
  assertEquals(String(broken.calls[1][1].p_error).startsWith("Storage refused"), true);
});

Deno.test("purge runs: each guard the database checks reaches the admin with its meaning and status", async () => {
  for (const [code, status] of [["PURGE_SWITCHED_OFF", 409], ["APPROVER_REQUIRED", 403], ["NOT_APPROVED", 409], ["LEGAL_REVIEW_PENDING", 409], ["CONFIRM_MISMATCH", 400], ["ALREADY_APPROVED", 409], ["OWNER_REQUIRED", 403], ["NOT_ALLOWED", 403]] as const) {
    const d = db(() => ({ error: `${code}` }));
    const err = await assertRejects(() => run(d, "retention_run_execute", { id: "c3000000-0000-0000-0000-000000000003", confirm: "PURGE 1" }, "zella_owner"), InputError);
    assertEquals((err as InputError).status, status);
    assertEquals(d.removed, []);
  }
  assertEquals([RETENTION_PERMISSIONS.retention_run_execute, RETENTION_PERMISSIONS.retention_run_approve, RETENTION_PERMISSIONS.retention_runs], ["security.manage", "security.manage", "security.view"]);
});
