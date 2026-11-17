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
import { OPEN_OWNER_INVITATION, latestOwnerInvitation } from "./ownerInvitation.ts";
import { MEMBER_SUPPORT_PERMISSION, type Member, reasonProblem, statusProblem } from "./member_support.ts";

// What business_detail borrows from index.ts (passed in, so this module has no import cycle and can be tested).
export type DetailDeps = {
  // deno-lint-ignore no-explicit-any
  loadSetup: (admin: SupabaseClient, businessId: string) => Promise<any>;
  viewerId?: string;   // the signed in admin, for the support access record (BIZ-22)
};

type Row = Record<string, unknown>;

// ---- What an audit row records about the state before a change (BIZ-17) ----
// A handler hangs the "before" values on its result under this Symbol key. JSON leaves Symbol keys out, so before values
// (an earlier owner name, setup slices) never reach the browser in the response; only the audit builders read them.
export const AUDIT_BEFORE = Symbol("audit before");
export function withBefore<T extends object>(result: T, before: Row | null): T {
  Object.defineProperty(result, AUDIT_BEFORE, { value: before, enumerable: false });
  return result;
}
export const beforeOf = (result: unknown): Row | null =>
  ((result as Record<symbol, unknown> | null)?.[AUDIT_BEFORE] as Row | null | undefined) ?? null;

// The lifecycle fields a suspend, reactivate, cancel or finish changes.
export const LIFECYCLE_FIELDS = ["is_active", "onboarding_status", "suspended_at", "cancel_at", "cancelled_at"] as const;
export const lifecycleOf = (b: Row | null) => b ? Object.fromEntries(LIFECYCLE_FIELDS.map((k) => [k, b[k] ?? null])) : null;

// A business's own contact details: an audit row names them when they change, never their values (DB-13, PRV-2).
export const CONTACT_FIELDS = ["email", "phone", "address_line_1", "address_line_2", "postal_code"];
export function businessChange(before: Row | null, after: Row) {
  const oldData: Row = {}, newData: Row = {}, contacts: string[] = [];
  for (const [k, v] of Object.entries(after)) {
    const was = before ? (before[k] ?? null) : null;
    const now = v === "" ? null : v;
    if (before && was === now) continue;
    if (CONTACT_FIELDS.includes(k)) { if (now !== null || was !== null) contacts.push(k); continue; }
    if (before) oldData[k] = was;
    newData[k] = now;
  }
  if (contacts.length) newData.contact_fields_changed = contacts;
  return { old_data: before ? oldData : null, new_data: newData };
}

// Permission each action of this module needs (index.ts: `?? DETAIL_PERMISSIONS[action]`).
export const DETAIL_PERMISSIONS: Record<string, string> = {
  business_size_save: "businesses.manage",   // BIZ-08: was a browser RPC open to owner and super admin only
  business_contacts_reveal: "businesses.manage",   // BIZ-22 (REVEAL_PERMISSION): needs the owner's approval to deploy
  invitation_cancel: "businesses.manage",   // BIZ-21 (CANCEL_PERMISSION): needs the owner's approval to deploy
  member_set_status: MEMBER_SUPPORT_PERMISSION,   // UI-06 part c: needs the owner's approval to deploy
  member_mfa_reset: MEMBER_SUPPORT_PERMISSION,   // UI-06 part d: needs the owner's approval to deploy
  business_pack_catalog: "billing.view",   // CFG-22
  business_pack_grant: "billing.manage",   // CFG-22: needs the owner's approval to deploy; each real grant too
};

// CFG-22: the database's refusals from zella_admin_pack_grant, in words.
export const PACK_GRANT_ERRORS: Record<string, [string, number]> = {
  NOT_ALLOWED: ["Your admin role can't grant packs (it needs billing.manage).", 403],
  REASON_REQUIRED: ["Give a reason of at least 5 characters.", 400],
  BAD_IDEMPOTENCY_KEY: ["Close the dialog and try again.", 400],
  UNKNOWN_PACK: ["That pack isn't on sale any more. Choose another.", 400],
  NO_CURRENT_PERIOD: ["This business has no current billing period (no active plan or trial), so a pack can't be added yet.", 409],
  IDEMPOTENCY_CONFLICT: ["This grant was already used for a different pack. Close the dialog and start again.", 409],
};
export function packGrantError(message: string | undefined): [string, number] | null {
  const code = Object.keys(PACK_GRANT_ERRORS).find((c) => (message ?? "").includes(c));
  return code ? PACK_GRANT_ERRORS[code] : null;
}

// ---- Owner invitations (BIZ-21; lane E defaults, owner can change; needs approval before deploy) ----
// Resend is refused for RESEND_COOLDOWN_MINUTES after the last invitation actually went out (invited_at is set only on
// a successful send, so a failed send can be retried at once). Cancelling needs a reason.
export const RESEND_COOLDOWN_MINUTES = 5;
export const CANCEL_PERMISSION = "businesses.manage";
export const CANCEL_REASON = { min: 10, max: 300 };

// When the next resend may go out, or null when it may go now.
export function resendAllowedAt(invitedAt: string | null | undefined, now: Date): Date | null {
  if (!invitedAt) return null;
  const at = new Date(new Date(invitedAt).getTime() + RESEND_COOLDOWN_MINUTES * 60000);
  return at > now ? at : null;
}

// ---- Audited support access (BIZ-22; lane E defaults, owner can change; needs approval before deploy) ----
// Every open of a business is recorded once per admin and business in VIEW_DEDUPE_MINUTES. Those rows, and reveals,
// are kept out of the business's Activity list and shown in their own Support access list (audit.view).
export const VIEW_DEDUPE_MINUTES = 30;
export const SUPPORT_ACCESS_ACTIONS = ["business.viewed", "support.contacts_revealed"];
export const REVEAL_PERMISSION = "businesses.manage";
export const REVEAL_REASON = { min: 10, max: 300 };

// What index.ts lends this module's handlers (the same helpers platform.ts gets).
export type DetailKit = {
  text: (v: unknown, max?: number) => string;
  requireId: (v: unknown, label?: string) => string;
  InputError: new (message: string, status?: number) => Error;
};

type Audit = { action: string; business_id?: string | null; entity_type?: string | null; entity_id?: string | null; old_data?: Row | null; new_data?: Row | null };

export const BUSINESS_SIZES = ["small", "medium", "large"] as const;

// This page's actions. Each returns what the page shows; `audited` says what each records (null records nothing).
export function detailHandlers(admin: SupabaseClient, fields: Row, k: DetailKit, userId = "", caller?: SupabaseClient) {
  const handlers: Record<string, () => Promise<unknown>> = {
    // CFG-22: the packs an admin can grant (active catalog rows).
    business_pack_catalog: async () => {
      const { data, error } = await admin.from("billing_pack_catalog").select("code, resource, quantity, price_cents, currency")
        .eq("active", true).order("resource").order("quantity");
      if (error) throw error;
      return { packs: data ?? [] };
    },
    // CFG-22: grant one pack, with a reason. Runs as the admin themselves (the caller's own client, after the function's
    // two step check), so zella_admin_pack_grant checks billing.manage for them and records billing.pack_granted with
    // their id; one idempotency key per dialog means a double click grants once. Never opens a period to make it work.
    business_pack_grant: async () => {
      if (!caller) throw new k.InputError("Not available", 500);
      const businessId = k.requireId(fields.businessId);
      const packCode = k.text(fields.packCode, 40);
      const reason = k.text(fields.reason, 500);
      const idempotencyKey = k.text(fields.idempotencyKey, 100);
      if (!packCode) throw new k.InputError("Choose a pack");
      if (reason.length < 5) throw new k.InputError(PACK_GRANT_ERRORS.REASON_REQUIRED[0]);
      const { data, error } = await caller.rpc("zella_admin_pack_grant", {
        p_business_id: businessId, p_pack_code: packCode, p_reason: reason, p_idempotency_key: idempotencyKey,
      });
      if (error) {
        const known = packGrantError(error.message);
        if (known) throw new k.InputError(known[0], known[1]);
        throw error;
      }
      return { businessId, ...(data as Row) };
    },
    // UI-06 part d: remove a member's two step sign in after the admin confirmed the identity check
    // (docs/ARCHITECTURE.md REQ-LC-19). The audit row is written FIRST; if it can't be, nothing is removed. Only that
    // person's verified authenticators are touched, and only their count is recorded. Never a platform admin's.
    member_mfa_reset: async () => {
      const businessId = k.requireId(fields.businessId);
      const memberId = k.requireId(fields.userId, "member");
      const reason = k.text(fields.reason, 301);
      const bad = reasonProblem(reason);
      if (bad) throw new k.InputError(bad);
      if (fields.identityChecked !== true) throw new k.InputError("Confirm you checked who is asking, as the identity check says");
      if (memberId === userId) throw new k.InputError("You can't reset your own two step sign in here", 403);
      const { data: member, error } = await admin.from("business_members").select("user_id, role, status")
        .eq("business_id", businessId).eq("user_id", memberId).maybeSingle();
      if (error) throw error;
      if (!member) throw new k.InputError("This person isn't a member of this business", 404);
      const { data: staff, error: staffError } = await admin.from("platform_admins").select("user_id").eq("user_id", memberId).maybeSingle();
      if (staffError) throw staffError;
      if (staff) throw new k.InputError("This person is a Zella Voice admin. Their two step sign in is reset through Users & access, not here.", 403);
      const { data: listed, error: listError } = await admin.auth.admin.mfa.listFactors({ userId: memberId });
      if (listError) throw listError;
      const verified = ((listed?.factors ?? []) as { id: string; status: string }[]).filter((f) => f.status === "verified");
      if (!verified.length) throw new k.InputError("This member has no two step sign in set up", 409);
      const { error: auditError } = await admin.from("audit_logs").insert({
        action: "member.mfa_reset", business_id: businessId, user_id: userId, entity_type: "business_member", entity_id: null,
        old_data: { user_id: memberId, verified_factors: verified.length },
        new_data: { user_id: memberId, reason, identity_checked: true },
      });
      if (auditError) {
        console.error("Two step reset audit failed; nothing removed", auditError);
        throw new k.InputError("The reset couldn't be recorded, so nothing was changed. Please try again.", 503);
      }
      let removed = 0;
      for (const f of verified) {
        const { error: deleteError } = await admin.auth.admin.mfa.deleteFactor({ id: f.id, userId: memberId });
        if (deleteError) {
          console.error("Two step factor removal failed", deleteError);
          throw new k.InputError(`Removed ${removed} of ${verified.length} authenticators; the rest could not be removed. Please try again.`, 502);
        }
        removed++;
      }
      return { businessId, userId: memberId, removed };
    },
    // UI-06 part c: deactivate or reactivate one member's access to this business, with a reason. The business always
    // keeps one active owner. Saved only from the status the page saw.
    member_set_status: async () => {
      const businessId = k.requireId(fields.businessId);
      const memberId = k.requireId(fields.userId, "member");
      const next = k.text(fields.status, 20);
      const reason = k.text(fields.reason, 301);
      const bad = reasonProblem(reason);
      if (bad) throw new k.InputError(bad);
      const { data: rows, error } = await admin.from("business_members").select("user_id, role, status").eq("business_id", businessId);
      if (error) throw error;
      const members = (rows ?? []) as Member[];
      const problem = statusProblem(members, memberId, next);
      if (problem) throw new k.InputError(problem.message, problem.status);
      const { role, status: was } = members.find((m) => m.user_id === memberId)!;
      const { data: moved, error: moveError } = await admin.from("business_members").update({ status: next })
        .eq("business_id", businessId).eq("user_id", memberId).eq("status", was).select("user_id");
      if (moveError) throw moveError;
      if (!moved?.length) throw new k.InputError("This member changed meanwhile. Reload the page to see them.", 409);
      return { businessId, userId: memberId, role, before: was, status: next, reason };
    },
    // BIZ-21: cancel the owner's open invitation. The link stops working (zella_accept_my_invitations only accepts an
    // open one) and the invited owner seat is removed, so inviting the same person again works.
    invitation_cancel: async () => {
      const businessId = k.requireId(fields.businessId);
      const reason = k.text(fields.reason, CANCEL_REASON.max + 1);
      if (reason.length < CANCEL_REASON.min) throw new k.InputError(`Give a reason of at least ${CANCEL_REASON.min} characters`);
      if (reason.length > CANCEL_REASON.max) throw new k.InputError(`Keep the reason under ${CANCEL_REASON.max} characters`);
      const { data: inv, error } = await latestOwnerInvitation(admin, businessId, "id, email, owner_name, status, auth_user_id");
      if (error) throw error;
      if (!inv) throw new k.InputError("This business has no open owner invitation", 404);
      if (inv.status === "accepted") throw new k.InputError("The owner has already accepted the invitation, so it can't be cancelled", 409);
      const now = new Date().toISOString();
      // only from an open or sent state, and only the owner's: a send or acceptance that lands first wins
      const { data: moved, error: moveError } = await admin.from("business_invitations")
        .update({ status: "revoked", updated_at: now }).eq("id", inv.id).eq("role", "owner")
        .in("status", [...OPEN_OWNER_INVITATION, "sent"]).select("id");
      if (moveError) throw moveError;
      if (!moved?.length) throw new k.InputError("The invitation changed meanwhile. Reload the page to see it.", 409);
      const authUserId = (inv as { auth_user_id?: string | null }).auth_user_id ?? null;
      let seatRemoved = false;
      if (authUserId) {
        const { data: removed, error: seatError } = await admin.from("business_members").delete()
          .eq("business_id", businessId).eq("user_id", authUserId).eq("role", "owner").eq("status", "invited").select("id");
        if (seatError) console.error("Invited owner seat removal failed", seatError);
        seatRemoved = Boolean(removed?.length);
      }
      return { businessId, invitationId: inv.id, before: inv.status, reason, seatRemoved, email: mask(inv.email) };
    },
    // BIZ-22: the masked contact details for one response, with a reason recorded first.
    business_contacts_reveal: async () => {
      const businessId = k.requireId(fields.businessId);
      const reason = k.text(fields.reason, REVEAL_REASON.max + 1);
      if (reason.length < REVEAL_REASON.min) throw new k.InputError(`Give a reason of at least ${REVEAL_REASON.min} characters`);
      if (reason.length > REVEAL_REASON.max) throw new k.InputError(`Keep the reason under ${REVEAL_REASON.max} characters`);
      const { data: exists, error } = await admin.from("businesses").select("id").eq("id", businessId).maybeSingle();
      if (error) throw error;
      if (!exists) throw new k.InputError("Business not found", 404);
      const out = await revealContacts(admin, businessId, userId, reason);
      if (!out) throw new k.InputError("The reveal couldn't be recorded, so nothing was shown. Please try again.", 503);
      return out;
    },
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
    business_pack_grant: () => null,   // zella_admin_pack_grant records billing.pack_granted itself
    member_mfa_reset: () => null,   // recorded before anything was removed
    member_set_status: (r) => ({
      action: r.status === "suspended" ? "member.suspended" : "member.reactivated", business_id: r.businessId as string,
      entity_type: "business_member", entity_id: null,
      old_data: { user_id: r.userId, role: r.role, status: r.before }, new_data: { user_id: r.userId, role: r.role, status: r.status, reason: r.reason },
    }),
    invitation_cancel: (r) => ({
      action: "invitation.revoked", business_id: r.businessId as string, entity_type: "business_invitation", entity_id: r.invitationId as string,
      old_data: { status: r.before ?? null }, new_data: { status: "revoked", reason: r.reason ?? null, seat_removed: r.seatRemoved ?? false, email: mask(r.email) },
    }),
    business_contacts_reveal: () => null,   // recorded before anything was read (revealContacts)
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
  if (deps.viewerId) await recordView(admin, deps.viewerId, businessId);
  const now = new Date();
  const since = new Date(now.getTime() - DETAIL_LIMITS.deliveryDays * 86400000).toISOString();

  const [
    industryResult, invitationsResult, membersResult, integrationsResult,
    _calls, callCountResult, logsResult, ticketsResult,
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
    // UI-10 part b, BIZ-22 part c: the Calls tab reads zella_admin_calls (masked, paged), so the page no longer reads
    // calls here at all. `calls` stays [] for one release because older web apps read data.calls.length.
    Promise.resolve({ data: [] as Row[], error: null }),
    admin.from("calls").select("id", { count: "exact", head: true }).eq("business_id", businessId),
    activityAllowed
      ? admin.from("audit_logs")
        .select("id, action, user_id, entity_type, old_data, new_data, created_at")
        .eq("business_id", businessId)
        .not("action", "in", `(${SUPPORT_ACCESS_ACTIONS.join(",")})`)
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
    membersResult.error ?? integrationsResult.error ??
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
    invitation: setup.invitation ? { ...setup.invitation, email: mask(setup.invitation.email), last_error: maskText(setup.invitation.last_error) } : null,
    invitations: [...(invitationsResult.data ?? [])].sort((a, b) =>
      Number((b.role ?? "owner") === "owner") - Number((a.role ?? "owner") === "owner")
    ).map((i) => ({ ...i, email: mask(i.email), last_error: maskText(i.last_error) })),
    contactsMasked: true,
    members: members.map((m) => {
      const profile = profileById.get(m.user_id);
      return {
        ...m,
        email: mask(who[m.user_id]?.email ?? null),
        name: [profile?.first_name, profile?.last_name].filter(Boolean).join(" ") || null,
        ...(signInFacts ? { last_sign_in_at: who[m.user_id]?.last_sign_in_at ?? null, two_step: who[m.user_id]?.two_step ?? false } : {}),
      };
    }),
    integrations: (integrationsResult.data ?? []).map((i) => ({
      ...i,
      account_email: mask(i.account_email),
      error_message: maskText(i.error_message),
    })),
    calls: [],
    callCount: callCountResult.count ?? 0,
    tickets: ticketsResult.data ?? [],
    activityAllowed,
    activity: activityAllowed ? logs.map((l) => ({ ...l, actor: who[l.user_id]?.email ?? null })) : [],
    supportAccess: activityAllowed ? await supportAccessList(admin, businessId) : [],
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
        ? optional(() => admin.from("audit_logs").select("id", { count: "exact", head: true }).eq("business_id", businessId)
          .not("action", "in", `(${SUPPORT_ACCESS_ACTIONS.join(",")})`), (_d, count) => ({ count }))
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

// One "business.viewed" row per admin and business in VIEW_DEDUPE_MINUTES. A failed write never blocks reading the page;
// it raises the same audit_write_failed alert as any other missed audit row.
async function recordView(admin: SupabaseClient, userId: string, businessId: string) {
  const since = new Date(Date.now() - VIEW_DEDUPE_MINUTES * 60000).toISOString();
  const { data: recent, error } = await admin.from("audit_logs").select("id").eq("action", "business.viewed")
    .eq("user_id", userId).eq("business_id", businessId).gte("created_at", since).limit(1);
  if (!error && recent?.length) return;
  const { error: insertError } = await admin.from("audit_logs").insert({
    action: "business.viewed", business_id: businessId, user_id: userId, entity_type: "business", entity_id: businessId,
    new_data: { dedupe_minutes: VIEW_DEDUPE_MINUTES },
  });
  if (insertError) {
    console.error("Support access record failed", insertError);
    await admin.rpc("zella_platform_alert", {
      p_kind: "audit_write_failed", p_title: "An admin action was not recorded in the audit log", p_detail: `business.viewed by admin ${userId}`,
      p_severity: "urgent", p_business_id: businessId, p_dedupe_key: "business.viewed", p_meta: { audit_action: "business.viewed" },
    });
  }
}

// Who opened this business or revealed its contacts, newest first (for audit.view holders).
async function supportAccessList(admin: SupabaseClient, businessId: string) {
  const { data, error } = await admin.from("audit_logs").select("id, action, user_id, new_data, created_at")
    .eq("business_id", businessId).in("action", SUPPORT_ACCESS_ACTIONS).order("created_at", { ascending: false }).limit(20);
  if (error) return [];
  const rows = (data ?? []) as Row[];
  const who = await people(admin, rows.map((r) => r.user_id as string | null));
  return rows.map((r) => ({ ...r, actor: who[r.user_id as string]?.email ?? null }));
}

// The contact details business_detail masks, for one response, after the reason is recorded. The audit row is written
// FIRST: if it can't be written, nothing is revealed (fails closed).
export async function revealContacts(admin: SupabaseClient, businessId: string, userId: string, reason: string) {
  const [invitations, members, calls, integrations] = await Promise.all([
    admin.from("business_invitations").select("id, email, last_error").eq("business_id", businessId),
    admin.from("business_members").select("user_id").eq("business_id", businessId).limit(DETAIL_LIMITS.members),
    admin.from("calls").select("id, from_number, to_number").eq("business_id", businessId).order("created_at", { ascending: false }).limit(10),
    admin.from("integrations").select("id, account_email, error_message").eq("business_id", businessId),
  ]);
  const failed = invitations.error ?? members.error ?? calls.error ?? integrations.error;
  if (failed) throw failed;
  const fields = ["member_emails", "invitation_emails", "call_numbers", "connection_accounts"];
  const { error: auditError } = await admin.from("audit_logs").insert({
    action: "support.contacts_revealed", business_id: businessId, user_id: userId, entity_type: "business", entity_id: businessId,
    new_data: { reason, fields, counts: { members: members.data?.length ?? 0, invitations: invitations.data?.length ?? 0, calls: calls.data?.length ?? 0, connections: integrations.data?.length ?? 0 } },
  });
  if (auditError) {
    console.error("Reveal audit failed; nothing revealed", auditError);
    return null;
  }
  const who = await people(admin, (members.data ?? []).map((m) => m.user_id));
  return {
    businessId,
    members: (members.data ?? []).map((m) => ({ user_id: m.user_id, email: who[m.user_id]?.email ?? null })),
    invitations: invitations.data ?? [],
    calls: calls.data ?? [],
    integrations: integrations.data ?? [],
  };
}
