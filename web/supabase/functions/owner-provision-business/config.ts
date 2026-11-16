// Admin dashboard, Lane C: industry configuration, plans, AI agents and connection state.
//
// Every action runs after index.ts has checked the caller's sign in, platform role, two step sign in and the
// permission listed in CONFIG_PERMISSIONS. Audit entries for these actions are described in configHandlers' audited
// map, and index.ts writes them after the action succeeds.

import type { SupabaseClient } from "@supabase/supabase-js";

type Json = Record<string, unknown>;

export type ConfigKit = {
  text: (v: unknown, max?: number) => string;
  bool: (v: unknown, fallback?: boolean) => boolean;
  obj: (v: unknown) => Json;
  requireId: (v: unknown, label?: string) => string;
  InputError: new (message: string, status?: number) => Error;
};

export const CONFIG_PERMISSIONS: Record<string, string> = {
  industry_module_usage: "businesses.view",
  industry_set_active: "platform.configure",
  agent_deliveries: "businesses.view",
  business_plans_list: "billing.view",
  industry_set_sensitive: "platform.configure",
  industry_automation_defaults: "businesses.view",
};

// CFG-05: industry data stored in the database (sql/zella_industry_data.sql).
export const BOOKING_MODELS = ["staff_appointment", "class", "table", "stay", "consultation", "viewing", "field_job", "none", "general"] as const;
// Only a Zella Voice owner may change whether an industry is sensitive (CFG-05 decision, owner can change).
export const SENSITIVE_ROLE = "zella_owner";

// The columns may not exist yet (migration not applied): callers then leave the industry data out.
export const missingColumn = (error: { code?: string; message?: string } | null) =>
  Boolean(error && (error.code === "42703" || error.code === "PGRST204" || /column .* does not exist|Could not find the .* column/i.test(error.message ?? "")));

const AUTOMATION_KEY = /^[a-z][a-z0-9_]{0,39}$/;
type Setting = string | number | boolean | number[];
// A default automations object as industry_configurations.automation_defaults stores it:
// { type: { enabled: boolean, settings: { key: number | string | boolean | number[] } } }. Anything else is refused.
export function cleanAutomationDefaults(input: unknown, InputError: new (m: string, s?: number) => Error): Record<string, { enabled: boolean; settings: Record<string, Setting> }> | null {
  if (input === null) return null;
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new InputError("Default automations must be a list of automations");
  const out: Record<string, { enabled: boolean; settings: Record<string, Setting> }> = {};
  const entries = Object.entries(input as Json);
  if (entries.length > 40) throw new InputError("Too many default automations");
  for (const [type, raw] of entries) {
    const v = raw as Json;
    if (!AUTOMATION_KEY.test(type) || !v || typeof v !== "object" || typeof v.enabled !== "boolean") throw new InputError(`Default automation ${type} isn't valid`);
    const settings: Record<string, Setting> = {};
    for (const [k, x] of Object.entries((v.settings && typeof v.settings === "object" && !Array.isArray(v.settings)) ? v.settings as Json : {})) {
      const okValue = (typeof x === "number" && Number.isFinite(x)) || typeof x === "boolean" || (typeof x === "string" && x.length <= 40)
        || (Array.isArray(x) && x.length <= 10 && x.every((n) => typeof n === "number" && Number.isFinite(n)));
      if (!AUTOMATION_KEY.test(k) || !okValue) throw new InputError(`A setting of ${type} isn't valid`);
      settings[k] = x as Setting;
    }
    out[type] = { enabled: v.enabled, settings };
  }
  return out;
}

// CFG-14: the Plans page lists businesses a page at a time (CFG-21), each with its own plan (business_plans).
export const PLANS_PAGE_SIZE = 25;
const PLANS_PAGE_MAX = 100;

type PlanRow = {
  business_id: string; version: number; tier: string; billing_interval: string; price_cents: number; setup_fee_cents: number;
  currency: string; minutes: number; texts: number; emails: number; team_seats: number; phone_numbers: number; locations: number;
  languages: string[]; trial_enabled: boolean; overage_cents_per_minute: number | null; effective_from: string;
};

// The latest version per business, how many versions it has, from rows of any order.
export function latestPlans(rows: PlanRow[]) {
  const out = new Map<string, { plan: PlanRow; versions: number }>();
  for (const row of rows) {
    const seen = out.get(row.business_id);
    if (!seen) out.set(row.business_id, { plan: row, versions: 1 });
    else out.set(row.business_id, { plan: row.version > seen.plan.version ? row : seen.plan, versions: seen.versions + 1 });
  }
  return out;
}

// CFG-01 deploy window. The web app that sends confirmOff deploys first. An older app that doesn't send the field at
// all is still allowed to switch a used module off, so it keeps working until every open tab has reloaded. Set this to
// false in a later change, once the new web app is live, to make the confirmation a hard server rule.
export const LEGACY_SWITCH_OFF_ALLOWED = true;

// PostgREST returns at most max_rows rows (1000 on Supabase) per request, so every count here reads in pages and
// keeps going until a page comes back empty. A lower max_rows only means more pages, never a wrong count.
const PAGE = 1000;
const MAX_PAGES = 500;

// deno-lint-ignore no-explicit-any
type PageQuery = (from: number, to: number) => PromiseLike<{ data: any[] | null; error: unknown }>;

export async function allRows<T = Json>(query: PageQuery): Promise<T[]> {
  const rows: T[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const { data, error } = await query(rows.length, rows.length + PAGE - 1);
    if (error) throw error;
    if (!data?.length) return rows;
    rows.push(...(data as T[]));
  }
  throw new Error("Too many rows to count");
}

// How many businesses have each of an industry's modules switched on, by the same rule zella_module_on uses
// (sql/zella_navigation.sql): the business_modules row is enabled and the business is in the module's industry. The
// module's own is_active is left out on purpose: the count says who would lose the module if it were switched off.
export async function moduleUsage(admin: SupabaseClient, industryId: string, moduleIds: string[]) {
  const usage = new Map<string, number>(moduleIds.map((id) => [id, 0]));
  if (!moduleIds.length) return usage;
  const [businesses, enabled] = await Promise.all([
    allRows<{ id: string }>((from, to) =>
      admin.from("businesses").select("id").eq("industry_id", industryId).order("id").range(from, to)
    ),
    allRows<{ business_id: string; module_id: string }>((from, to) =>
      admin.from("business_modules").select("business_id, module_id").in("module_id", moduleIds).eq("enabled", true)
        .order("id").range(from, to)
    ),
  ]);
  const inIndustry = new Set(businesses.map((b) => b.id));
  for (const row of enabled) {
    if (inIndustry.has(row.business_id) && usage.has(row.module_id)) {
      usage.set(row.module_id, (usage.get(row.module_id) ?? 0) + 1);
    }
  }
  return usage;
}

// COM-01, OPS-07, UI-02: one definition of connected, answering and live, in SQL (sql/zella_connection_state.sql,
// docs/PRODUCT.md "Connected, answering and live"). Every page asks these two helpers; none works it out itself.
export type Connection = {
  business_id: string; business_state: string; receptionist: string; phone: boolean; phone_numbers: number;
  vapi_linked: boolean; answering: boolean; last_served_at: string | null; calendar: boolean; leads: boolean;
  lead_sources: string[]; email: "not_tracked"; problems: number; live: boolean;
};

// Only "this function doesn't exist": an error raised inside it (a missing table, a refusal) is never hidden.
const missingFunction = (error: { code?: string } | null) => Boolean(error && (error.code === "PGRST202" || error.code === "42883"));

// null when the migration isn't applied yet: pages then say the state isn't available instead of guessing.
export async function connectionsFor(admin: SupabaseClient, businessIds: string[]): Promise<Map<string, Connection> | null> {
  const ids = [...new Set(businessIds)];
  const out = new Map<string, Connection>();
  for (let i = 0; i < ids.length; i += 1000) {
    const { data, error } = await admin.rpc("zella_business_connections", { p_business_ids: ids.slice(i, i + 1000) });
    if (missingFunction(error)) return null;
    if (error) throw error;
    for (const row of (data ?? []) as Connection[]) out.set(row.business_id, row);
  }
  return out;
}

export type ConnectionCounts = {
  businesses: number; active: number; receptionists_active: number; phone: number; vapi_linked: number; answering: number;
  calendar: number; leads: number; live: number; problems: number; email: "not_tracked";
};

export async function connectionCounts(admin: SupabaseClient): Promise<ConnectionCounts | null> {
  const { data, error } = await admin.rpc("zella_connection_counts");
  if (missingFunction(error)) return null;
  if (error) throw error;
  return data as ConnectionCounts;
}

// COM-03: what calls actually got (assistant_deliveries), aggregated in SQL (sql/zella_agent_delivery_admin.sql).
export type DeliverySummary = {
  business_id: string; last_outcome: string | null; last_at: string | null; served_7d: number; not_ready_7d: number;
  unknown_number_7d: number; forwarded_usage_7d: number; last_problems: unknown[] | null; last_problem_at: string | null;
  served_version: number | null; published_version: number | null; published_sync_status: string | null;
  published_sync_error: string | null;
};

export async function deliveriesFor(admin: SupabaseClient, businessIds: string[]): Promise<Map<string, DeliverySummary> | null> {
  const ids = [...new Set(businessIds)];
  const out = new Map<string, DeliverySummary>();
  for (let i = 0; i < ids.length; i += 1000) {
    const { data, error } = await admin.rpc("zella_admin_agent_deliveries_summary", { p_business_ids: ids.slice(i, i + 1000) });
    if (missingFunction(error)) return null;
    if (error) throw error;
    for (const row of (data ?? []) as DeliverySummary[]) out.set(row.business_id, row);
  }
  return out;
}

export type SwitchOff = { id: string; name: string; businesses: number };

// Which modules this save switches off while businesses still have them on, and whether the save may go ahead.
// confirmOff is the list of module ids the admin confirmed in the "N businesses lose X" dialog. When it is missing
// entirely the request comes from an older web app (see LEGACY_SWITCH_OFF_ALLOWED).
export function switchOffCheck(
  current: { id: string; name: string; is_active: boolean }[],
  requested: { id: string; isActive: boolean }[],
  usage: Map<string, number>,
  confirmOff: unknown,
  legacyAllowed = LEGACY_SWITCH_OFF_ALLOWED,
) {
  const byId = new Map(current.map((m) => [m.id, m]));
  const switchedOff: SwitchOff[] = [];
  for (const r of requested) {
    const before = byId.get(r.id);
    if (before?.is_active && !r.isActive) {
      switchedOff.push({ id: r.id, name: before.name, businesses: usage.get(r.id) ?? 0 });
    }
  }
  const used = switchedOff.filter((m) => m.businesses > 0);
  const legacy = confirmOff === undefined || confirmOff === null;
  const confirmed = new Set(Array.isArray(confirmOff) ? confirmOff.filter((v) => typeof v === "string") : []);
  const unconfirmed = legacy && legacyAllowed ? [] : used.filter((m) => !confirmed.has(m.id));
  return { switchedOff, unconfirmed, legacy };
}

export function switchOffMessage(unconfirmed: SwitchOff[]) {
  const parts = unconfirmed.map((m) => `${m.businesses} ${m.businesses === 1 ? "business loses" : "businesses lose"} ${m.name}`);
  return `Switching this off removes it from businesses that use it now: ${parts.join("; ")}. Confirm to continue.`;
}

export function configHandlers(admin: SupabaseClient, fields: Json, kit: ConfigKit, role: string | null = null) {
  const { text, requireId, InputError } = kit;

  const industryOf = async (id: string) => {
    const { data, error } = await admin.from("industries").select("id, name, is_active").eq("id", id).maybeSingle();
    if (error) throw error;
    if (!data) throw new InputError("Industry not found", 404);
    return data as { id: string; name: string; is_active: boolean };
  };

  // CFG-01: per module business counts for one industry, read when the admin opens it.
  const industryModuleUsage = async () => {
    const industryId = requireId(fields.industryId, "industry");
    await industryOf(industryId);
    const { data, error } = await admin.from("industry_modules").select("id").eq("industry_id", industryId);
    if (error) throw error;
    const ids = (data ?? []).map((m: { id: string }) => m.id);
    const usage = await moduleUsage(admin, industryId, ids);
    return { industryId, modules: Object.fromEntries(usage) };
  };

  // CFG-08: deactivate or reactivate an industry. Inactive industries aren't offered when a business is created
  // (zella_create_business_draft refuses them); businesses already in the industry keep working, because nothing else
  // reads industries.is_active. Rename and delete stay out: presets and default automations match on the name.
  const industrySetActive = async () => {
    const industryId = requireId(fields.industryId, "industry");
    if (typeof fields.active !== "boolean") throw new InputError("Say whether the industry should be active");
    const reason = text(fields.reason, 300);
    if (reason.length < 3) throw new InputError("Give a short reason (it goes in the audit log)");
    const industry = await industryOf(industryId);
    const active = fields.active;
    const { count, error: countError } = await admin.from("businesses").select("id", { count: "exact", head: true })
      .eq("industry_id", industryId);
    if (countError) throw countError;
    if (industry.is_active !== active) {
      const { error } = await admin.from("industries").update({ is_active: active }).eq("id", industryId);
      if (error) throw error;
    }
    return { industryId, name: industry.name, before: industry.is_active, after: active, changed: industry.is_active !== active, reason, businesses: count ?? 0 };
  };

  // COM-03: one business's recent deliveries, for the AI agents drawer. Read only, not audited.
  const agentDeliveries = async () => {
    const businessId = requireId(fields.businessId);
    const limit = Number.isInteger(fields.limit) ? Number(fields.limit) : 25;
    const { data, error } = await admin.rpc("zella_admin_agent_deliveries", { p_business_id: businessId, p_limit: limit });
    if (missingFunction(error)) return { available: false, businessId, deliveries: [] };
    if (error) {
      if (/BUSINESS_NOT_FOUND/.test(error.message ?? "")) throw new InputError("Business not found", 404);
      throw error;
    }
    return { available: true, businessId, ...(data as Json) };
  };

  // CFG-14, CFG-21: businesses a page at a time, each with its latest plan version, how many versions it has, and its
  // subscription status. Read with the server key (business_plans has no read policy); billing.view is checked first.
  // Nothing here charges anyone: payments aren't connected.
  const businessPlansList = async () => {
    const offset = Number.isInteger(fields.offset) && Number(fields.offset) >= 0 ? Number(fields.offset) : 0;
    const limit = Number.isInteger(fields.limit) ? Math.min(Math.max(Number(fields.limit), 1), PLANS_PAGE_MAX) : PLANS_PAGE_SIZE;
    const search = text(fields.search, 80).replace(/[%_,()*\\]/g, " ").trim();
    let page = admin.from("businesses").select("id, name, onboarding_status, is_active, suspended_at, cancelled_at", { count: "exact" })
      .order("name").order("id");
    if (search) page = page.ilike("name", `%${search}%`);
    const [{ data: businesses, count, error }, { count: withPlan, error: withPlanError }] = await Promise.all([
      page.range(offset, offset + limit - 1),
      admin.from("business_plans").select("business_id", { count: "exact", head: true }).eq("version", 1),   // one version 1 per business
    ]);
    if (error) throw error;
    if (withPlanError) throw withPlanError;
    const ids = (businesses ?? []).map((b: { id: string }) => b.id);
    const [plans, subs] = ids.length ? await Promise.all([
      allRows<PlanRow>((from, to) => admin.from("business_plans")
        .select("business_id, version, tier, billing_interval, price_cents, setup_fee_cents, currency, minutes, texts, emails, team_seats, phone_numbers, locations, languages, trial_enabled, overage_cents_per_minute, effective_from")
        .in("business_id", ids).order("business_id").order("version").range(from, to)),
      allRows<{ business_id: string; status: string; trial_end_at: string | null; current_period_end: string | null; provider: string | null }>((from, to) =>
        admin.from("subscriptions").select("business_id, status, trial_end_at, current_period_end, provider, created_at")
          .in("business_id", ids).order("created_at", { ascending: false }).range(from, to)),
    ]) : [[], []];
    const latest = latestPlans(plans);
    const subscription = new Map<string, (typeof subs)[number]>();
    for (const s of subs) if (!subscription.has(s.business_id)) subscription.set(s.business_id, s);   // newest first
    return {
      total: count ?? 0, withPlan: withPlan ?? 0, offset, limit, search: search || null,
      businesses: (businesses ?? []).map((b: Json) => {
        const l = latest.get(String(b.id)); const sub = subscription.get(String(b.id));
        return {
          businessId: b.id, businessName: b.name,
          businessState: b.cancelled_at ? "cancelled" : b.suspended_at ? "suspended" : b.onboarding_status === "active" && b.is_active ? "active" : "setup",
          plan: l ? {
            version: l.plan.version, versions: l.versions, tier: l.plan.tier, billingInterval: l.plan.billing_interval,
            priceCents: l.plan.price_cents, setupFeeCents: l.plan.setup_fee_cents, currency: l.plan.currency,
            minutes: l.plan.minutes, texts: l.plan.texts, emails: l.plan.emails, teamSeats: l.plan.team_seats,
            phoneNumbers: l.plan.phone_numbers, locations: l.plan.locations, languages: l.plan.languages,
            trialEnabled: l.plan.trial_enabled, overageCentsPerMinute: l.plan.overage_cents_per_minute, effectiveFrom: l.plan.effective_from,
          } : null,
          subscription: sub ? { status: sub.status, trialEndAt: sub.trial_end_at, currentPeriodEnd: sub.current_period_end, provider: sub.provider } : null,
        };
      }),
    };
  };

  // CFG-05: whether staff may read call transcripts in this industry (M-4). Zella Voice owner only, with a reason;
  // turning it off also needs confirm: true, because staff may then read transcripts. Audited.
  const industrySetSensitive = async () => {
    if (role !== SENSITIVE_ROLE) throw new InputError("Only a Zella Voice owner can change whether an industry is sensitive.", 403);
    const industryId = requireId(fields.industryId, "industry");
    if (typeof fields.sensitive !== "boolean") throw new InputError("Say whether the industry is sensitive");
    const reason = text(fields.reason, 300);
    if (reason.length < 3) throw new InputError("Give a short reason (it goes in the audit log)");
    const { data, error } = await admin.from("industries").select("id, name, sensitive").eq("id", industryId).maybeSingle();
    if (missingColumn(error)) throw new InputError("Industry data isn't switched on yet", 409);
    if (error) throw error;
    if (!data) throw new InputError("Industry not found", 404);
    const before = Boolean((data as Json).sensitive);
    if (before && !fields.sensitive && fields.confirm !== true) {
      throw new InputError("Turning this off lets staff read call transcripts in this industry. Confirm to continue.", 409);
    }
    if (before !== fields.sensitive) {
      const { error: e } = await admin.from("industries").update({ sensitive: fields.sensitive }).eq("id", industryId);
      if (e) throw e;
    }
    return { industryId, name: (data as Json).name, before, after: fields.sensitive, changed: before !== fields.sensitive, reason };
  };

  // CFG-05, UI-28: the automations a new business in this industry starts with, from the database. null means the
  // base set (web/src/industryAutomations.js), also when the migration isn't applied yet.
  const industryAutomationDefaults = async () => {
    const industryId = requireId(fields.industryId, "industry");
    const { data, error } = await admin.from("industry_configurations").select("automation_defaults").eq("industry_id", industryId).maybeSingle();
    if (missingColumn(error)) return { industryId, available: false, defaults: null };
    if (error) throw error;
    return { industryId, available: true, defaults: (data as Json | null)?.automation_defaults ?? null };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    industry_set_sensitive: industrySetSensitive,
    industry_automation_defaults: industryAutomationDefaults,
    business_plans_list: businessPlansList,
    agent_deliveries: agentDeliveries,
    industry_module_usage: industryModuleUsage,
    industry_set_active: industrySetActive,
  };

  // Returning null skips the audit row (a repeat click that changed nothing).
  const audited: Record<string, (r: Json) => Json | null> = {
    industry_set_sensitive: (r) => r.changed
      ? {
        action: r.after ? "industry.sensitive_on" : "industry.sensitive_off",
        entity_type: "industry", entity_id: r.industryId,
        old_data: { name: r.name, sensitive: r.before }, new_data: { name: r.name, sensitive: r.after, reason: r.reason },
      }
      : null,
    industry_set_active: (r) => r.changed
      ? {
        action: r.after ? "industry.reactivated" : "industry.deactivated",
        entity_type: "industry",
        entity_id: r.industryId,
        old_data: { name: r.name, is_active: r.before },
        new_data: { name: r.name, is_active: r.after, reason: r.reason, businesses_in_industry: r.businesses },
      }
      : null,
  };

  return { handlers, audited };
}
