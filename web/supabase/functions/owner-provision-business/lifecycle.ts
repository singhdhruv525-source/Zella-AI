// Admin dashboard: the business lifecycle (Lane B, docs/ADMIN_AUDIT_2026-11-16.md BIZ-14 and the items after it).
//
// Every action runs after index.ts has checked the caller's sign in, platform role and the permission listed in
// LIFECYCLE_PERMISSIONS. Actions that change something return what changed, and `audited` turns that into the audit
// entry index.ts writes.

import type { SupabaseClient } from "@supabase/supabase-js";
import { DOCUMENT_BUCKET } from "./onboarding.ts";

type Json = Record<string, unknown>;

export type LifecycleKit = {
  text: (v: unknown, max?: number) => string;
  bool: (v: unknown, fallback?: boolean) => boolean;
  obj: (v: unknown) => Json;
  requireId: (v: unknown, label?: string) => string;
  InputError: new (message: string, status?: number) => Error;
};

export const LIFECYCLE_PERMISSIONS: Record<string, string> = {
  setup_check_duplicates: "businesses.manage",
  business_delete_draft: "businesses.manage",   // and the zella_owner or super_admin role (DRAFT_DELETE_ROLES)
};

// BIZ-13a default (owner can change): only these roles may delete a never finished draft.
export const DRAFT_DELETE_ROLES = ["zella_owner", "super_admin"];

// Why a business isn't a draft that can be deleted, from zella_delete_draft_business's NOT_A_DRAFT list.
const NOT_A_DRAFT_WORDS: Record<string, string> = {
  setup_finished: "setup is finished", active: "it is active", cancelled: "it is cancelled or cancelling",
  owner_accepted: "the owner accepted the invitation", members: "it has active team members", calls: "it has calls",
  phone_numbers: "it has phone numbers", subscriptions: "it has a subscription", payments: "it has payments",
  assistant_deliveries: "its receptionist was delivered", offers: "it has offer history",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type RpcResult = { data: { business_id?: string; existing?: boolean } | null; error: { code?: string; message: string } | null };

// BIZ-14: creates the draft with the wizard's creation key, so the same key always gives the same business
// (sql/zella_business_creation_key.sql). Before that migration is applied the two argument function doesn't exist
// (PGRST202), and the draft is made the old way, so either deploy order works.
export async function createDraft(admin: SupabaseClient, values: Json, creationKey: string): Promise<RpcResult> {
  if (creationKey) {
    const keyed = await admin.rpc("zella_create_business_draft", { p_fields: values, p_creation_key: creationKey }) as RpcResult;
    if (keyed.error?.code !== "PGRST202") return keyed;
  }
  return await admin.rpc("zella_create_business_draft", { p_fields: values }) as RpcResult;
}

export function lifecycleHandlers(admin: SupabaseClient, fields: Json, kit: LifecycleKit, userId: string | null = null, role: string | null = null) {
  const { text, obj, InputError } = kit;

  // BIZ-14: businesses that are not cancelled and share the name, phone number or web domain, before a draft is made.
  // The one this wizard session's own first try made (same creation key) is not a duplicate. Read only, so not
  // audited. Before the migration is applied the wizard gets an empty list and creates as before.
  const checkDuplicates = async () => {
    const business = obj(fields.business);
    const name = text(business.name, 200);
    const phone = text(business.phone, 30);
    const website = text(business.website, 300);
    const exclude = text(fields.businessId, 64);
    const creationKey = text(fields.creationKey, 64);
    if (exclude && !UUID_RE.test(exclude)) throw new InputError("A valid business is required");
    if (creationKey && !UUID_RE.test(creationKey)) throw new InputError("The creation key is not valid");
    if (!name && !phone && !website) return { duplicates: [], checked: false };
    const { data, error } = await admin.rpc("zella_business_duplicates", {
      p_name: name, p_phone: phone, p_website: website, p_exclude: exclude || null, p_creation_key: creationKey || null,
    });
    if (error?.code === "PGRST202") return { duplicates: [], checked: false };
    if (error) throw error;
    const duplicates = (Array.isArray(data) ? data : []).map((row) => {
      const r = obj(row);
      return {
        id: text(r.id, 64), name: text(r.name, 200), onboardingStatus: text(r.onboarding_status, 40),
        isActive: r.is_active === true, createdAt: text(r.created_at, 40),
        matched: (Array.isArray(r.matched) ? r.matched : []).filter((m) => m === "name" || m === "phone" || m === "website"),
      };
    });
    return { duplicates, checked: true };
  };

  // BIZ-13a: deletes a never finished draft. The database checks the role again, the typed name and every reason the
  // business is no longer a draft under a row lock, and writes the audit entry itself in the same transaction (with
  // the name, since audit_logs has none). Then the business-documents files go; any left over are orphans, which the
  // orphan cleanup removes later.
  const deleteDraft = async () => {
    if (!role || !DRAFT_DELETE_ROLES.includes(role)) {
      throw new InputError("Only a Zella Voice owner or super admin can delete a draft business.", 403);
    }
    const businessId = kit.requireId(fields.businessId);
    const confirmName = text(fields.confirmName, 200);
    const reason = text(fields.reason, 300);
    if (!confirmName) throw new InputError("Type the business name to confirm.");
    if (reason.length < 3) throw new InputError("Give a short reason (it goes in the audit log).");
    const { data, error } = await admin.rpc("zella_delete_draft_business", {
      p_business_id: businessId, p_actor: userId, p_confirm_name: confirmName, p_reason: reason,
    });
    if (error) {
      const m = error.message ?? "";
      if (m.includes("NOT_A_DRAFT")) {
        const why = (m.split("NOT_A_DRAFT:")[1] ?? "").trim().split(",").map((k) => NOT_A_DRAFT_WORDS[k.trim()]).filter(Boolean);
        throw new InputError(`This business can't be deleted: ${why.join(", ") || "it is no longer a draft"}.`, 409);
      }
      if (m.includes("NAME_MISMATCH")) throw new InputError("The name you typed doesn't match the business.");
      if (m.includes("REASON_REQUIRED")) throw new InputError("Give a short reason (it goes in the audit log).");
      if (m.includes("NOT_FOUND")) throw new InputError("Business not found", 404);
      if (m.includes("NOT_ALLOWED")) throw new InputError("Only a Zella Voice owner or super admin can delete a draft business.", 403);
      throw error;
    }
    const result = obj(data);
    const paths = (Array.isArray(result.paths) ? result.paths : []).map(String).filter((p) => p.startsWith(`${businessId}/`));
    let removed = 0;
    for (let i = 0; i < paths.length; i += 100) {
      const chunk = paths.slice(i, i + 100);
      const { error: removeError } = await admin.storage.from(DOCUMENT_BUCKET).remove(chunk);
      if (removeError) { console.error("Draft delete: some document files were not removed", removeError); break; }
      removed += chunk.length;
    }
    return { businessId, name: text(result.name, 200), deleted: true, filesRemoved: removed, filesLeft: paths.length - removed };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    setup_check_duplicates: checkDuplicates,
    business_delete_draft: deleteDraft,
  };

  // business_delete_draft is audited by zella_delete_draft_business itself, in the same transaction as the delete.
  const audited: Record<string, (r: Json) => Json> = {};

  return { handlers, audited };
}
