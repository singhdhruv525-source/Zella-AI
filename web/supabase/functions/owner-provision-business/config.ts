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
};

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

export function configHandlers(admin: SupabaseClient, fields: Json, kit: ConfigKit) {
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

  const handlers: Record<string, () => Promise<unknown>> = {
    agent_deliveries: agentDeliveries,
    industry_module_usage: industryModuleUsage,
    industry_set_active: industrySetActive,
  };

  // Returning null skips the audit row (a repeat click that changed nothing).
  const audited: Record<string, (r: Json) => Json | null> = {
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
