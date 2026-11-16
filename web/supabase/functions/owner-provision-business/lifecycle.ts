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
  retry_step: "businesses.manage",
  export_request: "businesses.manage",
  export_decide: "businesses.manage",   // and the zella_owner role, never the requester (checked again in the database)
  export_status: "security.view",       // the Data lifecycle page's permission
  export_download: "businesses.manage", // and the requester or a Zella Voice owner
};

// SET-DL-EXPORT defaults (owner can change): an admin requests, a Zella Voice owner other than the requester
// approves, and the export can be downloaded for EXPORT_DAYS through signed links that end with it.
export const EXPORT_DAYS = 7;
export const EXPORT_BUCKET = "business-exports";

// SET-ONB-RETRY default (owner can change): only these internal database steps are retried, by a person here or by
// the timed job (switched off until the owner turns it on). The owner invitation email gets Send owner invite; steps
// that reach a provider or need the admin's answers are finished through Continue setup.
export const RETRYABLE_STEPS = ["modules", "receptionist", "automations"];

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

// SET-ONB-RETRY part 1: every setup save records its step in provisioning_steps through zella_track_provisioning
// (pending, then done or failed), so the Failed steps column and the provisioning alerts fill. A deliberate refusal
// (an InputError, answered before any work) is not a failed step: the step goes back to what it was. Recording never blocks or
// changes the save itself.
export const SETUP_STEPS: Record<string, string> = {
  setup_save_business: "business", setup_save_owner: "owner", setup_save_operations: "operations", setup_save_team: "team",
  setup_save_terminology: "terminology", setup_save_modules: "modules", setup_save_receptionist: "receptionist",
  setup_save_integrations: "integrations", setup_save_spam: "spam", setup_save_automations: "automations",
  setup_finish: "finish",
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function track(admin: SupabaseClient, businessId: string, step: string, status: "pending" | "done" | "failed", error: string | null = null) {
  try {
    const { error: e } = await admin.rpc("zella_track_provisioning", { p_business_id: businessId, p_step: step, p_status: status, p_error: error });
    if (e) console.error(`Provisioning step ${step} could not be recorded`, e);
  } catch (e) { console.error(`Provisioning step ${step} could not be recorded`, e); }
}

export async function trackSetup<T>(admin: SupabaseClient, action: string, fields: Json, run: () => Promise<T>): Promise<T> {
  const step = SETUP_STEPS[action];
  if (!step) return await run();
  const given = typeof fields.businessId === "string" && UUID.test(fields.businessId) ? fields.businessId : null;
  let before: { status: string; error: string | null } | null = null;
  if (given) {
    try {
      const { data } = await admin.from("provisioning_steps").select("status, error").eq("business_id", given).eq("step", step).maybeSingle();
      before = (data as { status: string; error: string | null } | null) ?? null;
    } catch { before = null; }
    await track(admin, given, step, "pending");
  }
  let result: T;
  try {
    result = await run();
  } catch (e) {
    const status = (e as { status?: unknown }).status;
    if (given && typeof status === "number") {
      // a deliberate refusal (InputError: bad input, or setup can't finish yet, such as no plan check or no app
      // address): it is answered before anything is provisioned, so the step is put back as it was
      try {
        if (before) await admin.from("provisioning_steps").update({ status: before.status, error: before.error }).eq("business_id", given).eq("step", step);
        else await admin.from("provisioning_steps").delete().eq("business_id", given).eq("step", step).eq("status", "pending");
      } catch (restoreError) { console.error(`Provisioning step ${step} could not be put back`, restoreError); }
    } else if (given) {
      await track(admin, given, step, "failed", e instanceof Error ? e.message : String(e));
    }
    throw e;
  }
  const r = (result ?? {}) as Json;
  const businessId = given ?? (typeof r.businessId === "string" && UUID.test(r.businessId) ? r.businessId : null);
  if (!businessId) return result;
  if (action === "setup_finish") {
    // the owner invitation email is its own step; the finish is done when the workspace is activated
    if (r.invitationStatus === "failed") {
      await track(admin, businessId, "owner_invitation", "failed", typeof r.invitationError === "string" ? r.invitationError : "The invitation email failed");
      await track(admin, businessId, step, "failed", "The owner invitation email failed");
    } else if (r.completed === false) {
      // the invitation was cancelled while it went out: nothing failed, nothing finished
      try { await admin.from("provisioning_steps").delete().eq("business_id", businessId).eq("step", step).eq("status", "pending"); }
      catch (e) { console.error("Provisioning step finish could not be put back", e); }
    } else {
      if (r.invitationStatus) await track(admin, businessId, "owner_invitation", "done");
      await track(admin, businessId, step, "done");
    }
  } else {
    await track(admin, businessId, step, "done");
  }
  return result;
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

  // SET-ONB-RETRY part 2: a person retries one failed internal step (zella_retry_provisioning adds only what is
  // missing, records the outcome and audits the attempt with the admin).
  const retryStep = async () => {
    const businessId = kit.requireId(fields.businessId);
    const step = text(fields.step, 40);
    if (!RETRYABLE_STEPS.includes(step)) {
      throw new InputError(step === "owner_invitation" ? "Use Send owner invite to send the invitation again." : "This step can't be retried on its own. Use Continue setup.");
    }
    const { data, error } = await admin.rpc("zella_retry_provisioning", { p_business: businessId, p_step: step, p_actor: userId });
    if (error) {
      const m = error.message ?? "";
      if (error.code === "PGRST202") throw new InputError("Retrying steps isn't installed on this database yet.", 503);
      if (m.includes("NOT_FOUND")) throw new InputError("Business not found", 404);
      if (m.includes("CANCELLED")) throw new InputError("This business is cancelled.", 409);
      throw error;
    }
    const r = obj(data);
    return { businessId, step, status: text(r.status, 20), added: Number(r.added) || 0, note: text(r.note, 300) || null };
  };

  // SET-DL-EXPORT: request, approve or reject, list and download a whole business export.
  const exportError = (error: { code?: string; message?: string }) => {
    const m = error.message ?? "";
    if (error.code === "PGRST202" || error.code === "42P01") return new InputError("Business exports aren't installed on this database yet.", 503);
    if (m.includes("EXPORT_OPEN")) return new InputError("This business already has an export waiting or running.", 409);
    if (m.includes("OWN_REQUEST")) return new InputError("Another Zella Voice owner has to approve your own request.", 403);
    if (m.includes("NOT_ALLOWED")) return new InputError("Only a Zella Voice owner can approve or reject an export.", 403);
    if (m.includes("NOT_REQUESTED")) return new InputError("This export was already decided.", 409);
    if (m.includes("NOT_FOUND")) return new InputError("Not found", 404);
    if (m.includes("REASON_REQUIRED")) return new InputError("Give a short reason (it goes in the audit log).");
    return error as unknown as Error;
  };
  const exportRequest = async () => {
    const businessId = kit.requireId(fields.businessId);
    const reason = text(fields.reason, 300);
    if (reason.length < 3) throw new InputError("Give a short reason (it goes in the audit log).");
    const { data, error } = await admin.rpc("zella_export_request", { p_business: businessId, p_actor: userId, p_reason: reason });
    if (error) throw exportError(error);
    return { id: String(data), businessId, status: "requested" };
  };
  const exportDecide = async () => {
    if (role !== "zella_owner") throw new InputError("Only a Zella Voice owner can approve or reject an export.", 403);
    const id = kit.requireId(fields.id, "export");
    if (typeof fields.approve !== "boolean") throw new InputError("Choose approve or reject.");
    const { data, error } = await admin.rpc("zella_export_decide", { p_id: id, p_actor: userId, p_approve: fields.approve, p_reason: text(fields.reason, 300) || null });
    if (error) throw exportError(error);
    return { id, status: String(data) };
  };
  const exportStatus = async () => {
    const { data, error } = await admin.from("business_export_jobs")
      .select("id, business_id, business_name, status, requested_by, request_reason, decided_by, decided_at, decision_reason, progress, attempts, started_at, finished_at, expires_at, last_error, created_at")
      .order("created_at", { ascending: false }).limit(50);
    if (error) {
      if (missingTable(error)) return { available: false, jobs: [] };
      throw error;
    }
    const jobs = ((data ?? []) as Json[]).map((j) => {
      const p = obj(j.progress);
      return { ...j, progress: { tables: Array.isArray(p.tables_done) ? p.tables_done.length : 0, tablesTotal: Number(p.tables_total) || null,
        files: Number(p.files_done) || 0, filesTotal: Number(p.files_total) || null }, mine: j.requested_by === userId };
    });
    return { available: true, jobs, days: EXPORT_DAYS, canDecide: role === "zella_owner" };
  };
  const exportDownload = async () => {
    const id = kit.requireId(fields.id, "export");
    const { data: j, error } = await admin.from("business_export_jobs").select("id, business_id, status, requested_by, progress, manifest_path, expires_at").eq("id", id).maybeSingle();
    if (error) throw exportError(error);
    if (!j) throw new InputError("Not found", 404);
    if (j.requested_by !== userId && role !== "zella_owner") throw new InputError("Only the person who asked for it or a Zella Voice owner can download an export.", 403);
    const left = Math.floor((Date.parse(String(j.expires_at ?? "")) - Date.now()) / 1000);
    if (j.status !== "ready" || !(left > 0)) throw new InputError("This export isn't ready, or its 7 days are over.", 409);
    const parts = [String(j.manifest_path), ...(Array.isArray(obj(j.progress).parts) ? obj(j.progress).parts as unknown[] : []).map(String)]
      .filter((p, i, a) => p.startsWith(`${id}/`) && a.indexOf(p) === i);
    const { data: signed, error: signError } = await admin.storage.from(EXPORT_BUCKET).createSignedUrls(parts, Math.min(left, EXPORT_DAYS * 86_400));
    if (signError) throw signError;
    return { id, businessId: j.business_id, expiresAt: j.expires_at, links: (signed ?? []).map((x) => ({ path: x.path, url: x.signedUrl })) };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    setup_check_duplicates: checkDuplicates,
    business_delete_draft: deleteDraft,
    documents_missing: documentsMissing,
    document_request: documentRequest,
    retry_step: retryStep,
    export_request: exportRequest,
    export_decide: exportDecide,
    export_status: exportStatus,
    export_download: exportDownload,
  };

  // business_delete_draft and retry_step are audited by their database functions, in the same transaction.
  // export_request and export_decide are audited by their database functions.
  const audited: Record<string, (r: Json) => Json> = {
    export_download: (r) => ({ action: "export.downloaded", business_id: r.businessId, entity_type: "business_export", entity_id: r.id,
      new_data: { files: Array.isArray(r.links) ? r.links.length : 0, expires_at: r.expiresAt } }),
    document_request: (r) => ({ action: "business.documents_requested", business_id: r.businessId, entity_type: "business", entity_id: r.businessId,
      new_data: { missing: r.missing, email: r.email, email_id: r.emailId } }),
  };

  return { handlers, audited };
}
