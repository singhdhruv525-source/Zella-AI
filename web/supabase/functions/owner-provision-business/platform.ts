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
  spam_admin_rules: "security.view",
  spam_admin_overview: "security.view",
  spam_admin_incidents: "security.view",
  spam_admin_incident: "security.view",
  spam_admin_policy_save: "platform.configure",
  spam_admin_rule_add: "security.manage",
  spam_admin_rule_remove: "security.manage",
  spam_admin_automation_save: "platform.configure",
};

// Spam: what platform admins see. Masked senders, reasons and decisions; never message bodies, transcripts,
// recordings or the text of a business's internal notes.
const mask = (s: string) => !s || s === "unknown" ? "Unknown" : s.includes("@") ? `${s.split("@")[0].slice(0, 1)}…@${s.split("@")[1]}` : `…${s.slice(-4)}`;
const SPAM_POLICY_LIMITS: Record<string, [number, number]> = {
  repeat_call_limit: [2, 50], repeat_window_minutes: [5, 1440], sms_flood_limit: [3, 200], email_flood_limit: [3, 200],
  booking_daily_limit: [1, 20], medium_score: [10, 150], high_score: [20, 200], auto_restrict_hours: [1, 168],
  calls_per_hour_alert: [5, 10000], incidents_per_day_alert: [3, 1000], notify_cooldown_per_hour: [1, 60], retention_days: [30, 3650],
};

const KEY_RE = /^[a-z][a-z0-9_]{0,39}$/;
const ICON_RE = /^[a-z][a-z0-9_]{0,39}$/;
const FIELD_TYPES = ["text", "longtext", "number", "date", "datetime", "select", "phone", "bool"] as const;
const TONES = ["", "info", "success", "warning", "danger"] as const;

// The same normalised name zella_apply_crm_preset matches presets on.
export const normalise = (name: string) => name.toLowerCase().replace(/[^a-z]/g, "");

export function platformHandlers(admin: SupabaseClient, fields: Json, kit: PlatformKit, kitUser: string | null = null) {
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

  const since = () => new Date(Date.now() - Math.min(365, Math.max(1, Number(fields.days) || 30)) * 864e5).toISOString();
  const spamMissing = (e: { code?: string; message?: string } | null) => missingTable(e);

  const spamAdminOverview = async () => {
    const from = since();
    const { data: rows, error } = await admin.from("spam_incidents").select("business_id, channel, status, risk_level, action, occurrences").gte("first_seen_at", from).limit(20000);
    if (error) { if (spamMissing(error)) return { available: false }; throw error; }
    const count = (f: (r: Json) => boolean) => (rows ?? []).filter(f).length;
    const byBiz = new Map<string, { total: number; high: number; open: number }>();
    for (const r of rows ?? []) {
      const b = byBiz.get(r.business_id) ?? { total: 0, high: 0, open: 0 };
      b.total += 1; if (r.risk_level === "high") b.high += 1; if (["new", "under_review", "escalated"].includes(r.status)) b.open += 1;
      byBiz.set(r.business_id, b);
    }
    const [{ data: businesses, error: bErr }, { data: settings, error: sErr }, { data: alerts, error: aErr }] = await Promise.all([
      admin.from("businesses").select("id, name, onboarding_status, suspended_at, cancelled_at"),
      admin.from("spam_settings").select("business_id, enabled, call_screening, updated_at"),
      admin.from("platform_alerts").select("id, kind, title, detail, business_id, occurrences, last_seen_at, status").in("kind", ["spam_flood", "call_volume_spike"]).neq("status", "resolved").order("last_seen_at", { ascending: false }).limit(50),
    ]);
    if (bErr) throw bErr;
    if (sErr) throw sErr;
    if (aErr) throw aErr;
    const names = new Map((businesses ?? []).map((b) => [b.id, b.name]));
    const settingBy = new Map((settings ?? []).map((x) => [x.business_id, x]));
    const live = (businesses ?? []).filter((b) => !b.cancelled_at);
    const confirmed = count((r) => r.status === "confirmed_spam");
    const fp = count((r) => r.status === "false_positive");
    return {
      available: true,
      totals: {
        incidents: rows?.length ?? 0, open: count((r) => ["new", "under_review", "escalated"].includes(r.status as string)), high: count((r) => r.risk_level === "high"),
        confirmed, false_positive: fp, blocked: count((r) => ["blocked", "restricted", "screened"].includes(r.action as string)),
        occurrences: (rows ?? []).reduce((n, r) => n + (r.occurrences ?? 0), 0),
        accuracy: confirmed + fp ? Math.round((confirmed / (confirmed + fp)) * 100) : null,
      },
      by_channel: Object.fromEntries(["call", "sms", "email", "booking", "web", "other"].map((c) => [c, count((r) => r.channel === c)])),
      top: [...byBiz.entries()].sort((a, b) => b[1].total - a[1].total).slice(0, 10).map(([id, v]) => ({ business_id: id, name: names.get(id) ?? "Deleted business", ...v })),
      coverage: live.map((b) => {
        const st = settingBy.get(b.id);
        return { business_id: b.id, name: b.name, status: b.onboarding_status, suspended: Boolean(b.suspended_at),
                 protection: st ? (st.enabled ? "on" : "off") : "default_on", call_screening: st?.call_screening ?? "flag", updated_at: st?.updated_at ?? null };
      }),
      alerts: (alerts ?? []).map((a) => ({ ...a, business_name: a.business_id ? names.get(a.business_id) ?? null : null })),
      policy: obj((await admin.from("platform_settings").select("value").eq("key", "spam_defaults").maybeSingle()).data?.value),
      automation: await spamAutomation(from),
    };
  };

  // The Spam Response workflow: is it on, what's waiting, when the dispatcher last called it. Counts only.
  const spamAutomation = async (from: string) => {
    const keys = ["spam_workflow_live", "spam_ai_live", "spam_ai_model", "spam_ai_monthly_limit", "n8n_base_url"];
    const [{ data: settings }, { data: queue, error: qErr }, { data: dispatch }] = await Promise.all([
      admin.from("platform_settings").select("key, value").in("key", keys),
      admin.from("spam_incidents").select("workflow_status, workflow_result").gte("first_seen_at", from).neq("workflow_status", "not_needed").limit(20000),
      admin.from("n8n_dispatch_state").select("last_triggered_at, triggers_total, consecutive_same").eq("workflow", "spam-response").maybeSingle(),
    ]);
    if (qErr) return { available: false };   // the workflow columns come with the current zella_spam_protection.sql
    const v = new Map((settings ?? []).map((x) => [x.key, x.value]));
    const by = (st: string) => (queue ?? []).filter((r) => r.workflow_status === st).length;
    return {
      available: true,
      live: v.get("spam_workflow_live") === true, ai_live: v.get("spam_ai_live") === true,
      ai_model: typeof v.get("spam_ai_model") === "string" ? v.get("spam_ai_model") : null,
      ai_monthly_limit: Number(v.get("spam_ai_monthly_limit") ?? 200),
      n8n_connected: typeof v.get("n8n_base_url") === "string" && Boolean(v.get("n8n_base_url")),
      queue: { pending: by("pending"), processing: by("processing"), done: by("done"), failed: by("failed"),
               ai_reviewed: (queue ?? []).filter((r) => obj(r.workflow_result).ai).length,
               fallback: (queue ?? []).filter((r) => obj(r.workflow_result).fallback_notified === true).length },
      last_run: dispatch?.last_triggered_at ?? null, runs_total: dispatch?.triggers_total ?? 0,
    };
  };

  const spamAdminAutomationSave = async () => {
    const input = obj(fields.automation);
    const { data: cur, error } = await admin.from("platform_settings").select("key, value").in("key", ["spam_workflow_live", "spam_ai_live", "spam_ai_monthly_limit"]);
    if (error) throw error;
    const before = Object.fromEntries((cur ?? []).map((x) => [x.key, x.value]));
    const next: Json = {};
    if ("live" in input) next.spam_workflow_live = bool(input.live);
    if ("ai_live" in input) next.spam_ai_live = bool(input.ai_live);
    if ("ai_monthly_limit" in input) {
      const n = Math.round(Number(input.ai_monthly_limit));
      if (!Number.isFinite(n) || n < 0 || n > 10000) throw new InputError("AI reviews per business per month must be between 0 and 10000");
      next.spam_ai_monthly_limit = n;
    }
    if (!Object.keys(next).length) throw new InputError("Nothing to change");
    const now = new Date().toISOString();
    const { error: upError } = await admin.from("platform_settings").upsert(Object.entries(next).map(([key, value]) => ({ key, value, updated_at: now })), { onConflict: "key" });
    if (upError) throw upError;
    return { before, after: next };
  };

  const spamAdminIncidents = async () => {
    const page = Math.max(0, Math.floor(Number(fields.page) || 0));
    let q = admin.from("spam_incidents").select("id, business_id, channel, sender, risk_score, risk_level, reasons, action, status, occurrences, first_seen_at, last_seen_at", { count: "exact" })
      .gte("last_seen_at", since()).order("last_seen_at", { ascending: false }).range(page * 50, page * 50 + 49);
    const businessId = text(fields.businessId, 64);
    if (businessId) q = q.eq("business_id", requireId(businessId));
    for (const [key, allowed] of [["channel", ["call", "sms", "email", "booking", "web", "other"]], ["status", ["new", "under_review", "confirmed_spam", "false_positive", "resolved", "escalated"]], ["risk_level", ["high", "medium", "low"]]] as const) {
      const v = text(fields[key], 20);
      if (v) { if (!(allowed as readonly string[]).includes(v)) throw new InputError(`Unknown ${key}`); q = q.eq(key, v); }
    }
    const { data, error, count } = await q;
    if (error) { if (spamMissing(error)) return { available: false, rows: [], total: 0 }; throw error; }
    const ids = [...new Set((data ?? []).map((r) => r.business_id))];
    const { data: names } = ids.length ? await admin.from("businesses").select("id, name").in("id", ids) : { data: [] };
    const byId = new Map((names ?? []).map((b) => [b.id, b.name]));
    return { available: true, total: count ?? 0, page,
      rows: (data ?? []).map((r) => ({ ...r, sender: mask(r.sender), business_name: byId.get(r.business_id) ?? "Deleted business" })) };
  };

  const spamAdminIncident = async () => {
    const id = requireId(fields.incidentId, "incident");
    const [{ data: inc, error }, { data: events, error: evError }] = await Promise.all([
      admin.from("spam_incidents").select("id, business_id, channel, sender, risk_score, risk_level, reasons, action, status, occurrences, first_seen_at, last_seen_at").eq("id", id).maybeSingle(),
      admin.from("spam_incident_events").select("kind, actor, from_status, to_status, note, detail, created_at").eq("incident_id", id).order("created_at").limit(200),
    ]);
    if (error) throw error;
    if (evError) throw evError;
    if (!inc) throw new InputError("Incident not found", 404);
    // Notes are the business's own; platform admins see that a note exists, not what it says.
    return { incident: { ...inc, sender: mask(inc.sender) },
      events: (events ?? []).map((e) => ({ kind: e.kind, from_status: e.from_status, to_status: e.to_status, has_note: Boolean(e.note), by_team: Boolean(e.actor), created_at: e.created_at,
        detail: e.kind === "listed" || e.kind === "unlisted" ? { list: obj(e.detail).list, channel: obj(e.detail).channel } : {} })) };
  };

  const spamAdminPolicySave = async () => {
    const input = obj(fields.policy);
    const { data: cur, error } = await admin.from("platform_settings").select("value").eq("key", "spam_defaults").maybeSingle();
    if (error) throw error;
    const before = obj(cur?.value);
    const next: Json = { ...before };
    for (const [k, [lo, hi]] of Object.entries(SPAM_POLICY_LIMITS)) {
      if (!(k in input)) continue;
      const n = Math.round(Number(input[k]));
      if (!Number.isFinite(n) || n < lo || n > hi) throw new InputError(`${k.replace(/_/g, " ")} must be between ${lo} and ${hi}`);
      next[k] = n;
    }
    if (Number(next.medium_score) >= Number(next.high_score)) throw new InputError("The medium risk score must be below the high risk score");
    const { error: upError } = await admin.from("platform_settings").upsert({ key: "spam_defaults", value: next, updated_at: new Date().toISOString() }, { onConflict: "key" });
    if (upError) throw upError;
    return { before, after: next };
  };

  const spamAdminRuleAdd = async () => {
    const raw = text(fields.value, 254).toLowerCase();
    const channel = text(fields.channel, 10);
    if (!["call", "sms", "email", "booking", "all"].includes(channel)) throw new InputError("Choose a channel");
    let type: string; let value: string;
    if (/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/.test(raw)) { type = "email"; value = raw; }
    else if (/^@?[a-z0-9.-]+\.[a-z]{2,}$/.test(raw)) { type = "domain"; value = raw.replace(/^@/, ""); }
    else { const digits = raw.replace(/\D/g, "").slice(-10); if (digits.length < 7) throw new InputError("Enter a phone number, an email address or a domain"); type = "phone"; value = digits; }
    if ((type === "phone" && channel === "email") || (type !== "phone" && ["call", "sms"].includes(channel))) throw new InputError("Phone numbers go with calls or texts, and addresses with email");
    const reason = text(fields.reason, 300);
    if (!reason) throw new InputError("Give a reason: platform rules affect every business");
    const hours = fields.hours ? Math.round(Number(fields.hours)) : null;
    if (hours !== null && (!Number.isFinite(hours) || hours < 1 || hours > 8760)) throw new InputError("Duration must be 1 hour to 1 year");
    const { data, error } = await admin.from("spam_list_entries").insert({
      business_id: null, list: "block", channel, value_type: type, value, reason, source: "manual", created_by: kitUser,
      expires_at: hours ? new Date(Date.now() + hours * 3600e3).toISOString() : null,
    }).select("id, channel, value_type, value, reason, expires_at, created_at").single();
    if (error) { if (/duplicate|unique/i.test(error.message)) throw new InputError("That rule already exists", 409); throw error; }
    return { rule: data };
  };

  const spamAdminRuleRemove = async () => {
    const id = requireId(fields.ruleId, "rule");
    const { data, error } = await admin.from("spam_list_entries").update({ removed_at: new Date().toISOString(), removed_by: kitUser })
      .eq("id", id).is("business_id", null).is("removed_at", null).select("id, channel, value_type").maybeSingle();
    if (error) throw error;
    if (!data) throw new InputError("Rule not found (business lists can only be changed by that business)", 404);
    return { rule: data };
  };

  const spamAdminRules = async () => {
    const { data, error } = await admin.from("spam_list_entries").select("id, channel, value_type, value, reason, expires_at, created_at").is("business_id", null).is("removed_at", null).order("created_at", { ascending: false }).limit(500);
    if (error) { if (spamMissing(error)) return { available: false, rules: [] }; throw error; }
    return { available: true, rules: data ?? [] };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    spam_admin_overview: spamAdminOverview,
    spam_admin_incidents: spamAdminIncidents,
    spam_admin_incident: spamAdminIncident,
    spam_admin_policy_save: spamAdminPolicySave,
    spam_admin_rule_add: spamAdminRuleAdd,
    spam_admin_rule_remove: spamAdminRuleRemove,
    spam_admin_rules: spamAdminRules,
    spam_admin_automation_save: spamAdminAutomationSave,
    industry_records_get: industryRecordsGet,
    industry_records_save: industryRecordsSave,
    business_records_get: businessRecordsGet,
    business_records_save: businessRecordsSave,
    documents_queue: documentsQueue,
  };

  const audited: Record<string, (r: Json) => Json> = {
    industry_records_save: (r) => ({ action: r.created ? "industry.records_created" : "industry.records_updated", entity_type: "industry", entity_id: r.industryId, old_data: { preset: r.presetKey, types: r.before }, new_data: { preset: r.presetKey, types: r.after } }),
    spam_admin_policy_save: (r) => ({ action: "platform.spam_policy_updated", entity_type: "platform_setting", old_data: r.before as Json, new_data: r.after as Json }),
    spam_admin_rule_add: (r) => ({ action: "platform.spam_rule_added", entity_type: "spam_list_entry", entity_id: obj(r.rule).id, new_data: { channel: obj(r.rule).channel, type: obj(r.rule).value_type, reason: obj(r.rule).reason, expires_at: obj(r.rule).expires_at } }),
    spam_admin_automation_save: (r) => ({ action: "platform.spam_automation_updated", entity_type: "platform_setting", old_data: r.before as Json, new_data: r.after as Json }),
    spam_admin_rule_remove: (r) => ({ action: "platform.spam_rule_removed", entity_type: "spam_list_entry", entity_id: obj(r.rule).id, old_data: { channel: obj(r.rule).channel, type: obj(r.rule).value_type } }),
    business_records_save: (r) => ({ action: "business.record_types_updated", business_id: r.businessId, entity_type: "business", entity_id: r.businessId, new_data: { changes: r.changes } }),
  };

  return { handlers, audited };
}
