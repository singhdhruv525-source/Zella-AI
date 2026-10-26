// Admin Settings actions for owner-provision-business.
//
// Every action here runs after index.ts has verified the caller's sign-in, their platform role, and the
// permission listed in PERMISSIONS below (checked in the database by zella_admin_can). Nothing here trusts a role
// or business id from the browser. Secret values never leave the server: only whether they are set.

import type { SupabaseClient } from "@supabase/supabase-js";

type Json = Record<string, unknown>;

export type Kit = {
  text: (v: unknown, max?: number) => string;
  bool: (v: unknown, fallback?: boolean) => boolean;
  obj: (v: unknown) => Json;
  requireId: (v: unknown, label?: string) => string;
  validTimezone: (tz: string) => boolean;
  InputError: new (message: string, status?: number) => Error;
  EMAIL_RE: RegExp;
  UUID_RE: RegExp;
};

// Permission each action needs. Actions not listed are refused (index.ts), so a new action must be added here.
export const PERMISSIONS: Record<string, string> = {
  // existing actions
  dashboard_data: "businesses.view", setup_load: "businesses.view", overview_data: "businesses.view",
  business_detail: "businesses.view", industries_list: "businesses.view", agents_list: "businesses.view",
  integrations_overview: "businesses.view", modules_overview: "businesses.view", platform_status: "businesses.view",
  platform_settings_list: "businesses.view", failed_events_list: "businesses.view",
  setup_save_business: "businesses.manage", setup_save_owner: "businesses.manage", setup_save_terminology: "businesses.manage",
  setup_save_modules: "businesses.manage", setup_save_receptionist: "businesses.manage", setup_save_integrations: "businesses.manage",
  setup_save_automations: "businesses.manage", setup_finish: "businesses.manage", invitation_resend: "businesses.manage",
  business_suspend: "businesses.lifecycle", business_reactivate: "businesses.lifecycle", business_cancel: "businesses.lifecycle",
  business_undo_cancel: "businesses.lifecycle",
  audit_logs: "audit.view", industry_save: "platform.configure", industry_create: "platform.configure",
  admins_list: "security.view", admin_invite: "admins.manage", admin_update: "admins.manage",
  tickets_list: "support.manage", ticket_create: "support.manage", ticket_update: "support.manage",
  plans_list: "billing.view", plan_save: "plans.manage", platform_setting_save: "platform.configure",
  // settings actions (this file)
  me_admin: "businesses.view", roles_get: "security.view", roles_save: "roles.manage", admins_security: "security.view",
  platform_profile_get: "businesses.view", platform_profile_save: "platform.configure", maintenance_save: "platform.configure",
  tenants_search: "businesses.view", tenant_summary: "businesses.view", onboarding_overview: "businesses.view",
  billing_overview: "billing.view", payments_list: "billing.view", subscriptions_list: "billing.view",
  plan_entitlements_save: "plans.manage", voice_pricing_list: "billing.view", voice_pricing_add: "billing.manage",
  usage_summary: "analytics.view", numbers_list: "businesses.view", number_assign: "telephony.manage", number_set_status: "telephony.manage",
  comms_overview: "businesses.view", automation_overview: "businesses.view", security_overview: "security.view",
  alerts_list: "businesses.view", alert_set: "support.manage", analytics_overview: "analytics.view", data_quality: "analytics.view",
  legal_list: "businesses.view", legal_save: "legal.manage", legal_transition: "legal.manage", dev_overview: "businesses.view",
  privacy_overview: "security.view",
};

// What each permission means, for the matrix in Settings.
export const PERMISSION_CATALOG: [string, string][] = [
  ["businesses.view", "See businesses, setup status and platform health"],
  ["businesses.manage", "Set up and edit businesses"],
  ["businesses.lifecycle", "Suspend, reactivate and cancel businesses"],
  ["plans.manage", "Create and edit plans and allowances"],
  ["billing.view", "See subscriptions, payments and pricing"],
  ["billing.manage", "Change pricing inputs"],
  ["ai.configure", "AI provider and model settings"],
  ["telephony.manage", "Assign and pause phone numbers"],
  ["integrations.manage", "Integration settings"],
  ["comms.manage", "SMS and email settings"],
  ["support.manage", "Support tickets and platform alerts"],
  ["security.view", "Security overview, admins and sessions"],
  ["security.manage", "Security settings"],
  ["audit.view", "Read the audit log"],
  ["analytics.view", "Analytics and usage"],
  ["legal.manage", "Draft, review and publish legal documents"],
  ["platform.configure", "Platform profile, branding, maintenance and preferences"],
];
export const RESTRICTED_ROLES = ["platform_operations", "billing_admin", "support_admin", "security_admin", "read_only_admin"];
const ROLE_LABELS: Record<string, string> = {
  zella_owner: "Zella owner", super_admin: "Super admin", platform_operations: "Platform operations", billing_admin: "Billing admin",
  support_admin: "Support admin", security_admin: "Security admin", read_only_admin: "Read-only admin",
};

const LEGAL_KINDS = ["terms", "privacy", "acceptable_use", "dpa", "cookies", "ai_disclosure", "recording_consent"];
const VOICE_PROVIDERS = ["vapi", "telnyx", "twilio", "llm", "other"];
const LIMIT_NUMBERS = ["voice_minutes", "sms_messages", "phone_numbers", "team_members", "locations", "automations", "integrations"];
const LIMIT_CHOICES: Record<string, string[]> = {
  reporting: ["standard", "advanced"], support_level: ["standard", "priority", "dedicated"], onboarding: ["self", "guided", "done_for_you"],
};
const CURRENCIES = ["USD", "CAD", "GBP", "EUR", "AUD"];

function iso(v: unknown, label: string, k: Kit): string | null {
  const t = k.text(v, 40);
  if (!t) return null;
  const d = new Date(t);
  if (isNaN(d.getTime())) throw new k.InputError(`${label} is not a valid date and time`);
  return d.toISOString();
}

function httpsUrl(v: unknown, label: string, k: Kit): string | null {
  const t = k.text(v, 400);
  if (!t) return null;
  if (!/^https:\/\/[^\s/]+\.[^\s]+$/i.test(t)) throw new k.InputError(`${label} must be an https:// address`);
  return t;
}

function check<T>(res: { data: T; error: unknown }): T {
  if (res.error) throw res.error;
  return res.data;
}

async function setting(admin: SupabaseClient, key: string) {
  const { data, error } = await admin.from("platform_settings").select("value, updated_at").eq("key", key).maybeSingle();
  if (error) throw error;
  return data;
}

async function putSetting(admin: SupabaseClient, key: string, value: unknown) {
  const before = await setting(admin, key);
  check(await admin.from("platform_settings").upsert({ key, value, updated_at: new Date().toISOString() }, { onConflict: "key" }));
  return before?.value ?? null;
}

async function names(admin: SupabaseClient, ids: string[]) {
  const unique = [...new Set(ids.filter(Boolean))];
  if (!unique.length) return {} as Record<string, string>;
  const rows = check(await admin.from("businesses").select("id, name").in("id", unique)) ?? [];
  return Object.fromEntries((rows as { id: string; name: string }[]).map((b) => [b.id, b.name]));
}

async function emails(admin: SupabaseClient, ids: string[]) {
  const out: Record<string, { email: string | null; last_sign_in_at: string | null; mfa: boolean }> = {};
  await Promise.all([...new Set(ids.filter(Boolean))].map(async (id) => {
    const { data } = await admin.auth.admin.getUserById(id);
    const factors = (data?.user?.factors ?? []) as { status?: string }[];
    out[id] = { email: data?.user?.email ?? null, last_sign_in_at: data?.user?.last_sign_in_at ?? null, mfa: factors.some((f) => f.status === "verified") };
  }));
  return out;
}

const since = (days: number) => new Date(Date.now() - days * 86400000).toISOString();

export function settingsHandlers(admin: SupabaseClient, fields: Json, ctx: { userId: string; role: string; aal: string; mfa: boolean }, k: Kit) {
  const isOwner = ctx.role === "zella_owner";
  const page = Math.max(0, Math.min(1000, Number(fields.page) || 0));
  const size = 25;

  const handlers: Record<string, () => Promise<unknown>> = {
    me_admin: async () => {
      const perms = ctx.role === "zella_owner" ? PERMISSION_CATALOG.map(([p]) => p).concat(["admins.manage", "roles.manage"])
        : ctx.role === "super_admin" ? PERMISSION_CATALOG.map(([p]) => p)
        : ((check(await admin.from("platform_role_permissions").select("permission").eq("role", ctx.role)) ?? []) as { permission: string }[]).map((r) => r.permission);
      return { role: ctx.role, roleLabel: ROLE_LABELS[ctx.role] ?? ctx.role, permissions: perms, mfa: ctx.mfa, aal: ctx.aal };
    },

    roles_get: async () => {
      const rows = (check(await admin.from("platform_role_permissions").select("role, permission, updated_at")) ?? []) as { role: string; permission: string }[];
      const admins = (check(await admin.from("platform_admins").select("role, is_active")) ?? []) as { role: string; is_active: boolean }[];
      return {
        catalog: PERMISSION_CATALOG,
        roles: ["zella_owner", "super_admin", ...RESTRICTED_ROLES].map((r) => ({
          key: r, label: ROLE_LABELS[r], fixed: !RESTRICTED_ROLES.includes(r),
          permissions: r === "zella_owner" ? [...PERMISSION_CATALOG.map(([p]) => p), "admins.manage", "roles.manage"]
            : r === "super_admin" ? PERMISSION_CATALOG.map(([p]) => p) : rows.filter((x) => x.role === r).map((x) => x.permission),
          admins: admins.filter((a) => a.role === r && a.is_active).length,
        })),
        canEdit: isOwner,
      };
    },

    roles_save: async () => {
      const role = k.text(fields.role, 40);
      if (!RESTRICTED_ROLES.includes(role)) throw new k.InputError("Only the restricted roles can be changed", 400);
      const valid = new Set(PERMISSION_CATALOG.map(([p]) => p));
      const wanted = [...new Set((Array.isArray(fields.permissions) ? fields.permissions : []).map((p) => k.text(p, 60)))].filter((p) => valid.has(p));
      const before = ((check(await admin.from("platform_role_permissions").select("permission").eq("role", role)) ?? []) as { permission: string }[]).map((r) => r.permission);
      const remove = before.filter((p) => !wanted.includes(p));
      const add = wanted.filter((p) => !before.includes(p));
      if (remove.length) check(await admin.from("platform_role_permissions").delete().eq("role", role).in("permission", remove));
      if (add.length) check(await admin.from("platform_role_permissions").insert(add.map((permission) => ({ role, permission, updated_by: ctx.userId }))));
      return { role, before, after: wanted };
    },

    admins_security: async () => {
      const rows = (check(await admin.from("platform_admins").select("user_id, role, is_active, created_at")) ?? []) as { user_id: string; role: string; is_active: boolean; created_at: string }[];
      const info = await emails(admin, rows.map((r) => r.user_id));
      const recent = (check(await admin.from("audit_logs").select("user_id, action, created_at").in("user_id", rows.map((r) => r.user_id).concat(["00000000-0000-0000-0000-000000000000"]))
        .is("business_id", null).order("created_at", { ascending: false }).limit(100)) ?? []) as { user_id: string; action: string; created_at: string }[];
      return {
        admins: rows.map((r) => ({
          ...r, roleLabel: ROLE_LABELS[r.role] ?? r.role, ...info[r.user_id],
          lastAction: recent.find((a) => a.user_id === r.user_id) ?? null,
        })),
      };
    },

    platform_profile_get: async () => {
      const [profile, branding, maintenance] = await Promise.all(["platform_profile", "platform_branding", "maintenance"].map((key) => setting(admin, key)));
      return { profile: profile?.value ?? {}, branding: branding?.value ?? {}, maintenance: maintenance?.value ?? {}, canEdit: true };
    },

    platform_profile_save: async () => {
      const section = k.text(fields.section, 20);
      const v = k.obj(fields.values);
      if (section === "profile") {
        const email = k.text(v.support_email, 254).toLowerCase();
        if (email && !k.EMAIL_RE.test(email)) throw new k.InputError("Enter a valid support email");
        const phone = k.text(v.support_phone, 20).replace(/[\s()-]/g, "");
        if (phone && !/^\+[1-9]\d{7,14}$/.test(phone)) throw new k.InputError("Enter the support phone with its country code, like +15551234567");
        const tz = k.text(v.timezone, 64) || "America/New_York";
        if (!k.validTimezone(tz)) throw new k.InputError("Choose a valid time zone");
        const value = {
          display_name: k.text(v.display_name, 80) || "Zella AI", legal_name: k.text(v.legal_name, 200) || null,
          support_email: email || null, support_phone: phone || null, website: httpsUrl(v.website, "Website", k),
          address: k.text(v.address, 300) || null, country: (k.text(v.country, 2) || "US").toUpperCase(), timezone: tz,
          currency: CURRENCIES.includes(k.text(v.currency, 3)) ? k.text(v.currency, 3) : "USD",
        };
        const before = await putSetting(admin, "platform_profile", value);
        return { section, value, before };
      }
      if (section === "branding") {
        const logo = httpsUrl(v.logo_url, "Logo", k);
        if (logo && !logo.includes("/storage/v1/object/public/brand-assets/platform/")) throw new k.InputError("Upload the logo here so it is stored with Zella");
        const value = { logo_url: logo, login_headline: k.text(v.login_headline, 120) || null };
        const before = await putSetting(admin, "platform_branding", value);
        return { section, value, before };
      }
      throw new k.InputError("Unknown settings section");
    },

    maintenance_save: async () => {
      if (!["zella_owner", "super_admin"].includes(ctx.role)) throw new k.InputError("Only a Zella owner or super admin can change maintenance mode", 403);
      const reason = k.text(fields.reason, 300);
      if (reason.length < 3) throw new k.InputError("Give a reason (kept in the audit log)");
      const active = k.bool(fields.active, false);
      const value = {
        active, message: k.text(fields.message, 300) || null,
        starts_at: iso(fields.startsAt, "Start", k), ends_at: iso(fields.endsAt, "End", k),
        set_by: ctx.userId, set_at: new Date().toISOString(),
      };
      if (active && !value.message) throw new k.InputError("Write the message people will see");
      if (value.starts_at && value.ends_at && value.ends_at <= value.starts_at) throw new k.InputError("The end must be after the start");
      const before = await putSetting(admin, "maintenance", value);
      return { value, before, reason };
    },

    tenants_search: async () => {
      let q = admin.from("businesses").select("id, name, industry_id, onboarding_status, is_active, suspended_at, cancel_at, cancelled_at, created_at, city, state, business_size", { count: "exact" });
      const term = k.text(fields.q, 80).replace(/[%,()]/g, " ").trim();
      if (term) q = q.ilike("name", `%${term}%`);
      const industry = k.text(fields.industryId, 64);
      if (industry && k.UUID_RE.test(industry)) q = q.eq("industry_id", industry);
      const onboarding = k.text(fields.onboarding, 40);
      if (onboarding) q = q.eq("onboarding_status", onboarding);
      const status = k.text(fields.status, 20);
      if (status === "suspended") q = q.not("suspended_at", "is", null);
      if (status === "cancelled") q = q.not("cancelled_at", "is", null);
      if (status === "cancelling") q = q.not("cancel_at", "is", null).is("cancelled_at", null);
      if (status === "live") q = q.is("suspended_at", null).is("cancelled_at", null).eq("onboarding_status", "active");
      if (status === "setup") q = q.is("cancelled_at", null).neq("onboarding_status", "active");
      const from = iso(fields.createdFrom, "From", k); if (from) q = q.gte("created_at", from);
      const to = iso(fields.createdTo, "To", k); if (to) q = q.lt("created_at", to);
      const plan = k.text(fields.planId, 64);
      let planBusinessIds: string[] | null = null;
      if (plan && k.UUID_RE.test(plan)) {
        planBusinessIds = ((check(await admin.from("subscriptions").select("business_id").eq("plan_id", plan).in("status", ["trial", "active", "renewal_due", "past_due", "grace_period"])) ?? []) as { business_id: string }[]).map((s) => s.business_id);
        q = q.in("id", planBusinessIds.length ? planBusinessIds : ["00000000-0000-0000-0000-000000000000"]);
      }
      const { data, count, error } = await q.order("created_at", { ascending: false }).range(page * size, page * size + size - 1);
      if (error) throw error;
      const ids = (data ?? []).map((b) => b.id);
      const [industries, subs, members, integ, plans] = await Promise.all([
        admin.from("industries").select("id, name"),
        ids.length ? admin.from("subscriptions").select("business_id, status, plan_id, created_at").in("business_id", ids).order("created_at", { ascending: false }) : { data: [] },
        ids.length ? admin.from("business_members").select("business_id").in("business_id", ids).eq("status", "active") : { data: [] },
        ids.length ? admin.from("integrations").select("business_id, status").in("business_id", ids) : { data: [] },
        admin.from("plans").select("id, name"),
      ]);
      const ind = Object.fromEntries(((industries.data ?? []) as { id: string; name: string }[]).map((i) => [i.id, i.name]));
      const planName = Object.fromEntries(((plans.data ?? []) as { id: string; name: string }[]).map((p) => [p.id, p.name]));
      return {
        total: count ?? 0, page, size,
        industries: industries.data ?? [], plans: plans.data ?? [],
        rows: (data ?? []).map((b) => {
          const sub = ((subs.data ?? []) as { business_id: string; status: string; plan_id: string }[]).find((s) => s.business_id === b.id);
          const ints = ((integ.data ?? []) as { business_id: string; status: string }[]).filter((x) => x.business_id === b.id);
          return {
            ...b, industry: ind[b.industry_id] ?? null,
            members: ((members.data ?? []) as { business_id: string }[]).filter((m) => m.business_id === b.id).length,
            subscription: sub ? { status: sub.status, plan: planName[sub.plan_id] ?? null } : null,
            integrations: { total: ints.length, failing: ints.filter((x) => ["error", "disconnected"].includes(x.status)).length },
          };
        }),
      };
    },

    tenant_summary: async () => {
      const id = k.requireId(fields.businessId);
      const [entitlements, members, activity, integ] = await Promise.all([
        admin.rpc("zella_business_entitlements_internal", { p_business_id: id }),
        admin.from("business_members").select("user_id, role, status, created_at").eq("business_id", id),
        admin.from("audit_logs").select("action, entity_type, created_at, user_id").eq("business_id", id).order("created_at", { ascending: false }).limit(15),
        admin.from("integrations").select("provider, status, last_synced_at, last_error, error_count").eq("business_id", id),
      ]);
      const sub = check(await admin.rpc("zella_current_subscription", { p_business_id: id }));
      const people = await emails(admin, ((members.data ?? []) as { user_id: string }[]).map((m) => m.user_id));
      return {
        entitlements: entitlements.error ? null : entitlements.data,
        subscription: (sub as { id?: string })?.id ? sub : null,
        members: ((members.data ?? []) as { user_id: string; role: string; status: string; created_at: string }[]).map((m) => ({ ...m, email: people[m.user_id]?.email ?? null, last_sign_in_at: people[m.user_id]?.last_sign_in_at ?? null })),
        activity: activity.data ?? [],
        integrations: (integ.data ?? []).map((i) => ({ ...i, last_error: i.last_error ? String(i.last_error).slice(0, 160) : null })),
      };
    },

    onboarding_overview: async () => {
      const biz = (check(await admin.from("businesses").select("id, name, onboarding_status, industry_id, email, phone, timezone, created_at, setup_data")
        .is("cancelled_at", null).neq("onboarding_status", "active").order("created_at", { ascending: false }).limit(200)) ?? []) as Json[];
      const ids = biz.map((b) => b.id as string);
      const [steps, agents, numbers, subs, invites] = await Promise.all([
        ids.length ? admin.from("provisioning_steps").select("business_id, step, status, error, updated_at").in("business_id", ids) : { data: [] },
        ids.length ? admin.from("ai_agents").select("business_id, status").in("business_id", ids) : { data: [] },
        ids.length ? admin.from("business_phone_numbers").select("business_id, status").in("business_id", ids) : { data: [] },
        ids.length ? admin.from("subscriptions").select("business_id, status").in("business_id", ids) : { data: [] },
        ids.length ? admin.from("business_invitations").select("business_id, status, role").in("business_id", ids).eq("role", "owner") : { data: [] },
      ]);
      const of = <T extends { business_id: string }>(rows: unknown, id: string) => ((rows ?? []) as T[]).filter((r) => r.business_id === id);
      return {
        rows: biz.map((b) => {
          const id = b.id as string;
          const st = of<{ business_id: string; step: string; status: string; error: string | null; updated_at: string }>(steps.data, id);
          const checks = {
            profile: Boolean(b.email && b.phone && b.timezone),
            industry: Boolean(b.industry_id),
            receptionist: of<{ business_id: string; status: string }>(agents.data, id).length > 0,
            phone: of<{ business_id: string; status: string }>(numbers.data, id).some((n) => n.status === "active"),
            owner_invited: of<{ business_id: string; status: string }>(invites.data, id).some((i) => ["sent", "accepted"].includes(i.status)),
            billing: of<{ business_id: string; status: string }>(subs.data, id).length > 0,
          };
          return { id, name: b.name, onboarding_status: b.onboarding_status, created_at: b.created_at, checks,
            failed_steps: st.filter((s) => s.status === "failed").map((s) => ({ step: s.step, error: s.error ? String(s.error).slice(0, 200) : null, at: s.updated_at })) };
        }),
      };
    },

    billing_overview: async () => {
      const [subs, plans, pays, events] = await Promise.all([
        admin.from("subscriptions").select("id, business_id, plan_id, status, billing_interval, trial_end_at, cancelled_at, created_at"),
        admin.from("plans").select("id, price_monthly, price_yearly, currency"),
        admin.from("payments").select("amount, currency, status, created_at, paid_at").gte("created_at", since(30)),
        admin.from("billing_events").select("type, status, received_at").gte("received_at", since(30)),
      ]);
      const planById = Object.fromEntries(((plans.data ?? []) as { id: string; price_monthly: number; price_yearly: number; currency: string }[]).map((p) => [p.id, p]));
      const S = (subs.data ?? []) as { plan_id: string; status: string; billing_interval: string; trial_end_at: string | null; cancelled_at: string | null }[];
      const paid = S.filter((s) => ["active", "renewal_due", "past_due", "grace_period"].includes(s.status));
      const mrr: Record<string, number> = {};
      for (const s of paid) {
        const p = planById[s.plan_id];
        if (!p) continue;
        const m = s.billing_interval === "yearly" ? Number(p.price_yearly ?? 0) / 12 : Number(p.price_monthly ?? 0);
        mrr[p.currency || "USD"] = (mrr[p.currency || "USD"] ?? 0) + m;
      }
      const P = (pays.data ?? []) as { amount: number; currency: string; status: string }[];
      const sum = (rows: typeof P) => rows.reduce((a, r) => { a[r.currency || "USD"] = (a[r.currency || "USD"] ?? 0) + Number(r.amount ?? 0); return a; }, {} as Record<string, number>);
      const trialsEnded = S.filter((s) => s.trial_end_at && new Date(s.trial_end_at) < new Date());
      return {
        mrr, arr: Object.fromEntries(Object.entries(mrr).map(([c, v]) => [c, v * 12])),
        activePaid: paid.length, trials: S.filter((s) => s.status === "trial").length,
        trialConversions: { ended: trialsEnded.length, converted: trialsEnded.filter((s) => s.status === "active").length },
        pastDue: S.filter((s) => ["past_due", "grace_period"].includes(s.status)).length,
        cancelled30d: S.filter((s) => s.cancelled_at && s.cancelled_at > since(30)).length,
        payments30d: { succeeded: sum(P.filter((p) => p.status === "succeeded")), refunded: sum(P.filter((p) => p.status === "refunded")), failed: P.filter((p) => p.status === "failed").length },
        events30d: ((events.data ?? []) as { status: string }[]).length,
        provider: Boolean(Deno.env.get("STRIPE_WEBHOOK_SECRET")) ? "stripe" : null,
      };
    },

    payments_list: async () => {
      let q = admin.from("payments").select("id, business_id, subscription_id, amount, currency, status, provider, external_payment_id, payment_method, failure_reason, paid_at, created_at", { count: "exact" });
      const status = k.text(fields.status, 20); if (status) q = q.eq("status", status);
      const { data, count, error } = await q.order("created_at", { ascending: false }).range(page * size, page * size + size - 1);
      if (error) throw error;
      const n = await names(admin, (data ?? []).map((p) => p.business_id));
      return { total: count ?? 0, page, size, rows: (data ?? []).map((p) => ({ ...p, business_name: n[p.business_id] ?? null })) };
    },

    subscriptions_list: async () => {
      let q = admin.from("subscriptions").select("id, business_id, plan_id, status, billing_interval, provider, trial_end_at, current_period_end, grace_period_end_at, cancelled_at, metadata, created_at", { count: "exact" });
      const status = k.text(fields.status, 20); if (status) q = q.eq("status", status);
      const { data, count, error } = await q.order("created_at", { ascending: false }).range(page * size, page * size + size - 1);
      if (error) throw error;
      const n = await names(admin, (data ?? []).map((s) => s.business_id));
      const plans = (check(await admin.from("plans").select("id, name")) ?? []) as { id: string; name: string }[];
      return { total: count ?? 0, page, size, rows: (data ?? []).map((s) => ({ ...s, business_name: n[s.business_id] ?? null, plan: plans.find((p) => p.id === s.plan_id)?.name ?? null,
        cancellation_reason: (s.metadata as Json)?.cancellation_reason ?? null, metadata: undefined })) };
    },

    plan_entitlements_save: async () => {
      const id = k.requireId(fields.planId, "plan");
      const v = k.obj(fields.limits);
      const limits: Json = {};
      for (const key of LIMIT_NUMBERS) {
        const raw = v[key];
        if (raw === null || raw === undefined || raw === "") continue;
        const n = Number(raw);
        if (!Number.isInteger(n) || n < 0 || n > 10000000) throw new k.InputError(`${key.replace(/_/g, " ")} must be a whole number, or empty for no limit`);
        limits[key] = n;
      }
      for (const [key, options] of Object.entries(LIMIT_CHOICES)) {
        const t = k.text(v[key], 30);
        if (t) { if (!options.includes(t)) throw new k.InputError(`Choose a ${key.replace(/_/g, " ")} from the list`); limits[key] = t; }
      }
      const price = (x: unknown, label: string) => {
        if (x === null || x === undefined || x === "") return null;
        const n = Number(x);
        if (!isFinite(n) || n < 0 || n > 100000) throw new k.InputError(`${label} must be a positive amount`);
        return Math.round(n * 100) / 100;
      };
      const currency = k.text(fields.currency, 3).toUpperCase() || "USD";
      if (!CURRENCIES.includes(currency)) throw new k.InputError("Choose a supported currency");
      const before = check(await admin.from("plans").select("limits, price_monthly, price_yearly, currency").eq("id", id).maybeSingle());
      if (!before) throw new k.InputError("Plan not found", 404);
      const after = { limits, price_monthly: price(fields.priceMonthly, "Monthly price"), price_yearly: price(fields.priceYearly, "Annual price"), currency };
      check(await admin.from("plans").update({ ...after, updated_at: new Date().toISOString() }).eq("id", id));
      return { planId: id, before, after };
    },

    voice_pricing_list: async () => ({ rows: check(await admin.from("voice_pricing").select("*").order("effective_from", { ascending: false }).limit(100)) ?? [] }),

    voice_pricing_add: async () => {
      const provider = k.text(fields.provider, 20);
      if (!VOICE_PROVIDERS.includes(provider)) throw new k.InputError("Choose a provider");
      const unit = Number(fields.unitCost);
      if (!isFinite(unit) || unit < 0 || unit > 100) throw new k.InputError("Enter the price per minute");
      const inc = Number(fields.incrementSeconds ?? 60);
      if (!Number.isInteger(inc) || inc < 1 || inc > 3600) throw new k.InputError("Billing increment must be 1 to 3600 seconds");
      const currency = k.text(fields.currency, 3).toUpperCase() || "USD";
      if (!CURRENCIES.includes(currency)) throw new k.InputError("Choose a supported currency");
      const from = iso(fields.effectiveFrom, "Effective date", k) ?? new Date().toISOString();
      const row = check(await admin.from("voice_pricing").insert({ provider, unit_cost: unit, currency, billing_increment_seconds: inc, effective_from: from,
        note: k.text(fields.note, 200) || null, created_by: ctx.userId }).select("*").single());
      return { row };
    },

    usage_summary: async () => {
      const from = iso(fields.from, "From", k) ?? since(30);
      const to = iso(fields.to, "To", k) ?? new Date().toISOString();
      const [voice, usage] = await Promise.all([
        admin.rpc("zella_voice_usage_summary", { p_from: from, p_to: to }),
        admin.from("usage_records").select("usage_type, quantity, unit").gte("created_at", from).lt("created_at", to).limit(5000),
      ]);
      if (voice.error) throw voice.error;
      const byType: Record<string, number> = {};
      for (const u of (usage.data ?? []) as { usage_type: string; quantity: number }[]) byType[u.usage_type] = (byType[u.usage_type] ?? 0) + Number(u.quantity ?? 0);
      return { from, to, voice: voice.data, providerReported: byType, providerReportedAvailable: Object.keys(byType).length > 0 };
    },

    numbers_list: async () => {
      const rows = (check(await admin.from("business_phone_numbers").select("id, business_id, e164, vapi_phone_number_id, label, status, created_at").order("created_at", { ascending: false }).limit(500)) ?? []) as { business_id: string }[];
      const n = await names(admin, rows.map((r) => r.business_id));
      return { rows: rows.map((r) => ({ ...r, business_name: n[r.business_id] ?? null })), telnyx: Boolean(Deno.env.get("TELNYX_API_KEY")), vapi: Boolean(Deno.env.get("VAPI_API_KEY")) };
    },

    number_assign: async () => {
      const businessId = k.requireId(fields.businessId);
      const e164 = k.text(fields.e164, 20).replace(/[\s()-]/g, "");
      if (!/^\+[1-9]\d{7,14}$/.test(e164)) throw new k.InputError("Enter the number with its country code, like +15551234567");
      const vapi = k.text(fields.vapiPhoneNumberId, 100) || null;
      const id = k.text(fields.id, 64);
      const row = { business_id: businessId, e164, vapi_phone_number_id: vapi, label: k.text(fields.label, 60) || null };
      let before = null;
      if (id) {
        before = check(await admin.from("business_phone_numbers").select("business_id, e164, status").eq("id", k.requireId(id, "number")).maybeSingle());
        if (!before) throw new k.InputError("Number not found", 404);
      }
      const res = id ? await admin.from("business_phone_numbers").update(row).eq("id", id).select("id").single()
        : await admin.from("business_phone_numbers").insert({ ...row, status: "active" }).select("id").single();
      if (res.error) {
        const m = String((res.error as { message?: string }).message ?? "");
        if (m.includes("PHONE_NUMBER_LIMIT_REACHED")) throw new k.InputError("That business's plan doesn't include another phone number", 409);
        if (m.includes("duplicate")) throw new k.InputError("This number is already assigned", 409);
        throw res.error;
      }
      return { id: res.data.id, before, after: row, reason: k.text(fields.reason, 300) || null };
    },

    number_set_status: async () => {
      const id = k.requireId(fields.id, "number");
      const status = k.text(fields.status, 10);
      if (!["active", "paused"].includes(status)) throw new k.InputError("Choose active or paused");
      const reason = k.text(fields.reason, 300);
      if (reason.length < 3) throw new k.InputError("Give a reason (kept in the audit log)");
      const before = check(await admin.from("business_phone_numbers").select("business_id, e164, status").eq("id", id).maybeSingle());
      if (!before) throw new k.InputError("Number not found", 404);
      const res = await admin.from("business_phone_numbers").update({ status }).eq("id", id);
      if (res.error) {
        if (String((res.error as { message?: string }).message).includes("PHONE_NUMBER_LIMIT_REACHED")) throw new k.InputError("That business's plan doesn't include another active number", 409);
        throw res.error;
      }
      return { id, before, after: { status }, reason };
    },

    comms_overview: async () => {
      const [smsFailed, smsSent, emailEvents, optOuts, templates] = await Promise.all([
        admin.from("sms_messages").select("id", { count: "exact", head: true }).eq("direction", "outbound").eq("status", "failed").gte("created_at", since(7)),
        admin.from("sms_messages").select("id", { count: "exact", head: true }).eq("direction", "outbound").gte("created_at", since(7)),
        admin.from("email_events").select("type, created_at").gte("created_at", since(30)).limit(5000),
        admin.from("contact_consents").select("id", { count: "exact", head: true }).eq("status", "opted_out"),
        admin.from("message_templates").select("id, key, channel, purpose, locale, subject, body, version, status, created_at").is("business_id", null).order("key").limit(200),
      ]);
      const byType: Record<string, number> = {};
      for (const e of (emailEvents.data ?? []) as { type: string }[]) byType[e.type] = (byType[e.type] ?? 0) + 1;
      const s = await Promise.all(["sms_live", "email_live", "sms_from_number", "email_from_address"].map((key) => setting(admin, key)));
      return {
        sms: { live: s[0]?.value === true, from: s[2]?.value || null, sent7d: smsSent.count ?? 0, failed7d: smsFailed.count ?? 0, provider: "Telnyx", configured: Boolean(Deno.env.get("TELNYX_API_KEY")) },
        email: { live: s[1]?.value === true, from: s[3]?.value || null, events30d: byType, provider: "Resend" },
        optOuts: optOuts.count ?? 0,
        templates: templates.data ?? [],
      };
    },

    automation_overview: async () => {
      const [execs, dead, dispatch, failed] = await Promise.all([
        admin.from("workflow_executions").select("workflow_key, status, started_at, finished_at, retry_count").gte("started_at", since(7)).limit(10000),
        admin.from("automation_dead_letters").select("id", { count: "exact", head: true }),
        admin.from("n8n_dispatch_state").select("*"),
        admin.from("workflow_executions").select("id, business_id, workflow_key, status, error_category, error_message, retry_count, needs_manual, started_at, correlation_id").eq("status", "failed").order("started_at", { ascending: false }).limit(25),
      ]);
      const by: Record<string, { total: number; failed: number; ms: number; timed: number }> = {};
      for (const e of (execs.data ?? []) as { workflow_key: string; status: string; started_at: string; finished_at: string | null }[]) {
        const r = by[e.workflow_key] ??= { total: 0, failed: 0, ms: 0, timed: 0 };
        r.total++; if (e.status === "failed") r.failed++;
        if (e.finished_at) { r.ms += new Date(e.finished_at).getTime() - new Date(e.started_at).getTime(); r.timed++; }
      }
      const n = await names(admin, ((failed.data ?? []) as { business_id: string }[]).map((f) => f.business_id));
      return {
        workflows: Object.entries(by).map(([key, r]) => ({ key, total: r.total, failed: r.failed, avgSeconds: r.timed ? Math.round(r.ms / r.timed / 100) / 10 : null })),
        deadLetters: dead.count ?? 0,
        dispatch: dispatch.data ?? [],
        failures: ((failed.data ?? []) as Json[]).map((f) => ({ ...f, business_name: n[f.business_id as string] ?? null, error_message: f.error_message ? String(f.error_message).slice(0, 200) : null })),
        n8n: { url: Boolean(Deno.env.get("N8N_WEBHOOK_URL")), dispatchEnabled: (await setting(admin, "n8n_dispatch_enabled"))?.value !== false, baseUrlSet: Boolean((await setting(admin, "n8n_base_url"))?.value) },
      };
    },

    security_overview: async () => {
      const [rls, leak, secrets, recent, admins] = await Promise.all([
        admin.rpc("zella_rls_coverage"),
        admin.rpc("zella_tenant_leak_check"),
        admin.from("integration_secrets").select("integration_id", { count: "exact", head: true }),
        admin.from("audit_logs").select("action, user_id, business_id, created_at").or("action.like.platform.%,action.like.admin%,action.like.business.suspend%,action.like.session.%,action.like.roles%").order("created_at", { ascending: false }).limit(20),
        admin.from("platform_admins").select("user_id").eq("is_active", true),
      ]);
      const info = await emails(admin, ((admins.data ?? []) as { user_id: string }[]).map((a) => a.user_id));
      return {
        rls: rls.error ? null : rls.data, leak: leak.error ? null : leak.data,
        integrationSecrets: secrets.count ?? 0, recent: recent.data ?? [],
        adminsWithoutMfa: Object.values(info).filter((a) => !a.mfa).length, adminCount: Object.keys(info).length,
      };
    },

    privacy_overview: async () => {
      const rows = (check(await admin.from("data_rights_requests").select("kind, status, due_at")) ?? []) as { kind: string; status: string; due_at: string }[];
      const keys = await Promise.all(["retention_days", "payment_grace_days", "payment_suspend_after_days"].map((key) => setting(admin, key)));
      return {
        requests: { open: rows.filter((r) => r.status === "open").length, overdue: rows.filter((r) => r.status === "open" && r.due_at < new Date().toISOString()).length,
          byKind: rows.reduce((a, r) => { a[r.kind] = (a[r.kind] ?? 0) + 1; return a; }, {} as Record<string, number>) },
        retentionDays: keys[0]?.value ?? 90,
      };
    },

    alerts_list: async () => {
      let q = admin.from("platform_alerts").select("id, kind, severity, business_id, title, detail, status, occurrences, first_seen_at, last_seen_at, notified_at, acknowledged_at, resolved_at, resolution_note", { count: "exact" });
      const status = k.text(fields.status, 20); if (status) q = q.eq("status", status);
      const { data, count, error } = await q.order("last_seen_at", { ascending: false }).range(page * size, page * size + size - 1);
      if (error) throw error;
      const n = await names(admin, (data ?? []).map((a) => a.business_id));
      return { total: count ?? 0, page, size, rows: (data ?? []).map((a) => ({ ...a, business_name: n[a.business_id] ?? null })) };
    },

    alert_set: async () => {
      const id = k.requireId(fields.id, "alert");
      const status = k.text(fields.status, 20);
      if (!["acknowledged", "resolved"].includes(status)) throw new k.InputError("Choose acknowledge or resolve");
      const ok = check(await admin.rpc("zella_set_alert_status", { p_id: id, p_status: status, p_user: ctx.userId, p_note: k.text(fields.note, 300) || null }));
      if (!ok) throw new k.InputError("This alert is already resolved", 409);
      return { id, status };
    },

    analytics_overview: async () => {
      const [biz, subs, calls, execs, ints] = await Promise.all([
        admin.from("businesses").select("created_at, cancelled_at"),
        admin.from("subscriptions").select("created_at, status"),
        admin.from("calls").select("created_at, ai_handled").gte("created_at", since(180)).limit(50000),
        admin.from("workflow_executions").select("status").gte("started_at", since(30)).limit(50000),
        admin.from("integrations").select("status"),
      ]);
      const month = (d: string) => d.slice(0, 7);
      const months = [...Array(6)].map((_, i) => { const d = new Date(); d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() - 5 + i); return d.toISOString().slice(0, 7); });
      const count = (rows: { created_at: string }[], m: string) => rows.filter((r) => month(r.created_at) === m).length;
      const B = (biz.data ?? []) as { created_at: string; cancelled_at: string | null }[];
      const E = (execs.data ?? []) as { status: string }[];
      const I = (ints.data ?? []) as { status: string }[];
      const C = (calls.data ?? []) as { created_at: string; ai_handled: boolean }[];
      return {
        months: months.map((m) => ({ month: m, businesses: count(B, m), subscriptions: count((subs.data ?? []) as { created_at: string }[], m), aiCalls: C.filter((c) => c.ai_handled && month(c.created_at) === m).length })),
        businesses: { total: B.length, cancelled: B.filter((b) => b.cancelled_at).length },
        automation30d: { total: E.length, succeeded: E.filter((e) => e.status === "succeeded").length, failed: E.filter((e) => e.status === "failed").length },
        integrations: { total: I.length, failing: I.filter((i) => ["error", "disconnected"].includes(i.status)).length },
      };
    },

    data_quality: async () => {
      const [dups, noBiz, unmatched, incomplete, usageNoSub] = await Promise.all([
        admin.from("duplicate_reviews").select("id", { count: "exact", head: true }).eq("status", "open"),
        admin.from("business_members").select("id", { count: "exact", head: true }).is("business_id", null),
        admin.from("billing_events").select("id", { count: "exact", head: true }).is("business_id", null),
        admin.from("businesses").select("id", { count: "exact", head: true }).is("cancelled_at", null).neq("onboarding_status", "active").lt("created_at", since(7)),
        admin.from("usage_records").select("id", { count: "exact", head: true }).is("subscription_id", null),
      ]);
      return { duplicatesOpen: dups.count ?? 0, membersWithoutBusiness: noBiz.count ?? 0, billingEventsUnmatched: unmatched.count ?? 0,
        onboardingStalled: incomplete.count ?? 0, usageWithoutSubscription: usageNoSub.count ?? 0 };
    },

    legal_list: async () => {
      const docs = (check(await admin.from("legal_documents").select("id, kind, version, title, body, status, requires_acceptance, effective_at, reviewed_by, reviewed_at, published_at, created_at, updated_at").order("kind").order("created_at", { ascending: false })) ?? []) as Json[];
      const acc = (check(await admin.from("legal_acceptances").select("document_id")) ?? []) as { document_id: string }[];
      return { docs: docs.map((d) => ({ ...d, acceptances: acc.filter((a) => a.document_id === d.id).length })), kinds: LEGAL_KINDS };
    },

    legal_save: async () => {
      const kind = k.text(fields.kind, 30);
      if (!LEGAL_KINDS.includes(kind)) throw new k.InputError("Choose a document type");
      const version = k.text(fields.version, 20);
      if (!/^[0-9A-Za-z.\-]{1,20}$/.test(version)) throw new k.InputError("Version can use letters, numbers, dots and dashes, like 1.0");
      const title = k.text(fields.title, 200);
      if (title.length < 3) throw new k.InputError("Enter a title");
      const row = { kind, version, title, body: k.text(fields.body, 200000), requires_acceptance: k.bool(fields.requiresAcceptance, false),
        effective_at: iso(fields.effectiveAt, "Effective date", k), updated_at: new Date().toISOString() };
      const id = k.text(fields.id, 64);
      if (id) {
        const before = check(await admin.from("legal_documents").select("status").eq("id", k.requireId(id, "document")).maybeSingle()) as { status: string } | null;
        if (!before) throw new k.InputError("Document not found", 404);
        if (before.status !== "draft") throw new k.InputError("Only drafts can be edited. Move it back to draft first.", 409);
        check(await admin.from("legal_documents").update(row).eq("id", id));
        return { id, created: false, kind, version };
      }
      const res = await admin.from("legal_documents").insert({ ...row, created_by: ctx.userId }).select("id").single();
      if (res.error) {
        if (String((res.error as { message?: string }).message).includes("duplicate")) throw new k.InputError("That version already exists for this document", 409);
        throw res.error;
      }
      return { id: res.data.id, created: true, kind, version };
    },

    legal_transition: async () => {
      const id = k.requireId(fields.id, "document");
      const to = k.text(fields.to, 20);
      const doc = check(await admin.from("legal_documents").select("id, kind, status, body, effective_at, reviewed_by").eq("id", id).maybeSingle()) as Json | null;
      if (!doc) throw new k.InputError("Document not found", 404);
      const now = new Date().toISOString();
      const allowed: Record<string, string[]> = { draft: ["in_review"], in_review: ["draft", "published"], published: ["retired"], retired: [] };
      if (!(allowed[doc.status as string] ?? []).includes(to)) throw new k.InputError(`A ${doc.status} document can't be moved to ${to}`, 409);
      if (to === "published") {
        if (!String(doc.body ?? "").trim()) throw new k.InputError("The document has no text");
        if (!doc.effective_at) throw new k.InputError("Set the effective date before publishing");
        if (!k.bool(fields.confirmReviewed, false)) throw new k.InputError("Confirm the text was reviewed (for example by your lawyer) before publishing");
        check(await admin.from("legal_documents").update({ status: "retired", updated_at: now }).eq("kind", doc.kind).eq("status", "published"));
        check(await admin.from("legal_documents").update({ status: "published", published_by: ctx.userId, published_at: now, reviewed_by: ctx.userId, reviewed_at: now, updated_at: now }).eq("id", id));
      } else {
        check(await admin.from("legal_documents").update({ status: to, updated_at: now }).eq("id", id));
      }
      return { id, from: doc.status, to };
    },

    dev_overview: async () => {
      const url = Deno.env.get("SUPABASE_URL") ?? "";
      const ref = (url.match(/^https:\/\/([a-z0-9]+)\.supabase\.co/) ?? [])[1] ?? null;
      const settings = (check(await admin.from("platform_settings").select("key, value, updated_at").order("updated_at", { ascending: false })) ?? []) as { key: string; value: unknown; updated_at: string }[];
      const history = check(await admin.from("audit_logs").select("action, user_id, new_data, old_data, created_at").in("action", ["platform.setting_updated", "platform.profile_updated", "platform.maintenance_updated", "platform.roles_updated"]).order("created_at", { ascending: false }).limit(25));
      return {
        projectRef: ref, environment: ref ? "production (Supabase project " + ref + ")" : "unknown",
        flags: settings.filter((s) => /_live$|_enabled$|_allowed$/.test(s.key)).map((s) => ({ key: s.key, on: s.value === true, updated_at: s.updated_at })),
        configVersion: settings[0]?.updated_at ?? null, history: history ?? [],
      };
    },
  };

  const audited: Record<string, (r: Json) => Json> = {
    roles_save: (r) => ({ action: "platform.roles_updated", entity_type: "platform_role", old_data: { role: r.role, permissions: r.before }, new_data: { role: r.role, permissions: r.after } }),
    platform_profile_save: (r) => ({ action: "platform.profile_updated", entity_type: "platform_setting", old_data: { section: r.section, value: r.before }, new_data: { section: r.section, value: r.value } }),
    maintenance_save: (r) => ({ action: "platform.maintenance_updated", entity_type: "platform_setting", old_data: r.before as Json, new_data: { ...(r.value as Json), reason: r.reason } }),
    plan_entitlements_save: (r) => ({ action: "plan.entitlements_updated", entity_type: "plan", entity_id: r.planId, old_data: r.before as Json, new_data: r.after as Json }),
    voice_pricing_add: (r) => ({ action: "billing.voice_pricing_added", entity_type: "voice_pricing", entity_id: (r.row as Json)?.id, new_data: r.row as Json }),
    number_assign: (r) => ({ action: "telephony.number_assigned", entity_type: "phone_number", entity_id: r.id, business_id: (r.after as Json)?.business_id, old_data: r.before as Json, new_data: { ...(r.after as Json), reason: r.reason } }),
    number_set_status: (r) => ({ action: "telephony.number_status", entity_type: "phone_number", entity_id: r.id, business_id: (r.before as Json)?.business_id, old_data: r.before as Json, new_data: { ...(r.after as Json), reason: r.reason } }),
    alert_set: (r) => ({ action: "platform.alert_" + r.status, entity_type: "platform_alert", entity_id: r.id }),
    legal_save: (r) => ({ action: r.created ? "legal.draft_created" : "legal.draft_updated", entity_type: "legal_document", entity_id: r.id, new_data: { kind: r.kind, version: r.version } }),
    legal_transition: (r) => ({ action: "legal." + r.to, entity_type: "legal_document", entity_id: r.id, old_data: { status: r.from }, new_data: { status: r.to } }),
  };

  return { handlers, audited, isOwner };
}
