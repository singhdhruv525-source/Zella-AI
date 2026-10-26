// Admin dashboard: industry records, per-business record types and modules, and the verification queue.
//
// Every action runs after index.ts has checked the caller's sign-in, platform role and the permission listed in
// PLATFORM_PERMISSIONS. Industry records are the per-industry record types (restaurant: tables and events; dental:
// recalls ...) kept in industry_crm_presets and copied into each business by zella_apply_crm_preset.

import type { SupabaseClient } from "@supabase/supabase-js";
import { DOCUMENT_BUCKET, missingTable } from "./onboarding.ts";

type Json = Record<string, unknown>;

export type PlatformKit = {
  text: (v: unknown, max?: number) => string;
  bool: (v: unknown, fallback?: boolean) => boolean;
  obj: (v: unknown) => Json;
  requireId: (v: unknown, label?: string) => string;
  InputError: new (message: string, status?: number) => Error;
};

export const PLATFORM_PERMISSIONS: Record<string, string> = {
  industry_records_get: "businesses.view",
  industry_records_save: "platform.configure",
  business_records_get: "businesses.view",
  business_records_save: "businesses.manage",
  documents_queue: "businesses.manage",
};

const KEY_RE = /^[a-z][a-z0-9_]{0,39}$/;
const ICON_RE = /^[a-z][a-z0-9_]{0,39}$/;
const FIELD_TYPES = ["text", "longtext", "number", "date", "datetime", "select", "phone", "bool"] as const;
const TONES = ["", "info", "success", "warning", "danger"] as const;

// The same normalised name zella_apply_crm_preset matches presets on.
export const normalise = (name: string) => name.toLowerCase().replace(/[^a-z]/g, "");

export function platformHandlers(admin: SupabaseClient, fields: Json, kit: PlatformKit) {
  const { text, bool, obj, requireId, InputError } = kit;

  const industryOf = async (id: string) => {
    const { data, error } = await admin.from("industries").select("id, name, slug").eq("id", id).maybeSingle();
    if (error) throw error;
    if (!data) throw new InputError("Industry not found", 404);
    return data;
  };

  // The preset this industry's businesses get, which other industries share it, and how many businesses use it.
  const presetFor = async (industry: { id: string; name: string }) => {
    const name = normalise(industry.name);
    const [{ data: presets, error }, { data: industries, error: indError }] = await Promise.all([
      admin.from("industry_crm_presets").select("key, match, config, updated_at").order("key"),
      admin.from("industries").select("id, name"),
    ]);
    if (error) throw error;
    if (indError) throw indError;
    const preset = (presets ?? []).find((p) => (p.match ?? []).includes(name)) ?? null;
    const sharedWith = preset
      ? (industries ?? []).filter((i) => i.id !== industry.id && (preset.match ?? []).includes(normalise(i.name))).map((i) => i.name)
      : [];
    return { preset, sharedWith, fallback: preset ? null : (presets ?? []).find((p) => p.key === "other") ?? null };
  };

  const cleanTypes = (input: unknown) => {
    if (!Array.isArray(input)) throw new InputError("Record types are missing");
    if (input.length > 12) throw new InputError("An industry can have at most 12 record types");
    const seen = new Set<string>();
    return input.map((raw, n) => {
      const t = obj(raw);
      const key = text(t.key, 40);
      if (!KEY_RE.test(key)) throw new InputError(`Record type ${n + 1}: the key must be lower case letters, numbers and _`);
      if (seen.has(key)) throw new InputError(`Two record types use the key "${key}"`);
      seen.add(key);
      const singular = text(t.singular, 60);
      const plural = text(t.plural, 60);
      if (!singular || !plural) throw new InputError(`${key}: enter the singular and plural names`);
      const icon = text(t.icon, 40) || "folder";
      if (!ICON_RE.test(icon)) throw new InputError(`${plural}: the icon must be a Material Symbols name, like table_restaurant`);

      const fieldKeys = new Set<string>();
      const fieldsIn = Array.isArray(t.fields) ? t.fields : [];
      if (fieldsIn.length > 30) throw new InputError(`${plural}: at most 30 fields`);
      const fieldList = fieldsIn.map((rf) => {
        const f = obj(rf);
        const fkey = text(f.key, 40);
        if (!KEY_RE.test(fkey)) throw new InputError(`${plural}: every field needs a key of lower case letters, numbers and _`);
        if (fieldKeys.has(fkey)) throw new InputError(`${plural}: two fields use the key "${fkey}"`);
        fieldKeys.add(fkey);
        const label = text(f.label, 60);
        if (!label) throw new InputError(`${plural}: every field needs a label`);
        const type = text(f.type, 20);
        if (!FIELD_TYPES.includes(type as typeof FIELD_TYPES[number])) throw new InputError(`${plural} > ${label}: choose a field type`);
        const field: Json = { key: fkey, label, type };
        if (type === "select") {
          const options = (Array.isArray(f.options) ? f.options : []).map((o) => text(o, 60)).filter(Boolean).slice(0, 30);
          if (!options.length) throw new InputError(`${plural} > ${label}: a choice field needs at least one option`);
          field.options = [...new Set(options)];
        }
        if (bool(f.required, false)) field.required = true;
        if (bool(f.unique, false)) field.unique = true;
        return field;
      });

      const statusKeys = new Set<string>();
      const statuses = (Array.isArray(t.statuses) ? t.statuses : []).slice(0, 12).map((rs) => {
        const s = obj(rs);
        const skey = text(s.key, 40);
        if (!KEY_RE.test(skey)) throw new InputError(`${plural}: every status needs a key of lower case letters, numbers and _`);
        if (statusKeys.has(skey)) throw new InputError(`${plural}: two statuses use the key "${skey}"`);
        statusKeys.add(skey);
        const label = text(s.label, 40);
        if (!label) throw new InputError(`${plural}: every status needs a label`);
        const tone = text(s.tone, 10);
        return { key: skey, label, tone: TONES.includes(tone as typeof TONES[number]) ? tone : "" };
      });
      if (!statuses.length) throw new InputError(`${plural}: add at least one status`);
      const closed = (Array.isArray(t.closed_statuses) ? t.closed_statuses : []).map((c) => text(c, 40)).filter((c) => statusKeys.has(c));
      const columns = (Array.isArray(t.columns) ? t.columns : []).map((c) => text(c, 40)).filter((c) => fieldKeys.has(c)).slice(0, 6);

      return {
        key, singular, plural, icon,
        title_label: text(t.title_label, 40) || "Name",
        link_person: bool(t.link_person, true),
        notice: text(t.notice, 500) || null,
        fields: fieldList, statuses, closed_statuses: [...new Set(closed)], columns: [...new Set(columns)],
      };
    });
  };

  const industryRecordsGet = async () => {
    const industry = await industryOf(requireId(fields.industryId, "industry"));
    const { preset, sharedWith, fallback } = await presetFor(industry);
    const source = preset ?? fallback;
    const { count, error } = await admin.from("businesses").select("id", { count: "exact", head: true }).eq("industry_id", industry.id);
    if (error) throw error;
    return {
      industryId: industry.id, presetKey: preset?.key ?? null, usesGeneral: !preset, sharedWith,
      types: obj(source?.config).types ?? [], updatedAt: preset?.updated_at ?? null, businesses: count ?? 0,
    };
  };

  const industryRecordsSave = async () => {
    const industry = await industryOf(requireId(fields.industryId, "industry"));
    const types = cleanTypes(fields.types);
    const { preset } = await presetFor(industry);
    const now = new Date().toISOString();
    if (preset) {
      const before = obj(preset.config).types ?? [];
      const { error } = await admin.from("industry_crm_presets").update({ config: { ...obj(preset.config), types }, updated_at: now }).eq("key", preset.key);
      if (error) throw error;
      return { industryId: industry.id, presetKey: preset.key, created: false, before: (before as Json[]).map((t) => t.key), after: types.map((t) => t.key) };
    }
    // This industry used the general set; it now gets its own, matched on its name like every other preset.
    const base = (industry.slug || normalise(industry.name)).replace(/-/g, "_").replace(/[^a-z0-9_]/g, "") || "industry";
    const { data: taken, error: takenError } = await admin.from("industry_crm_presets").select("key").like("key", `${base}%`);
    if (takenError) throw takenError;
    const used = new Set((taken ?? []).map((r) => r.key));
    let key = base;
    for (let n = 2; used.has(key); n++) key = `${base}_${n}`;
    const { error } = await admin.from("industry_crm_presets").insert({ key, match: [normalise(industry.name)], config: { types }, updated_at: now });
    if (error) throw error;
    return { industryId: industry.id, presetKey: key, created: true, before: [], after: types.map((t) => t.key) };
  };

  const businessRecordsGet = async () => {
    const businessId = requireId(fields.businessId);
    const { data: business, error: bizError } = await admin.from("businesses").select("id, onboarding_status").eq("id", businessId).maybeSingle();
    if (bizError) throw bizError;
    if (!business) throw new InputError("Business not found", 404);
    const read = () => admin.from("crm_record_types").select("key, singular, plural, icon, enabled, position, preset_key").eq("business_id", businessId).order("position");
    let { data, error } = await read();
    if (error) throw error;
    // A finished business whose CRM hasn't been opened yet gets its industry's types now, as the CRM would.
    if (!data?.length && ["testing", "ready", "active", "paused"].includes(business.onboarding_status)) {
      const { error: applyError } = await admin.rpc("zella_apply_crm_preset", { p_business_id: businessId });
      if (applyError) throw applyError;
      ({ data, error } = await read());
      if (error) throw error;
    }
    const counts = new Map<string, number>();
    const { data: records, error: recError } = await admin.from("crm_records").select("type_key").eq("business_id", businessId).limit(5000);
    if (recError) throw recError;
    for (const r of records ?? []) counts.set(r.type_key, (counts.get(r.type_key) ?? 0) + 1);
    return { businessId, status: business.onboarding_status, types: (data ?? []).map((t) => ({ ...t, records: counts.get(t.key) ?? 0 })) };
  };

  const businessRecordsSave = async () => {
    const businessId = requireId(fields.businessId);
    const input = obj(fields.enabled);
    const { data: current, error } = await admin.from("crm_record_types").select("key, enabled").eq("business_id", businessId);
    if (error) throw error;
    const now = new Date().toISOString();
    const changes: Json[] = [];
    for (const t of current ?? []) {
      if (!(t.key in input)) continue;
      const enabled = bool(input[t.key], t.enabled);
      if (enabled === t.enabled) continue;
      // Switching a type off hides it in the CRM; its records are kept.
      const { error: upError } = await admin.from("crm_record_types").update({ enabled, updated_at: now }).eq("business_id", businessId).eq("key", t.key);
      if (upError) throw upError;
      changes.push({ key: t.key, enabled });
    }
    return { businessId, changes };
  };

  const documentsQueue = async () => {
    const status = text(fields.status, 20) || "pending_review";
    if (!["pending_review", "verified", "rejected", "all"].includes(status)) throw new InputError("Unknown status filter");
    let query = admin.from("business_verification_documents")
      .select("id, business_id, kind, file_name, mime_type, size_bytes, status, review_note, created_at, reviewed_at")
      .neq("status", "replaced").order("created_at", { ascending: status === "pending_review" }).limit(200);
    if (status !== "all") query = query.eq("status", status);
    const { data, error } = await query;
    if (error) {
      if (missingTable(error)) return { available: false, documents: [], bucket: DOCUMENT_BUCKET };
      throw error;
    }
    const ids = [...new Set((data ?? []).map((d) => d.business_id))];
    const { data: names, error: nameError } = ids.length
      ? await admin.from("businesses").select("id, name, onboarding_status").in("id", ids)
      : { data: [], error: null };
    if (nameError) throw nameError;
    const byId = new Map((names ?? []).map((b) => [b.id, b]));
    const { data: counts, error: countError } = await admin.from("business_verification_documents").select("status").neq("status", "replaced");
    if (countError) throw countError;
    const totals: Record<string, number> = { pending_review: 0, verified: 0, rejected: 0 };
    for (const c of counts ?? []) totals[c.status] = (totals[c.status] ?? 0) + 1;
    return {
      available: true, totals, bucket: DOCUMENT_BUCKET,
      documents: (data ?? []).map((d) => ({ ...d, business_name: byId.get(d.business_id)?.name ?? "Deleted business", business_status: byId.get(d.business_id)?.onboarding_status ?? null })),
    };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    industry_records_get: industryRecordsGet,
    industry_records_save: industryRecordsSave,
    business_records_get: businessRecordsGet,
    business_records_save: businessRecordsSave,
    documents_queue: documentsQueue,
  };

  const audited: Record<string, (r: Json) => Json> = {
    industry_records_save: (r) => ({ action: r.created ? "industry.records_created" : "industry.records_updated", entity_type: "industry", entity_id: r.industryId, old_data: { preset: r.presetKey, types: r.before }, new_data: { preset: r.presetKey, types: r.after } }),
    business_records_save: (r) => ({ action: "business.record_types_updated", business_id: r.businessId, entity_type: "business", entity_id: r.businessId, new_data: { changes: r.changes } }),
  };

  return { handlers, audited };
}
