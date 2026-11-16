// The admin Business detail page (/businesses/<id>): what one admin may see and do there.
//
// index.ts checks each action's permission before it runs (the permission lookup and the role grant there); this module
// adds what the page itself needs on top: the full permission set of the signed in admin, so business_detail can leave
// out what the admin may not read (activity without audit.view) and the web app can hide what they can't use.
// New actions for this page are listed in DETAIL_PERMISSIONS and joined to index.ts with one lookup line, like
// platform.ts.

import type { SupabaseClient } from "@supabase/supabase-js";
import { PERMISSION_CATALOG, RESTRICTED_ROLES } from "./settings.ts";
import { mask, maskText } from "./mask.ts";

// What business_detail borrows from index.ts (passed in, so this module has no import cycle and can be tested).
export type DetailDeps = {
  // deno-lint-ignore no-explicit-any
  loadSetup: (admin: SupabaseClient, businessId: string) => Promise<any>;
};

type Row = Record<string, unknown>;

// Permission each action of this module needs (index.ts: `?? DETAIL_PERMISSIONS[action]`).
export const DETAIL_PERMISSIONS: Record<string, string> = {
  business_size_save: "businesses.manage",   // BIZ-08: was a browser RPC open to owner and super admin only
};

// What index.ts lends this module's handlers (the same helpers platform.ts gets).
export type DetailKit = {
  text: (v: unknown, max?: number) => string;
  requireId: (v: unknown, label?: string) => string;
  InputError: new (message: string, status?: number) => Error;
};

type Audit = { action: string; business_id?: string | null; entity_type?: string | null; entity_id?: string | null; old_data?: Row | null; new_data?: Row | null };

export const BUSINESS_SIZES = ["small", "medium", "large"] as const;

// This page's actions. Each returns what the page shows; `audited` says what each records (null records nothing).
export function detailHandlers(admin: SupabaseClient, fields: Row, k: DetailKit) {
  const handlers: Record<string, () => Promise<unknown>> = {
    // BIZ-08: Small, Medium or Large (or not set), set by an admin and used by offers. Saved only if nobody changed it
    // since the page loaded it, so the audit's before value is the real one.
    business_size_save: async () => {
      const businessId = k.requireId(fields.businessId);
      const raw = fields.size === null || fields.size === "" ? null : k.text(fields.size, 20);
      if (raw !== null && !(BUSINESS_SIZES as readonly string[]).includes(raw)) throw new k.InputError("Choose Small, Medium, Large or Not set");
      const { data: current, error } = await admin.from("businesses").select("id, business_size").eq("id", businessId).maybeSingle();
      if (error) throw error;
      if (!current) throw new k.InputError("Business not found", 404);
      const before = (current.business_size as string | null) ?? null;
      if (before === raw) return { businessId, size: raw, before, changed: false };
      const update = admin.from("businesses").update({ business_size: raw, updated_at: new Date().toISOString() }).eq("id", businessId);
      const { data: rows, error: updateError } = await (before === null ? update.is("business_size", null) : update.eq("business_size", before)).select("id");
      if (updateError) throw updateError;
      if (!rows?.length) throw new k.InputError("The size was changed by someone else meanwhile. Reload the page and try again.", 409);
      return { businessId, size: raw, before, changed: true };
    },
  };
  const audited: Record<string, (r: Row) => Audit | null> = {
    business_size_save: (r) => r.changed
      ? { action: "business.size_changed", business_id: r.businessId as string, entity_type: "business", entity_id: r.businessId as string,
        old_data: { size: r.before ?? null }, new_data: { size: r.size ?? null } }
      : null,
  };
  return { handlers, audited };
}

const OWNER_ONLY = ["admins.manage", "roles.manage"];

// Everything the admin's role may do, worked out exactly as index.ts decides each action:
// - zella_owner: every permission;
// - super_admin: every permission except managing admins and roles;
// - a restricted role: only what the owner granted it in platform_role_permissions;
// - anything else: nothing.
// A failed lookup grants nothing (fails closed).
export async function adminPermissions(admin: SupabaseClient, role: string): Promise<Set<string>> {
  const catalog = PERMISSION_CATALOG.map(([p]) => p);
  if (role === "zella_owner") return new Set([...catalog, ...OWNER_ONLY]);
  if (role === "super_admin") return new Set(catalog);
  if (!RESTRICTED_ROLES.includes(role)) return new Set();
  const { data, error } = await admin.from("platform_role_permissions").select("permission").eq("role", role);
  if (error) {
    console.error("Permission lookup failed", error);
    return new Set();
  }
  return new Set(((data ?? []) as { permission: string }[]).map((r) => r.permission));
}

// Defaults taken for this page (owner can change; listed in the PR):
// - prices on the plan card only with billing.view (BIZ-11);
// - the activation report (go live checklist) only with businesses.manage, as the audit item reads it (BIZ-12);
// - each member's last sign in and two step status only with businesses.manage, until BIZ-22 is decided (UI-06).
export const PRICES_PERMISSION = "billing.view";
export const ACTIVATION_PERMISSION = "businesses.manage";
export const SIGN_IN_FACTS_PERMISSION = "businesses.manage";
// Every list on the page is capped, so one large business can't make the page slow.
export const DETAIL_LIMITS = { numbers: 20, alerts: 10, deliveries: 10, members: 100, deliveryDays: 7 };

type Reply = { data: unknown; error: { code?: string; message?: string } | null; count?: number | null };

// A read of a table or function that an environment may not have yet (a migration not applied): the page shows
// "not available" for that card instead of failing (PGRST202 missing function, PGRST205 or 42P01 missing table).
// Any other failure is logged and reported the same way, so one card never takes the whole page down.
export async function optional<T>(read: () => PromiseLike<Reply>, shape: (data: unknown, count: number | null) => T) {
  try {
    const r = await read();
    if (r.error) {
      if (!["PGRST202", "PGRST205", "42P01", "42883"].includes(r.error.code ?? "")) console.error("Business page read failed", r.error);
      return { available: false as const };
    }
    return { available: true as const, ...shape(r.data, r.count ?? null) };
  } catch (e) {
    console.error("Business page read failed", e);
    return { available: false as const };
  }
}

// The plan card: the latest plan version, without its prices for an admin who may not see billing.
export function planView(row: Row | null, canSeePrices: boolean) {
  if (!row) return null;
  return canSeePrices ? row : Object.fromEntries(Object.entries(row).filter(([k]) => !/price|amount|fee|cost|overage|estimate/i.test(k)));
}

// The current billing period (start <= now < end), or null when there is none or it has ended.
export function currentPeriod(rows: Row[], now: Date) {
  return rows.find((p) => new Date(String(p.period_start)) <= now && now < new Date(String(p.period_end))) ?? null;
}

// What is left of each allowance this period, from its balances (allowance_buckets for that period), counted the way
// zella_billing_balance counts it: the 5% reserve for appointment messages (kind "buffer") is kept apart.
export function usageSummary(buckets: Row[]) {
  const out: Record<string, { granted: number; used: number; remaining: number; reserve: number; reserveRemaining: number }> = {};
  for (const b of buckets) {
    const t = (out[String(b.resource)] ??= { granted: 0, used: 0, remaining: 0, reserve: 0, reserveRemaining: 0 });
    const granted = Number(b.granted) || 0, used = Number(b.used) || 0;
    if (b.kind === "buffer") {
      t.reserve += granted;
      t.reserveRemaining = Math.max(0, t.reserveRemaining + granted - used);
    } else {
      t.granted += granted;
      t.used += used;
      t.remaining = Math.max(0, t.granted - t.used);
    }
  }
  return out;
}

// Call routing as the Voice page's zella_admin_routing_get works it out, from the receptionist's escalation rules
// (that function refuses the server key, which has no admin behind it). routing_test checks both agree.
export function routingFrom(rules: Row, extra: { timezone: string | null; hasAgent: boolean; hasHours: boolean; onCall: Row | null }) {
  const str = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
  const flag = (v: unknown) => (typeof v === "boolean" ? v : v === "true" ? true : v === "false" ? false : true);
  const transferTo = (rules.transfer_to ?? {}) as Row;
  return {
    has_agent: extra.hasAgent,
    timezone: extra.timezone,
    transfer_enabled: flag(rules.transfer_enabled),
    transfer_number: str(rules.transfer_number) ?? str(transferTo.phone),
    fallback_number: str(rules.fallback_number),
    transfer_route: str(rules.transfer_route) ?? "primary",
    transfer_open_hours_only: flag(rules.transfer_open_hours_only),
    on_call: extra.onCall ? { enabled: extra.onCall.enabled ?? null, scope: extra.onCall.scope ?? null } : null,
    has_hours: extra.hasHours,
  };
}

// The signed in accounts behind member and actor ids: email, last sign in, whether two step sign in is set up.
async function people(admin: SupabaseClient, ids: (string | null)[]) {
  const unique = [...new Set(ids.filter((id): id is string => Boolean(id)))].slice(0, DETAIL_LIMITS.members);
  const out: Record<string, { email: string | null; last_sign_in_at: string | null; two_step: boolean }> = {};
  await Promise.all(unique.map(async (id) => {
    const { data } = await admin.auth.admin.getUserById(id);
    const factors = ((data?.user as { factors?: { status?: string }[] } | undefined)?.factors ?? []);
    out[id] = { email: data?.user?.email ?? null, last_sign_in_at: data?.user?.last_sign_in_at ?? null, two_step: factors.some((f) => f.status === "verified") };
  }));
  return out;
}

// One business's page. `can` is the signed in admin's permission set (detail.ts adminPermissions): the activity list
// and who did each action are returned only with audit.view (BIZ-04); without it activity is [] and
// activityAllowed false, never null, so an older web app still renders. Caller numbers and connection accounts are
// masked (mask.ts, the zella_admin_mask rule; BIZ-22): revealing them is a separate, audited action.
export async function businessDetail(admin: SupabaseClient, businessId: string, can: Set<string>, deps: DetailDeps) {
  const setup = await deps.loadSetup(admin, businessId);
  const activityAllowed = can.has("audit.view");
  const now = new Date();
  const since = new Date(now.getTime() - DETAIL_LIMITS.deliveryDays * 86400000).toISOString();

  const [
    industryResult, invitationsResult, membersResult, integrationsResult,
    callsResult, callCountResult, logsResult, ticketsResult,
  ] = await Promise.all([
    admin.from("industries").select("id, name").eq("id", setup.business.industry_id).maybeSingle(),
    admin.from("business_invitations")
      .select("id, email, owner_name, role, status, invited_at, accepted_at, expires_at, last_error, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false }),
    admin.from("business_members")
      .select("user_id, role, status, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: true })
      .limit(DETAIL_LIMITS.members),
    admin.from("integrations")
      .select("id, provider, integration_type, status, account_email, error_message, last_synced_at, updated_at")
      .eq("business_id", businessId),
    admin.from("calls")
      .select("id, direction, status, from_number, to_number, started_at, duration_seconds, ai_handled, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false })
      .limit(10),
    admin.from("calls").select("id", { count: "exact", head: true }).eq("business_id", businessId),
    activityAllowed
      ? admin.from("audit_logs")
        .select("id, action, user_id, entity_type, new_data, created_at")
        .eq("business_id", businessId)
        .order("created_at", { ascending: false })
        .limit(30)
      : Promise.resolve({ data: [], error: null }),
    admin.from("support_tickets")
      .select("id, subject, status, priority, category, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false })
      .limit(10),
  ]);

  const queryError = industryResult.error ?? invitationsResult.error ??
    membersResult.error ?? integrationsResult.error ?? callsResult.error ??
    callCountResult.error ?? logsResult.error ?? ticketsResult.error;
  if (queryError) throw queryError;

  const members = membersResult.data ?? [];
  const logs = logsResult.data ?? [];
  const userIds = [...members.map((m) => m.user_id), ...logs.map((l) => l.user_id)];

  const [who, profilesResult, extra] = await Promise.all([
    people(admin, userIds),
    members.length
      ? admin.from("profiles").select("id, first_name, last_name")
        .in("id", members.map((m) => m.user_id))
      : Promise.resolve({ data: [], error: null }),
    detailExtras(admin, businessId, setup, can, now, since),
  ]);
  if (profilesResult.error) throw profilesResult.error;
  const signInFacts = can.has(SIGN_IN_FACTS_PERMISSION);

  const profileById = new Map((profilesResult.data ?? []).map((p) => [p.id, p]));

  return {
    ...setup,
    industryName: industryResult.data?.name ?? "Unassigned",
    // The owner's invitation first (it is the one the page acts on), then the newest.
    invitations: [...(invitationsResult.data ?? [])].sort((a, b) =>
      Number((b.role ?? "owner") === "owner") - Number((a.role ?? "owner") === "owner")
    ),
    members: members.map((m) => {
      const profile = profileById.get(m.user_id);
      return {
        ...m,
        email: who[m.user_id]?.email ?? null,
        name: [profile?.first_name, profile?.last_name].filter(Boolean).join(" ") || null,
        ...(signInFacts ? { last_sign_in_at: who[m.user_id]?.last_sign_in_at ?? null, two_step: who[m.user_id]?.two_step ?? false } : {}),
      };
    }),
    integrations: (integrationsResult.data ?? []).map((i) => ({
      ...i,
      account_email: mask(i.account_email),
      error_message: maskText(i.error_message),
    })),
    calls: (callsResult.data ?? []).map((c) => ({ ...c, from_number: mask(c.from_number), to_number: mask(c.to_number) })),
    callCount: callCountResult.count ?? 0,
    tickets: ticketsResult.data ?? [],
    activityAllowed,
    activity: activityAllowed ? logs.map((l) => ({ ...l, actor: who[l.user_id]?.email ?? null })) : [],
    permissions: [...can].sort(),
    signInFactsAllowed: signInFacts,
    ...extra,
  };
}

// Payload v2 (BIZ-11, BIZ-12 phase 1, UI-07, UI-08, COM-03, BIZ-30 part b): each card's data, read with the server key
// (auth.uid() is null, which takes each function's server branch). Every part is additive and reports
// {available:false} on its own when it can't be read. Nothing here calls zella_billing_overview or
// zella_billing_open_period, which can create a billing period: opening the page writes nothing.
// deno-lint-ignore no-explicit-any
async function detailExtras(admin: SupabaseClient, businessId: string, setup: any, can: Set<string>, now: Date, since: string) {
  const agentId = setup.receptionist?.agentId ?? null;
  const rules = (setup.receptionist?.escalationRules ?? {}) as Row;
  const [readiness, plan, periods, numbers, alerts, activation, lastTest, deliveryStatus, deliveries, recentOutcomes, onCall, hours, activityCount, connections] =
    await Promise.all([
      optional(() => admin.rpc("zella_business_readiness", { p_business_id: businessId }), (d) => ({ report: d })),
      optional(() => admin.from("business_plans").select("*").eq("business_id", businessId).order("version", { ascending: false }).limit(1),
        (d) => ({ plan: planView(((d as Row[]) ?? [])[0] ?? null, can.has(PRICES_PERMISSION)), pricesShown: can.has(PRICES_PERMISSION) })),
      optional(() => admin.from("billing_periods").select("id, period_start, period_end, is_trial").eq("business_id", businessId)
        .order("period_start", { ascending: false }).limit(3), (d) => ({ rows: (d as Row[]) ?? [] })),
      optional(() => admin.from("business_phone_numbers").select("id, e164, label, status, created_at").eq("business_id", businessId)
        .order("created_at", { ascending: false }).limit(DETAIL_LIMITS.numbers), (d) => ({ rows: (d as Row[]) ?? [] })),
      optional(() => admin.from("platform_alerts").select("id, kind, severity, title, status, occurrences, last_seen_at", { count: "exact" })
        .eq("business_id", businessId).neq("status", "resolved").order("last_seen_at", { ascending: false }).limit(DETAIL_LIMITS.alerts),
        (d, count) => ({ rows: (d as Row[]) ?? [], count: count ?? ((d as Row[]) ?? []).length })),
      can.has(ACTIVATION_PERMISSION)
        ? optional(() => admin.rpc("zella_activation_report", { p_business_id: businessId }), (d) => ({ report: d }))
        : Promise.resolve({ available: false as const, notAllowed: true }),
      can.has(ACTIVATION_PERMISSION)
        ? optional(() => admin.from("activation_tests").select("ok, detail, created_at").eq("business_id", businessId)
          .order("created_at", { ascending: false }).limit(1), (d) => ({ test: ((d as Row[]) ?? [])[0] ?? null }))
        : Promise.resolve({ available: false as const }),
      optional(() => admin.rpc("zella_assistant_delivery_status", { p_business_id: businessId }), (d) => ({ status: d })),
      // no caller data: no provider call id, no numbers
      optional(() => admin.from("assistant_deliveries").select("id, outcome, problems, config_hash, created_at").eq("business_id", businessId)
        .order("created_at", { ascending: false }).limit(DETAIL_LIMITS.deliveries), (d) => ({ rows: (d as Row[]) ?? [] })),
      optional(() => admin.from("assistant_deliveries").select("outcome").eq("business_id", businessId).gte("created_at", since)
        .in("outcome", ["not_ready", "unknown_number"]).limit(1000), (d) => ({ rows: (d as Row[]) ?? [] })),
      optional(() => admin.from("on_call_settings").select("enabled, scope").eq("business_id", businessId).limit(1),
        (d) => ({ row: ((d as Row[]) ?? [])[0] ?? null })),
      optional(() => admin.from("business_hours").select("weekday").eq("business_id", businessId).limit(1), (d) => ({ any: ((d as Row[]) ?? []).length > 0 })),
      can.has("audit.view")
        ? optional(() => admin.from("audit_logs").select("id", { count: "exact", head: true }).eq("business_id", businessId), (_d, count) => ({ count }))
        : Promise.resolve({ available: false as const }),
      // the one definition of connected, answering and live (lane C, sql/zella_connection_state.sql; COM-01):
      // zella_business_connections(p_business_ids uuid[]), one row per business. Unavailable until that file is applied.
      optional(() => admin.rpc("zella_business_connections", { p_business_ids: [businessId] }),
        (d) => ({ state: (Array.isArray(d) ? d[0] : null) ?? null })),
    ]);

  const period = periods.available ? currentPeriod(periods.rows, now) : null;
  const buckets = period
    ? await optional(() => admin.from("allowance_buckets").select("resource, kind, granted, used, expires_at").eq("period_id", period.id)
      .order("resource"), (d) => ({ rows: (d as Row[]) ?? [] }))
    : { available: periods.available, rows: [] as Row[] };
  const counts = { not_ready: 0, unknown_number: 0 };
  if (recentOutcomes.available) {
    for (const r of recentOutcomes.rows) if (r.outcome === "not_ready" || r.outcome === "unknown_number") counts[r.outcome]++;
  }

  return {
    readiness,
    plan,
    usage: !periods.available ? { available: false } : {
      available: buckets.available,
      period: period ? { from: period.period_start, to: period.period_end, trial: period.is_trial } : null,
      totals: usageSummary(buckets.available ? buckets.rows : []),
      balances: buckets.available ? buckets.rows : [],
    },
    numbers,
    alerts,
    activation: { ...activation, lastTest: lastTest.available ? lastTest.test : null },
    routing: routingFrom(rules, {
      timezone: (setup.business?.timezone as string) ?? null, hasAgent: Boolean(agentId),
      hasHours: hours.available ? hours.any : false, onCall: onCall.available ? onCall.row : null,
    }),
    deliveries: {
      status: deliveryStatus.available ? deliveryStatus.status : null,
      available: deliveryStatus.available || deliveries.available,
      recent: deliveries.available ? deliveries.rows : [],
      lastDays: DETAIL_LIMITS.deliveryDays,
      counts: recentOutcomes.available ? counts : null,
    },
    activityCount: activityCount.available ? activityCount.count : null,
    connections,
  };
}
