// Create Business wizard: operations, team and verification documents.
//
// Every action here runs after index.ts has verified the caller's sign-in, their platform role and the permission
// listed in ONBOARDING_PERMISSIONS (checked in the database by zella_admin_can). Business ids come from the request
// but every read and write is scoped to that one business; files are only reachable through short-lived links made
// here, never through the storage bucket directly.

import type { SupabaseClient } from "@supabase/supabase-js";

type Json = Record<string, unknown>;

export type OnboardingKit = {
  text: (v: unknown, max?: number) => string;
  bool: (v: unknown, fallback?: boolean) => boolean;
  obj: (v: unknown) => Json;
  requireId: (v: unknown, label?: string) => string;
  optionalPhone: (v: unknown, label: string) => string;
  getBusiness: (admin: SupabaseClient, businessId: string) => Promise<Json>;
  getReceptionist: (admin: SupabaseClient, businessId: string) => Promise<{ agent: Json; config: Json | null }>;
  advance: (admin: SupabaseClient, businessId: string, status: string) => Promise<void>;
  mergeSetupData: (admin: SupabaseClient, businessId: string, key: string, value: unknown) => Promise<void>;
  InputError: new (message: string, status?: number) => Error;
  EMAIL_RE: RegExp;
  UUID_RE: RegExp;
};

export const ONBOARDING_PERMISSIONS: Record<string, string> = {
  setup_save_operations: "businesses.manage",
  setup_save_team: "businesses.manage",
  setup_document_upload_url: "businesses.manage",
  setup_document_confirm: "businesses.manage",
  document_view: "businesses.manage",
  document_review: "businesses.manage",
};

export const DOCUMENT_BUCKET = "business-documents";
const DOCUMENT_KINDS = ["business_registration", "owner_identity", "tax_registration", "professional_license"] as const;
export const REQUIRED_DOCUMENTS = ["business_registration", "owner_identity"] as const;
const DOCUMENT_TYPES: Record<string, string> = {
  "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic",
};
const MAX_BYTES = 10 * 1024 * 1024;

const DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] as const; // index = business_hours.weekday
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const KEY_RE = /^[a-z][a-z0-9_]{0,39}$/;
const STAFF_COLORS = ["#8a5a3c", "#3c6e8a", "#5a8a3c", "#8a3c6e", "#6e5a8a", "#8a7a3c"];

// The documents table arrives with sql/zella_onboarding.sql; until then the wizard says so instead of failing.
export function missingTable(error: { code?: string; message?: string } | null) {
  return Boolean(error && (error.code === "42P01" || error.code === "PGRST205" || /does not exist|could not find the table/i.test(error.message ?? "")));
}

// Opening hours as the wizard sends them ({ mon: { closed, open, close } }), checked, in two shapes:
// table rows for business_hours (weekday 0 = Sunday) and the knowledge-base form the AI reads.
export function cleanHours(input: Json, kit: OnboardingKit) {
  const rows: { weekday: number; opens: string; closes: string }[] = [];
  const kb: Json = {};
  for (const [weekday, day] of DAYS.entries()) {
    const h = kit.obj(input[day]);
    if (kit.bool(h.closed, false)) { kb[day] = { closed: true }; continue; }
    const open = kit.text(h.open, 5);
    const close = kit.text(h.close, 5);
    if (!open && !close) { kb[day] = { not_set: true }; continue; }
    if (!TIME_RE.test(open) || !TIME_RE.test(close)) throw new kit.InputError(`Enter both opening and closing times for ${day}`);
    if (close <= open) throw new kit.InputError(`On ${day} the closing time must be after the opening time`);
    rows.push({ weekday, opens: open, closes: close });
    kb[day] = { closed: false, open, close };
  }
  return { rows, kb };
}

export function onboardingHandlers(admin: SupabaseClient, fields: Json, userId: string, kit: OnboardingKit) {
  const { text, bool, obj, requireId, InputError } = kit;

  const saveOperations = async () => {
    const businessId = requireId(fields.businessId);
    const business = await kit.getBusiness(admin, businessId);
    const input = obj(fields.operations);
    const { rows, kb: hoursKb } = cleanHours(obj(input.hours), kit);

    const services = (Array.isArray(input.services) ? input.services : []).slice(0, 100).map((item) => {
      const s = obj(item);
      return { name: text(s.name, 120), description: text(s.description, 600), price: text(s.price, 60), duration: text(s.duration, 60) };
    }).filter((s) => s.name);

    // Industry questions arrive as [{ key, label, value }]; only short, plain facts are kept.
    const details = (Array.isArray(input.details) ? input.details : []).slice(0, 30).map((item) => {
      const d = obj(item);
      const raw = d.value;
      const value = typeof raw === "boolean" ? raw : typeof raw === "number" && Number.isFinite(raw) ? raw : text(raw, 500);
      return { key: text(d.key, 40), label: text(d.label, 80), value };
    }).filter((d) => KEY_RE.test(d.key) && d.label && d.value !== "" && d.value !== null);

    const booking = obj(input.booking);
    const minutes = (v: unknown, lo: number, hi: number, fallback: number | null) => {
      const n = Number(v);
      return Number.isFinite(n) && n >= lo && n <= hi ? Math.round(n) : fallback;
    };
    const bookingRules = bool(input.appointments, true) ? {
      default_minutes: minutes(booking.defaultMinutes, 5, 480, 30),
      buffer_minutes: minutes(booking.bufferMinutes, 0, 120, 0),
      min_notice_hours: minutes(booking.minNoticeHours, 0, 168, 2),
      max_days_ahead: minutes(booking.maxDaysAhead, 1, 365, 60),
    } : null;
    const about = text(input.about, 3000);
    const area = details.find((d) => d.key === "service_area" || d.key === "areas_covered");

    // 1. Opening hours: the table the open/closed check, after-hours replies and bookings read.
    const { error: delError } = await admin.from("business_hours").delete().eq("business_id", businessId);
    if (delError) throw delError;
    if (rows.length) {
      const { error } = await admin.from("business_hours").insert(rows.map((r) => ({ ...r, business_id: businessId })));
      if (error) throw error;
    }

    // 2. The business record and its setup answers.
    const { error: bizError } = await admin.from("businesses")
      .update({ description: about || null, updated_at: new Date().toISOString() }).eq("id", businessId);
    if (bizError) throw bizError;
    await kit.mergeSetupData(admin, businessId, "operations", { details, booking: bookingRules, appointments: bookingRules !== null });

    // 3. What the AI receptionist knows: merged, so the receptionist step's own answers stay.
    const { agent, config } = await kit.getReceptionist(admin, businessId);
    const knowledge = {
      ...obj(config?.knowledge_base),
      about, hours: hoursKb, services,
      service_area: area ? String(area.value) : "",
      business_details: details.map((d) => ({ label: d.label, value: typeof d.value === "boolean" ? (d.value ? "Yes" : "No") : String(d.value) })),
    };
    const appointmentRules = { ...obj(config?.appointment_rules), ...(bookingRules ?? {}), takes_bookings: bookingRules !== null };
    const values = { knowledge_base: knowledge, appointment_rules: appointmentRules, updated_at: new Date().toISOString() };
    const { error: cfgError } = config
      ? await admin.from("ai_agent_configs").update(values).eq("id", config.id as string)
      : await admin.from("ai_agent_configs").insert({ agent_id: agent.id, business_context: { business_name: business.name, industry_id: business.industry_id, timezone: business.timezone }, ...values });
    if (cfgError) throw cfgError;

    await kit.advance(admin, businessId, "industry_setup");
    return { businessId, hours: rows.length, services: services.length, details: details.length };
  };

  const saveTeam = async () => {
    const businessId = requireId(fields.businessId);
    await kit.getBusiness(admin, businessId);
    const input = (Array.isArray(fields.team) ? fields.team : []).slice(0, 50).map((item) => {
      const s = obj(item);
      const email = text(s.email, 254).toLowerCase();
      if (email && !kit.EMAIL_RE.test(email)) throw new InputError(`Enter a valid email for ${text(s.name, 80) || "each team member"}`);
      return { id: text(s.id, 64), name: text(s.name, 120), title: text(s.title, 80), phone: kit.optionalPhone(s.phone, "team member phone"), email };
    }).filter((s) => s.name);

    // New team members work the business's opening hours until their own are set in the CRM.
    const { data: hourRows, error: hoursError } = await admin.from("business_hours").select("weekday, opens, closes").eq("business_id", businessId);
    if (hoursError) throw hoursError;
    const working: Json = {};
    for (const [weekday, day] of DAYS.entries()) {
      const h = (hourRows ?? []).filter((r) => r.weekday === weekday).sort((a, b) => String(a.opens).localeCompare(String(b.opens)));
      working[day] = h.length
        ? { on: true, start: String(h[0].opens).slice(0, 5), end: String(h[h.length - 1].closes).slice(0, 5) }
        : { on: false };
    }

    const { data: current, error: currentError } = await admin.from("staff_members").select("id").eq("business_id", businessId).eq("is_active", true);
    if (currentError) throw currentError;
    const known = new Set((current ?? []).map((r) => r.id));
    const kept = new Set<string>();
    const now = new Date().toISOString();
    let added = 0;
    for (const [n, s] of input.entries()) {
      const row = { name: s.name, title: s.title || null, phone: s.phone || null, email: s.email || null, sort_order: n, updated_at: now };
      if (s.id && known.has(s.id)) {
        kept.add(s.id);
        const { error } = await admin.from("staff_members").update(row).eq("id", s.id).eq("business_id", businessId);
        if (error) throw error;
      } else {
        const { error } = await admin.from("staff_members").insert({
          ...row, business_id: businessId, is_active: true, color: STAFF_COLORS[n % STAFF_COLORS.length], working_hours: hourRows?.length ? working : {},
        });
        if (error) throw error;
        added += 1;
      }
    }
    // Removed in the wizard: switched off, never deleted, so past bookings keep their name.
    const removed = [...known].filter((id) => !kept.has(id));
    if (removed.length) {
      const { error } = await admin.from("staff_members").update({ is_active: false, updated_at: now }).in("id", removed).eq("business_id", businessId);
      if (error) throw error;
    }
    return { businessId, team: input.length, added, removed: removed.length };
  };

  const kindOf = (v: unknown) => {
    const kind = text(v, 40);
    if (!DOCUMENT_KINDS.includes(kind as typeof DOCUMENT_KINDS[number])) throw new InputError("Choose a document type");
    return kind;
  };
  const fileOf = () => {
    const mime = text(fields.mimeType, 60).toLowerCase();
    const ext = DOCUMENT_TYPES[mime];
    if (!ext) throw new InputError("Upload a PDF, JPG, PNG, WEBP or HEIC file");
    const size = Number(fields.size);
    if (!Number.isFinite(size) || size < 1 || size > MAX_BYTES) throw new InputError("Files must be 10 MB or smaller");
    const name = text(fields.fileName, 200).replace(/[\u0000-\u001f\\/]/g, "_") || `document.${ext}`;
    return { mime, ext, size: Math.round(size), name };
  };

  const documentUploadUrl = async () => {
    const businessId = requireId(fields.businessId);
    await kit.getBusiness(admin, businessId);
    const kind = kindOf(fields.kind);
    const file = fileOf();
    const path = `${businessId}/${kind}/${crypto.randomUUID()}.${file.ext}`;
    const { data, error } = await admin.storage.from(DOCUMENT_BUCKET).createSignedUploadUrl(path);
    if (error) {
      if (/not found|bucket/i.test(error.message)) throw new InputError("Document storage isn't set up yet. Apply sql/zella_onboarding.sql first.", 409);
      throw error;
    }
    return { path, token: data.token };
  };

  const documentConfirm = async () => {
    const businessId = requireId(fields.businessId);
    await kit.getBusiness(admin, businessId);
    const kind = kindOf(fields.kind);
    const file = fileOf();
    const path = text(fields.path, 300);
    // The path must be one this function issued for this business and kind.
    if (!new RegExp(`^${businessId}/${kind}/[0-9a-f-]{36}\\.(pdf|jpg|png|webp|heic)$`).test(path)) throw new InputError("That upload doesn't belong to this business");
    const folder = `${businessId}/${kind}`;
    const { data: found, error: listError } = await admin.storage.from(DOCUMENT_BUCKET).list(folder, { search: path.slice(folder.length + 1) });
    if (listError) throw listError;
    if (!found?.some((o) => `${folder}/${o.name}` === path)) throw new InputError("The file didn't finish uploading. Try again.");

    const now = new Date().toISOString();
    const { error: oldError } = await admin.from("business_verification_documents")
      .update({ status: "replaced", updated_at: now }).eq("business_id", businessId).eq("kind", kind).neq("status", "replaced");
    if (oldError) throw oldError;
    const { data, error } = await admin.from("business_verification_documents").insert({
      business_id: businessId, kind, file_path: path, file_name: file.name, mime_type: file.mime, size_bytes: file.size, uploaded_by: userId,
    }).select("id, kind, file_name, mime_type, size_bytes, status, review_note, created_at, reviewed_at").single();
    if (error) throw error;
    return { businessId, document: data };
  };

  const documentRow = async () => {
    const id = requireId(fields.documentId, "document");
    const { data, error } = await admin.from("business_verification_documents").select("id, business_id, kind, file_path, status").eq("id", id).maybeSingle();
    if (error) throw error;
    if (!data) throw new InputError("Document not found", 404);
    return data;
  };

  const documentView = async () => {
    const doc = await documentRow();
    const { data, error } = await admin.storage.from(DOCUMENT_BUCKET).createSignedUrl(doc.file_path, 60);
    if (error) throw error;
    return { url: data.signedUrl, documentId: doc.id, businessId: doc.business_id, kind: doc.kind };
  };

  const documentReview = async () => {
    const doc = await documentRow();
    const status = text(fields.status, 20);
    if (!["verified", "rejected"].includes(status)) throw new InputError("Choose verified or rejected");
    if (doc.status === "replaced") throw new InputError("A newer copy of this document was uploaded. Review that one.", 409);
    const note = text(fields.note, 500);
    if (status === "rejected" && !note) throw new InputError("Say why the document was rejected, so it can be fixed");
    const now = new Date().toISOString();
    const { data, error } = await admin.from("business_verification_documents")
      .update({ status, review_note: note || null, reviewed_by: userId, reviewed_at: now, updated_at: now })
      .eq("id", doc.id).select("id, kind, file_name, mime_type, size_bytes, status, review_note, created_at, reviewed_at").single();
    if (error) throw error;
    return { businessId: doc.business_id, before: doc.status, document: data };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    setup_save_operations: saveOperations,
    setup_save_team: saveTeam,
    setup_document_upload_url: documentUploadUrl,
    setup_document_confirm: documentConfirm,
    document_view: documentView,
    document_review: documentReview,
  };

  // Audit entries, from each action's result. File contents and paths are never logged.
  const audited: Record<string, (r: Json) => Json> = {
    setup_save_operations: (r) => ({ action: "business.operations_updated", business_id: r.businessId, entity_type: "business", entity_id: r.businessId, new_data: { hours: r.hours, services: r.services, details: r.details } }),
    setup_save_team: (r) => ({ action: "business.team_updated", business_id: r.businessId, entity_type: "staff_member", new_data: { team: r.team, added: r.added, removed: r.removed } }),
    setup_document_confirm: (r) => ({ action: "business.document_uploaded", business_id: r.businessId, entity_type: "verification_document", entity_id: obj(r.document).id, new_data: { kind: obj(r.document).kind, file_name: obj(r.document).file_name } }),
    document_view: (r) => ({ action: "business.document_viewed", business_id: r.businessId, entity_type: "verification_document", entity_id: r.documentId, new_data: { kind: r.kind } }),
    document_review: (r) => ({ action: "business.document_" + obj(r.document).status, business_id: r.businessId, entity_type: "verification_document", entity_id: obj(r.document).id, old_data: { status: r.before }, new_data: { status: obj(r.document).status, note: obj(r.document).review_note } }),
  };

  return { handlers, audited };
}

// What loadSetup adds for the wizard: documents, team, saved operations. A missing documents table (update not
// applied yet) is reported, not treated as an error.
export async function loadOnboarding(admin: SupabaseClient, businessId: string, setupData: Json) {
  const [docs, staff] = await Promise.all([
    admin.from("business_verification_documents")
      .select("id, kind, file_name, mime_type, size_bytes, status, review_note, created_at, reviewed_at")
      .eq("business_id", businessId).neq("status", "replaced").order("created_at", { ascending: false }),
    admin.from("staff_members").select("id, name, title, phone, email").eq("business_id", businessId).eq("is_active", true).order("sort_order").order("name"),
  ]);
  if (docs.error && !missingTable(docs.error)) throw docs.error;
  if (staff.error) throw staff.error;
  const { data: hours, error: hoursError } = await admin.from("business_hours").select("weekday, opens, closes").eq("business_id", businessId).order("weekday").order("opens");
  if (hoursError) throw hoursError;
  return {
    documentsAvailable: !docs.error,
    documents: docs.error ? [] : docs.data ?? [],
    team: staff.data ?? [],
    hours: hours ?? [],
    operations: (setupData.operations && typeof setupData.operations === "object") ? setupData.operations : null,
  };
}

// Finishing needs both required documents uploaded and not rejected, once document storage exists.
export async function documentsReady(admin: SupabaseClient, businessId: string) {
  const { data, error } = await admin.from("business_verification_documents")
    .select("kind, status").eq("business_id", businessId).neq("status", "replaced");
  if (error) {
    if (missingTable(error)) return { ready: true, missing: [] as string[], available: false };
    throw error;
  }
  const ok = new Set((data ?? []).filter((d) => d.status !== "rejected").map((d) => d.kind));
  const missing = REQUIRED_DOCUMENTS.filter((k) => !ok.has(k));
  return { ready: missing.length === 0, missing, available: true };
}
