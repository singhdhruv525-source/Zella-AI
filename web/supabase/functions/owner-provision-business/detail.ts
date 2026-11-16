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
  resolveUsers: (admin: SupabaseClient, ids: (string | null)[]) => Promise<Record<string, string | null>>;
};

// Permission each action of this module needs (index.ts: `?? DETAIL_PERMISSIONS[action]`).
export const DETAIL_PERMISSIONS: Record<string, string> = {};

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

// One business's page. `can` is the signed in admin's permission set (detail.ts adminPermissions): the activity list
// and who did each action are returned only with audit.view (BIZ-04); without it activity is [] and
// activityAllowed false, never null, so an older web app still renders. Caller numbers and connection accounts are
// masked (mask.ts, the zella_admin_mask rule; BIZ-22): revealing them is a separate, audited action.
export async function businessDetail(admin: SupabaseClient, businessId: string, can: Set<string>, deps: DetailDeps) {
  const { loadSetup, resolveUsers } = deps;
  const setup = await loadSetup(admin, businessId);
  const activityAllowed = can.has("audit.view");

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
      .order("created_at", { ascending: true }),
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

  const [emails, profilesResult] = await Promise.all([
    resolveUsers(admin, userIds),
    members.length
      ? admin.from("profiles").select("id, first_name, last_name")
        .in("id", members.map((m) => m.user_id))
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (profilesResult.error) throw profilesResult.error;

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
        email: emails[m.user_id] ?? null,
        name: [profile?.first_name, profile?.last_name].filter(Boolean).join(" ") || null,
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
    activity: activityAllowed ? logs.map((l) => ({ ...l, actor: emails[l.user_id] ?? null })) : [],
    permissions: [...can].sort(),
  };
}
