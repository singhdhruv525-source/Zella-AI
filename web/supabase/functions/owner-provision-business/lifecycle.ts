// Admin dashboard: the business lifecycle (Lane B, docs/ADMIN_AUDIT_2026-11-16.md BIZ-14 and the items after it).
//
// Every action runs after index.ts has checked the caller's sign in, platform role and the permission listed in
// LIFECYCLE_PERMISSIONS. Actions that change something return what changed, and `audited` turns that into the audit
// entry index.ts writes.

import type { SupabaseClient } from "@supabase/supabase-js";
import { DOCUMENT_BUCKET, REQUIRED_DOCUMENTS, missingDocuments, missingTable } from "./onboarding.ts";
import { renderEmail } from "../_shared/businessEmails.js";

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
  documents_missing: "businesses.manage",       // the same permission as the Verification queue (documents_queue)
  document_request: "businesses.manage",
};

// UI-11 default (owner can change): one documents request per business in this many hours, read from the last
// business.documents_requested audit entry (no new table).
export const DOCUMENT_REQUEST_COOLDOWN_HOURS = 24;

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

// BIZ-13b default (owner can change): a draft with no change for this many days is Abandoned. The platform setting
// draft_abandon_days (editable on Settings, Operational rules) overrides it. Nothing is ever deleted automatically: a
// person uses Delete draft.
export const DRAFT_ABANDON_DAYS_DEFAULT = 30;
const DAY_MS = 86_400_000;

type DraftRow = { id: string; name: unknown; created_at: unknown; updated_at?: unknown };
export type DraftAge = { lastActivityAt: string; abandoned: boolean };

// Last activity is the later of the business row's own change and its newest audit entry (every setup save is
// audited). A draft that has just become Abandoned raises one draft_abandoned alert, once ever per business: a
// resolved alert is not raised again. Alerts are best effort and never fail the page.
export async function draftAges(admin: SupabaseClient, rows: DraftRow[], now = Date.now()): Promise<{ days: number; ages: Map<string, DraftAge> }> {
  const ages = new Map<string, DraftAge>();
  const { data: setting } = await admin.from("platform_settings").select("value").eq("key", "draft_abandon_days").maybeSingle();
  const set = Number((setting as { value?: unknown } | null)?.value);
  const days = Number.isInteger(set) && set >= 7 && set <= 365 ? set : DRAFT_ABANDON_DAYS_DEFAULT;
  if (!rows.length) return { days, ages };
  const ids = rows.map((r) => r.id);
  const { data: audit, error } = await admin.from("audit_logs").select("business_id, created_at").in("business_id", ids)
    .order("created_at", { ascending: false }).limit(5000);
  if (error) throw error;
  const newest = new Map<string, string>();
  for (const a of (audit ?? []) as { business_id: string; created_at: string }[]) if (!newest.has(a.business_id)) newest.set(a.business_id, a.created_at);
  const cutoff = now - days * DAY_MS;
  for (const r of rows) {
    const times = [r.updated_at, r.created_at, newest.get(r.id)].map((t) => Date.parse(String(t ?? ""))).filter((t) => Number.isFinite(t));
    const last = times.length ? Math.max(...times) : now;
    ages.set(r.id, { lastActivityAt: new Date(last).toISOString(), abandoned: last < cutoff });
  }
  const abandoned = rows.filter((r) => ages.get(r.id)?.abandoned);
  if (abandoned.length) {
    try {
      const { data: raised, error: alertError } = await admin.from("platform_alerts").select("business_id")
        .eq("kind", "draft_abandoned").in("business_id", abandoned.map((r) => r.id));
      if (alertError) throw alertError;
      const already = new Set(((raised ?? []) as { business_id: string }[]).map((a) => a.business_id));
      for (const r of abandoned.filter((x) => !already.has(x.id))) {
        await admin.rpc("zella_platform_alert", {
          p_kind: "draft_abandoned", p_title: "A draft business looks abandoned",
          p_detail: `${String(r.name ?? "A business")} has had no changes for ${days} days. Continue its setup or delete the draft.`,
          p_severity: "info", p_business_id: r.id, p_dedupe_key: `draft_abandoned:${r.id}`, p_meta: { days },
        });
      }
    } catch (e) {
      console.error("Abandoned draft alerts could not be raised", e);
    }
  }
  return { days, ages };
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

  // UI-11: businesses (not cancelled) that still miss a required verification document, including ones already live
  // ("Live without documents"), with when documents were last requested.
  const documentsMissing = async () => {
    const { data: docs, error } = await admin.from("business_verification_documents").select("business_id, kind, status").neq("status", "replaced");
    if (error) {
      if (missingTable(error)) return { available: false, rows: [], required: REQUIRED_DOCUMENTS };
      throw error;
    }
    const { data: biz, error: bizError } = await admin.from("businesses").select("id, name, onboarding_status, is_active, created_at")
      .is("cancelled_at", null).order("created_at", { ascending: false }).limit(1000);
    if (bizError) throw bizError;
    const byBiz = new Map<string, { kind: string; status: string }[]>();
    for (const d of (docs ?? []) as { business_id: string; kind: string; status: string }[]) byBiz.set(d.business_id, [...(byBiz.get(d.business_id) ?? []), d]);
    const rows = ((biz ?? []) as { id: string; name: string; onboarding_status: string; is_active: boolean; created_at: string }[])
      .map((b) => ({ ...b, missing: missingDocuments(byBiz.get(b.id) ?? []), live: b.is_active || b.onboarding_status === "active" }))
      .filter((b) => b.missing.length > 0);
    const last = await lastRequests(rows.map((r) => r.id));
    return {
      available: true, required: REQUIRED_DOCUMENTS, cooldownHours: DOCUMENT_REQUEST_COOLDOWN_HOURS,
      rows: rows.map((r) => ({ id: r.id, name: r.name, onboarding_status: r.onboarding_status, live: r.live, missing: r.missing, created_at: r.created_at, last_requested_at: last.get(r.id) ?? null })),
    };
  };

  const lastRequests = async (ids: string[]) => {
    const out = new Map<string, string>();
    if (!ids.length) return out;
    const { data, error } = await admin.from("audit_logs").select("business_id, created_at").eq("action", "business.documents_requested")
      .in("business_id", ids).order("created_at", { ascending: false }).limit(2000);
    if (error) throw error;
    for (const a of (data ?? []) as { business_id: string; created_at: string }[]) if (!out.has(a.business_id)) out.set(a.business_id, a.created_at);
    return out;
  };

  // UI-11: asks the owner for the missing documents. Queues email S4 in the platform outbox when it is installed; it
  // goes out only once email_live, the sender and the provider key are set. Without the outbox the request is only
  // audited and the page says email isn't live yet. Once per business per DOCUMENT_REQUEST_COOLDOWN_HOURS.
  const documentRequest = async () => {
    const businessId = kit.requireId(fields.businessId);
    const { data: b, error: bError } = await admin.from("businesses").select("id, name, email, cancelled_at").eq("id", businessId).maybeSingle();
    if (bError) throw bError;
    if (!b || b.cancelled_at) throw new InputError("Business not found", 404);
    const { data: docs, error: dError } = await admin.from("business_verification_documents").select("kind, status").eq("business_id", businessId);
    if (dError) throw dError;
    const missing = missingDocuments((docs ?? []) as { kind: string; status: string }[]);
    if (!missing.length) throw new InputError("This business has every required document.", 409);
    const last = (await lastRequests([businessId])).get(businessId);
    if (last && Date.now() - Date.parse(last) < DOCUMENT_REQUEST_COOLDOWN_HOURS * 3_600_000) {
      throw new InputError(`Documents were already requested ${new Date(last).toISOString().slice(0, 16).replace("T", " ")} UTC. Ask again after ${DOCUMENT_REQUEST_COOLDOWN_HOURS} hours.`, 429);
    }
    const { data: invite } = await admin.from("business_invitations").select("email").eq("business_id", businessId).eq("role", "owner")
      .in("status", ["pending", "sent", "accepted"]).order("created_at", { ascending: false }).limit(1).maybeSingle();
    const to = text((invite as { email?: string } | null)?.email ?? b.email, 254).toLowerCase();
    let emailId: string | null = null, emailState: "queued" | "not_installed" | "no_address" = "no_address";
    if (to) {
      const data = { business: String(b.name), appUrl: Deno.env.get("ZELLA_APP_URL") ?? "" } as unknown as Parameters<typeof renderEmail>[1];
      const m = renderEmail("S4", data, { strict: true });
      const { data: id, error: qError } = await admin.rpc("zella_queue_platform_email", {
        p_business: businessId, p_code: "S4", p_dedupe_key: `email:S4:${businessId}:${Date.now()}`, p_to: to,
        p_subject: m.subject, p_html: m.html, p_text: m.text, p_mandatory: true, p_user: null, p_cc: [],
      });
      if (qError?.code === "PGRST202" || (qError && missingTable(qError))) emailState = "not_installed";
      else if (qError) throw qError;
      else { emailState = "queued"; emailId = String(id); }
    }
    return { businessId, name: b.name, missing, email: emailState, emailId, to: to ? `${to.slice(0, 1)}…@${to.split("@")[1] ?? ""}` : null };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    setup_check_duplicates: checkDuplicates,
    business_delete_draft: deleteDraft,
    documents_missing: documentsMissing,
    document_request: documentRequest,
  };

  // business_delete_draft is audited by zella_delete_draft_business itself, in the same transaction as the delete.
  const audited: Record<string, (r: Json) => Json> = {
    document_request: (r) => ({ action: "business.documents_requested", business_id: r.businessId, entity_type: "business", entity_id: r.businessId,
      new_data: { missing: r.missing, email: r.email, email_id: r.emailId } }),
  };

  return { handlers, audited };
}
