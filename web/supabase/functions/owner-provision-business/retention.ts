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

import type { SupabaseClient } from "@supabase/supabase-js";
import type { PlatformKit } from "./platform.ts";

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
};

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

  const retention_overview = () => rpc("zella_retention_overview", { p_actor: userId });
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

  const handlers: Record<string, () => Promise<unknown>> = {
    recording_policy_get, recording_policy_set, recording_legal_set,
    retention_overview, retention_preview, retention_policy_set, retention_switch_set, legal_hold_place, legal_hold_release,
  };
  const audited: Record<string, (r: Json) => Json> = {};
  return { handlers, audited };
}
