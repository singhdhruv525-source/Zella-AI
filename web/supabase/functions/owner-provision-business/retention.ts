// Admin dashboard: the recording policy per business (sql/zella_recording_policy.sql), and retention periods, legal
// holds and the dry run of what a purge would remove (sql/zella_data_retention.sql).
//
// Every action runs after index.ts has checked the caller's sign in, two step sign in, platform role and the
// permission listed in RETENTION_PERMISSIONS. The database functions check the admin again and audit every change in
// the same transaction, so nothing is added to the audit here.
//
// Recording is off for every business until a Zella Voice owner records legal approval with the caller disclosure line
// (both empty today, pending legal review, D-27). Nothing here changes the live call path: voice-rules and the
// assistant config don't read the policy yet; connecting them is a separate change that needs its own approval.
//
// Retention periods start at the architecture's values, "pending legal review". The dry run lists what is past its
// period and deletes nothing. No job is scheduled.
//
// A purge run (sql/zella_retention_purge.sql) needs a legally approved period, two different people (one a Zella Voice
// owner), retention_purge_enabled switched on by an owner, and the typed confirmation "PURGE <rows>". The database
// checks every one of these. For verification documents the database hands back the file paths and this server
// removes them from storage, then records exactly which ones went. If that stops part way (storage refused, or the
// record failed after the files went), an approver retries, one attempt at a time: the database checks the switch and
// the legal approval again and hands back only the files still listed and still due (never those of a business placed
// on hold), and a file storage no longer has counts as removed.
//
// A whole cancelled business (sql/zella_business_purge.sql, BIZ-13d) is purged the same way, approved by the same two
// people, once its final export offer is recorded and 14 days old, with its name typed. It is refused while its audit
// history would be lost (lane B's ACC-10 not applied), while it has billing records, offer history or phone numbers.

import type { SupabaseClient } from "@supabase/supabase-js";
import type { PlatformKit } from "./platform.ts";
import { DOCUMENT_BUCKET } from "./onboarding.ts";

type Json = Record<string, unknown>;

export const RETENTION_PERMISSIONS: Record<string, string> = {
  recording_policy_get: "businesses.view",
  recording_policy_set: "businesses.manage",
  recording_legal_set: "platform.configure",
  retention_overview: "security.view",
  retention_preview: "security.view",
  retention_policy_set: "platform.configure",
  retention_switch_set: "platform.configure",
  legal_hold_place: "security.manage",
  legal_hold_release: "security.manage",
  retention_runs: "security.view",
  retention_run_request: "security.manage",
  retention_run_approve: "security.manage",
  retention_run_execute: "security.manage",
  retention_run_cancel: "security.manage",
  retention_run_files_retry: "security.manage",
  business_purge_request: "security.manage",
  business_purge_execute: "security.manage",
  business_purge_files_retry: "security.manage",
};

// The buckets a business purge may remove files from; anything else in a path list is ignored.
export const PURGE_BUCKETS = ["business-documents", "record-files", "brand-assets"];

// What the admin types to confirm. The server checks it too.
export const RECORDING_ON_WORD = "RECORD";
export const LEGAL_APPROVED_WORD = "APPROVED";
export const PURGE_SWITCH_WORD = "ENABLE PURGES";
export const DATA_CLASSES = ["call_recordings", "call_transcripts", "message_bodies", "audit_logs", "documents_replaced",
  "documents_owner_id_verified", "documents_cancelled_business", "cancelled_business"];

export const REFUSALS: Record<string, [string, number]> = {
  NOT_ALLOWED: ["Your admin role doesn't allow this.", 403],
  OWNER_REQUIRED: ["Only a Zella Voice owner can do this.", 403],
  REASON_REQUIRED: ["Give a short reason (it goes in the audit log).", 400],
  DECISION_REQUIRED: ["Choose on or off.", 400],
  BUSINESS_NOT_FOUND: ["That business wasn't found.", 404],
  RECORDING_NOT_APPROVED: ["Recording stays off until a Zella Voice owner records the legal review and the caller disclosure line.", 409],
  DISCLOSURE_REQUIRED: ["Enter the caller disclosure line legal approved before switching approval on.", 400],
  RECORDING_SETTING_OWNER_ONLY: ["Only a Zella Voice owner changes this, from the recording policy.", 403],
  RETENTION_SWITCH_OWNER_ONLY: ["Only a Zella Voice owner changes this, from Data retention.", 403],
  UNKNOWN_CLASS: ["Choose a kind of data.", 400],
  INVALID_DAYS: ["Enter a whole number of days from 1 to 36500.", 400],
  INVALID_STATUS: ["Choose pending legal review or approved.", 400],
  ALREADY_ON_HOLD: ["This business is already on a legal hold.", 409],
  NOT_FOUND: ["Not found.", 404],
  LEGAL_REVIEW_PENDING: ["This kind of data is still pending legal review, so it can't be purged.", 409],
  BUSINESS_PURGE_SEPARATE: ["Whole businesses are purged from Data lifecycle, not here.", 400],
  RUN_OPEN: ["There is already an open purge run for this kind of data.", 409],
  NOTHING_TO_PURGE: ["Nothing is past its period.", 409],
  NOT_PENDING: ["This run has already been decided.", 409],
  ALREADY_APPROVED: ["You've already approved this run. A second person has to approve it.", 409],
  APPROVER_REQUIRED: ["Only one of the two people who approved this run can run it.", 403],
  PURGE_SWITCHED_OFF: ["Purges are switched off. A Zella Voice owner switches them on in Data retention.", 409],
  NOT_APPROVED: ["This run isn't approved by two people yet, or has already run.", 409],
  CONFIRM_MISMATCH: ["What you typed doesn't match. Type exactly what the dialog asks for (PURGE and the number of rows, or the business's name).", 400],
  NOT_RUNNING: ["This run isn't waiting for files.", 409],
  REMOVAL_IN_PROGRESS: ["The files are being removed right now. Try again in 10 minutes if it doesn't finish.", 409],
  PURGE_IN_PROGRESS: ["A purge run is removing this business's files. Place the hold once it has finished.", 409],
  NUMBER_RELEASE_OPEN: ["This number has an open release order, so it can't be given to a business.", 409],
  EXPORT_OFFER_REQUIRED: ["Record when and how the owner was offered a final export of their data.", 400],
  NOT_PAST_RETENTION: ["This business isn't past its retention date, isn't cancelled, or is on a legal hold.", 409],
  EXPORT_OFFER_TOO_RECENT: ["The final export offer was made less than 14 days ago.", 409],
  AUDIT_HISTORY_AT_RISK: ["Deleting a business would still erase its audit history. The audit history fix (ACC-10) must be applied first.", 409],
  BILLING_RECORDS_KEPT: ["This business has payment or billing records. How long those are kept after deletion hasn't been decided, so it can't be purged yet.", 409],
  OFFER_HISTORY_KEPT: ["This business has offer history, which is kept.", 409],
  NUMBERS_STILL_ASSIGNED: ["Release this business's phone numbers on Voice & numbers first.", 409],
};

// A database call; known refusals become messages with their status, anything else stays an error (500).
export function rpcWith(admin: SupabaseClient, kit: PlatformKit, refusals: Record<string, [string, number]> = REFUSALS) {
  return async (fn: string, args: Json) => {
    const { data, error } = await admin.rpc(fn, args);
    if (error) {
      const code = Object.keys(refusals).find((c) => String(error.message ?? "").includes(c));
      if (code) throw new kit.InputError(refusals[code][0], refusals[code][1]);
      throw error;
    }
    return data as Json;
  };
}

export function retentionHandlers(admin: SupabaseClient, fields: Json, kit: PlatformKit, userId: string, role: string | null) {
  const { text, InputError } = kit;
  const rpc = rpcWith(admin, kit);

  const recording_policy_get = () => rpc("zella_recording_policies", { p_actor: userId });

  const recording_policy_set = async () => {
    const businessId = kit.requireId(fields.businessId);
    if (typeof fields.on !== "boolean") throw new InputError(REFUSALS.DECISION_REQUIRED[0]);
    if (fields.on && text(fields.confirm, 20) !== RECORDING_ON_WORD) throw new InputError(`Type ${RECORDING_ON_WORD} to confirm.`);
    return await rpc("zella_recording_policy_set", { p_actor: userId, p_business: businessId, p_on: fields.on, p_reason: text(fields.reason, 300) });
  };

  const recording_legal_set = async () => {
    if (role !== "zella_owner") throw new InputError(REFUSALS.OWNER_REQUIRED[0], 403);
    if (typeof fields.approved !== "boolean") throw new InputError("Choose approved or not approved.");
    if (fields.approved && text(fields.confirm, 20) !== LEGAL_APPROVED_WORD) throw new InputError(`Type ${LEGAL_APPROVED_WORD} to confirm.`);
    return await rpc("zella_recording_legal_set", { p_actor: userId, p_approved: fields.approved, p_disclosure: text(fields.disclosure, 500), p_reason: text(fields.reason, 300) });
  };

  const dataClass = () => {
    const c = text(fields.dataClass, 40);
    if (!DATA_CLASSES.includes(c)) throw new InputError(REFUSALS.UNKNOWN_CLASS[0]);
    return c;
  };
  const ownerOnly = () => { if (role !== "zella_owner") throw new InputError(REFUSALS.OWNER_REQUIRED[0], 403); };

  const retention_overview = async () => ({ ...(await rpc("zella_retention_overview", { p_actor: userId })), you: userId });
  // The dry run: deletes nothing.
  const retention_preview = async () => await rpc("zella_retention_preview", { p_actor: userId, p_class: dataClass(), p_limit: 25 });

  const retention_policy_set = async () => {
    ownerOnly();
    const c = dataClass();
    const days = Number(fields.days);
    if (!Number.isInteger(days) || days < 1 || days > 36500) throw new InputError(REFUSALS.INVALID_DAYS[0]);
    const status = text(fields.legalStatus, 30);
    if (status === "approved" && text(fields.confirm, 20) !== LEGAL_APPROVED_WORD) throw new InputError(`Type ${LEGAL_APPROVED_WORD} to confirm.`);
    return await rpc("zella_retention_policy_set", { p_actor: userId, p_class: c, p_days: days, p_status: status, p_reason: text(fields.reason, 300) });
  };

  const retention_switch_set = async () => {
    ownerOnly();
    if (typeof fields.on !== "boolean") throw new InputError(REFUSALS.DECISION_REQUIRED[0]);
    if (fields.on && text(fields.confirm, 30) !== PURGE_SWITCH_WORD) throw new InputError(`Type ${PURGE_SWITCH_WORD} to confirm.`);
    return await rpc("zella_retention_switch_set", { p_actor: userId, p_on: fields.on, p_reason: text(fields.reason, 300) });
  };

  const legal_hold_place = async () => await rpc("zella_legal_hold_place", { p_actor: userId, p_business: kit.requireId(fields.businessId), p_reason: text(fields.reason, 300) });
  const legal_hold_release = async () => {
    ownerOnly();
    return await rpc("zella_legal_hold_release", { p_actor: userId, p_hold: kit.requireId(fields.id, "hold"), p_reason: text(fields.reason, 300) });
  };

  const runId = () => kit.requireId(fields.id, "run");
  const retention_runs = () => rpc("zella_retention_runs", { p_actor: userId, p_limit: 50 });
  const retention_run_request = async () => await rpc("zella_retention_run_request", { p_actor: userId, p_class: dataClass(), p_reason: text(fields.reason, 300) });
  const retention_run_approve = async () => await rpc("zella_retention_run_approve", { p_actor: userId, p_run: runId(), p_reason: text(fields.reason, 300) });
  const retention_run_cancel = async () => await rpc("zella_retention_run_cancel", { p_actor: userId, p_run: runId(), p_reason: text(fields.reason, 300) });

  // Removes the files from storage in batches of 100. A file storage doesn't have (removed by an earlier attempt) counts
  // as removed when storage reported no error; a refusal stops the removal and is recorded on the run.
  const removeFiles = async (paths: string[], split: (p: string) => [string, string] | null) => {
    const removed: string[] = [];
    let problem: string | null = null;
    const byBucket = new Map<string, string[]>();
    for (const p of paths) {
      const parts = split(p);
      if (parts) byBucket.set(parts[0], [...(byBucket.get(parts[0]) ?? []), p]);
    }
    for (const [bucket, full] of byBucket) {
      for (let i = 0; i < full.length && !problem; i += 100) {
        const batch = full.slice(i, i + 100);
        const { error } = await admin.storage.from(bucket).remove(batch.map((p) => split(p)![1]));
        if (error) { problem = `Storage refused to remove some files (${String(error.message ?? "no details").slice(0, 200)})`; break; }
        removed.push(...batch);
      }
    }
    if (!problem && removed.length < paths.length) problem = `${paths.length - removed.length} files are in no bucket a purge may use`;
    return { removed, problem };
  };
  const documentPath = (p: string): [string, string] => [DOCUMENT_BUCKET, p];
  const bucketPath = (p: string): [string, string] | null => {
    const bucket = PURGE_BUCKETS.find((b) => p.startsWith(`${b}/`));
    return bucket ? [bucket, p.slice(bucket.length + 1)] : null;
  };
  const stringList = (v: unknown) => (Array.isArray(v) ? v : []).filter((p): p is string => typeof p === "string");

  const retention_run_execute = async () => {
    const id = runId();
    const confirm = text(fields.confirm, 20);
    if (!/^PURGE \d{1,4}$/.test(confirm)) throw new InputError(REFUSALS.CONFIRM_MISMATCH[0]);
    const run = await rpc("zella_retention_run_execute", { p_actor: userId, p_run: id, p_confirm: confirm });
    if (run.status !== "files_pending") return run;
    const { removed, problem } = await removeFiles(stringList(run.file_paths), documentPath);
    return await rpc("zella_retention_run_files_done", { p_actor: userId, p_run: id, p_removed: removed, p_error: problem });
  };

  // Finishes a run whose file removal stopped (files_pending or failed): never runs the purge again.
  const filesRetry = async (split: (p: string) => [string, string] | null, resume: string, done: string) => {
    const id = runId();
    const left = stringList(await rpc(resume, { p_actor: userId, p_run: id }));
    const { removed, problem } = await removeFiles(left, split);
    return await rpc(done, { p_actor: userId, p_run: id, p_removed: removed, p_error: problem });
  };
  const retention_run_files_retry = () => filesRetry(documentPath, "zella_retention_run_files_resume", "zella_retention_run_files_done");
  const business_purge_files_retry = () => filesRetry(bucketPath, "zella_business_purge_files_resume", "zella_business_purge_files_done");

  const business_purge_request = async () => {
    const offered = new Date(text(fields.exportOfferedAt, 40));
    if (Number.isNaN(offered.getTime())) throw new InputError(REFUSALS.EXPORT_OFFER_REQUIRED[0]);
    return await rpc("zella_business_purge_request", { p_actor: userId, p_business: kit.requireId(fields.businessId), p_offered_at: offered.toISOString(),
      p_offer_note: text(fields.exportOfferNote, 300), p_reason: text(fields.reason, 300) });
  };

  const business_purge_execute = async () => {
    const id = runId();
    const name = typeof fields.confirmName === "string" ? fields.confirmName : "";
    if (!name) throw new InputError("Type the business's name exactly to confirm.");
    const run = await rpc("zella_business_purge_execute", { p_actor: userId, p_run: id, p_confirm_name: name });
    if (run.status !== "files_pending") return run;
    const { removed, problem } = await removeFiles(stringList(run.file_paths), bucketPath);
    return await rpc("zella_business_purge_files_done", { p_actor: userId, p_run: id, p_removed: removed, p_error: problem });
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    business_purge_request, business_purge_execute, business_purge_files_retry,
    retention_runs, retention_run_request, retention_run_approve, retention_run_execute, retention_run_cancel, retention_run_files_retry,
    recording_policy_get, recording_policy_set, recording_legal_set,
    retention_overview, retention_preview, retention_policy_set, retention_switch_set, legal_hold_place, legal_hold_release,
  };
  const audited: Record<string, (r: Json) => Json> = {};
  return { handlers, audited };
}
