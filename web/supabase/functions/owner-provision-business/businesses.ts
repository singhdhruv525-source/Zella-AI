// The admin Businesses list (action businesses_list, permission businesses.view in settings.ts).
//
// One page of businesses with search, filters, sort and exact totals. Every source is read in full, 1,000 rows at a
// time (allRows), so totals and statistics stay right above the API's 1,000 row limit (BIZ-15); filtering, sorting
// and paging then happen here, on the server, and only the asked for page goes to the browser. The last call is
// looked up for that page only (calls_business_created_idx).
//
// It runs after index.ts has checked the caller's sign in, two step sign in, platform role and permission. It
// returns each business's latest saved plan as tier, version and billing interval (no prices or allowances). This is
// new for businesses.view: tenants_search only shows the subscription's plan name and status, and no other
// businesses.view action reads business_plans. Every businesses.view role, read_only_admin included, sees it.

import type { SupabaseClient } from "@supabase/supabase-js";
import { allRows } from "./settings.ts";

type Json = Record<string, unknown>;
// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

export type ListKit = {
  text: (v: unknown, max?: number) => string;
  InputError: new (message: string, status?: number) => Error;
  UUID_RE: RegExp;
};

export const STAGES = ["draft", "complete", "live", "paused", "failed", "cancelling", "suspended", "cancelled"] as const;
export const SORTS = ["newest", "oldest", "name", "problems"] as const;
export const PLAN_FILTERS = ["base", "pro", "none"] as const;
export const PAGE_SIZES = [25, 50, 100] as const;

// Setup counts as finished from "testing" on, whatever the business's suspension or cancellation (BIZ-24).
const SETUP_DONE = ["testing", "ready", "active", "paused"];
export const setupDone = (status: unknown) => SETUP_DONE.includes(String(status ?? ""));

// The same buckets as businessState in web/src/ownerFormat.js: cancellation, then suspension, then the setup stage.
// Any status not listed (older ones such as plan_setup) is a draft, so no business falls out of every filter.
export function stageOf(b: Row): string {
  if (b.cancelled_at) return "cancelled";
  if (b.suspended_at) return "suspended";
  const s = b.onboarding_status;
  if (s === "active") return "live";
  if (s === "testing" || s === "ready") return "complete";
  if (s === "paused") return "paused";
  if (s === "failed") return "failed";
  return "draft";
}
export const isCancelling = (b: Row) => !b.cancelled_at && !b.suspended_at && Boolean(b.cancel_at);

export type ListQuery = {
  q: string; industryId: string | null; stage: string | null; plan: string | null; problem: boolean;
  sort: string; page: number; size: number;
};

export function parseQuery(fields: Json, k: ListKit): ListQuery {
  const industry = k.text(fields.industryId, 64);
  const stage = k.text(fields.stage, 20);
  const plan = k.text(fields.plan, 10);
  const sort = k.text(fields.sort, 20);
  const size = Number(fields.size);
  return {
    q: k.text(fields.q, 80).toLowerCase(),
    industryId: k.UUID_RE.test(industry) ? industry : null,
    stage: (STAGES as readonly string[]).includes(stage) ? stage : null,
    plan: (PLAN_FILTERS as readonly string[]).includes(plan) ? plan : null,
    problem: fields.problem === true,
    sort: (SORTS as readonly string[]).includes(sort) ? sort : "newest",
    page: Math.max(0, Math.min(10000, Math.floor(Number(fields.page) || 0))),
    size: (PAGE_SIZES as readonly number[]).includes(size) ? size : 25,
  };
}

export type Owner = { name: string | null; email: string | null; status: string; expired: boolean };
export type Problem = { kind: string; title: string; severity: string };

// The newest owner invitation that isn't revoked (as latestOwnerInvitation in ownerInvitation.ts), per business.
export function latestOwners(invitations: Row[], now: number): Map<string, Owner> {
  const out = new Map<string, Row>();
  for (const i of invitations) {
    if (i.status === "revoked") continue;
    const seen = out.get(i.business_id);
    if (!seen || String(i.created_at ?? "") > String(seen.created_at ?? "")) out.set(i.business_id, i);
  }
  return new Map([...out].map(([id, i]) => [id, {
    name: i.owner_name ?? null, email: i.email ?? null, status: i.status,
    expired: i.status === "expired" || (["sent", "pending"].includes(i.status) && Boolean(i.expires_at) && Date.parse(i.expires_at) < now),
  }]));
}

// The saved plan: the highest version per business (as zella_billing_plan_current).
export function latestPlans(plans: Row[]): Map<string, Row> {
  const out = new Map<string, Row>();
  for (const p of plans) {
    const seen = out.get(p.business_id);
    if (!seen || Number(p.version) > Number(seen.version)) out.set(p.business_id, p);
  }
  return out;
}

// Open problems of one business, one per kind, urgent first. A platform alert (open or acknowledged, warning or
// urgent; info alerts such as "business suspended" are not problems) wins over the same problem worked out here.
// The rest match Overview's "Needs attention": failed or expired owner invitation, an integration in error or
// disconnected, setup failed. A canceled business has no open problems.
const SAME_AS: Record<string, string> = { integration_disconnected: "integration_error" };
const RANK: Record<string, number> = { urgent: 0, warning: 1 };
export function problemsOf(b: Row, owner: Owner | undefined, alerts: Row[], failing: Row[]): Problem[] {
  if (b.cancelled_at) return [];
  const out = new Map<string, Problem>();
  for (const a of alerts) {
    const kind = SAME_AS[a.kind] ?? a.kind;
    const seen = out.get(kind);
    if (!seen || (RANK[a.severity] ?? 2) < (RANK[seen.severity] ?? 2)) out.set(kind, { kind, title: a.title || "Platform alert", severity: a.severity });
  }
  const add = (kind: string, title: string, severity: string) => { if (!out.has(kind)) out.set(kind, { kind, title, severity }); };
  if (owner?.status === "failed") add("invitation_failed", "The owner invitation failed", "warning");
  if (owner?.expired) add("invitation_expired", "The owner invitation expired", "warning");
  if (failing.length) add("integration_error", failing.length === 1 ? "An integration isn't working" : `${failing.length} integrations aren't working`, "warning");
  if (b.onboarding_status === "failed") add("setup_failed", "Setup failed", "urgent");
  return [...out.values()].sort((x, y) => (RANK[x.severity] ?? 2) - (RANK[y.severity] ?? 2));
}

export function matchesSearch(b: Row, q: string): boolean {
  if (!q) return true;
  const hay = [b.name, b.phone, b.industry_name, b.owner?.name, b.owner?.email];
  if (hay.some((v) => String(v ?? "").toLowerCase().includes(q))) return true;
  // A query that looks like a phone number matches on its digits, however either is written.
  if (!/^[\d\s()+.-]+$/.test(q)) return false;
  const digits = q.replace(/\D/g, "");
  return digits.length >= 3 && String(b.phone ?? "").replace(/\D/g, "").includes(digits);
}

export function matchesFilters(b: Row, f: ListQuery): boolean {
  if (f.industryId && b.industry_id !== f.industryId) return false;
  if (f.stage === "cancelling" ? !b.cancelling : f.stage && b.stage !== f.stage) return false;
  if (f.plan && (f.plan === "none" ? b.plan !== null : b.plan?.tier !== f.plan)) return false;
  if (f.problem && !b.problems.count) return false;
  return matchesSearch(b, f.q);
}

const byNewest = (a: Row, b: Row) => String(b.created_at ?? "").localeCompare(String(a.created_at ?? "")) || String(a.id).localeCompare(String(b.id));
const SORTERS: Record<string, (a: Row, b: Row) => number> = {
  newest: byNewest,
  oldest: (a, b) => -byNewest(a, b),
  name: (a, b) => String(a.name ?? "").localeCompare(String(b.name ?? ""), "en", { sensitivity: "base" }) || byNewest(a, b),
  problems: (a, b) => b.problems.count - a.problems.count
    || Number(b.problems.items.some((p: Problem) => p.severity === "urgent")) - Number(a.problems.items.some((p: Problem) => p.severity === "urgent"))
    || byNewest(a, b),
};
export const sortRows = (rows: Row[], sort: string) => [...rows].sort(SORTERS[sort] ?? byNewest);

// A source that may be missing: its failure is reported (unavailable) instead of failing the whole list.
async function optional(read: () => Promise<Row[]>): Promise<Row[] | null> {
  try { return await read(); } catch (e) { console.error("Businesses list lookup failed", e); return null; }
}

export async function businessesList(admin: SupabaseClient, fields: Json, k: ListKit, now = Date.now()) {
  const f = parseQuery(fields, k);
  const every = (table: string, columns: string, narrow: (q: Row) => Row = (q) => q) => () =>
    allRows((from, to) => narrow(admin.from(table).select(columns)).order("id").range(from, to));

  // Everything is read at once; a failure of the businesses, industries or owner invitations fails the page.
  const [core, plans, subscriptions, alerts, integrations] = await Promise.all([
    Promise.all([
      every("businesses", "id, name, industry_id, phone, timezone, onboarding_status, is_active, created_at, suspended_at, cancel_at, cancelled_at")(),
      every("industries", "id, name, slug, is_active")(),
      every("business_invitations", "id, business_id, email, owner_name, status, expires_at, created_at", (q) => q.eq("role", "owner"))(),
    ]).catch((e) => { console.error("Businesses list query failed", e); return null; }),
    optional(every("business_plans", "id, business_id, version, tier, billing_interval")),
    optional(every("subscriptions", "id, business_id, status")),
    optional(every("platform_alerts", "id, business_id, kind, title, severity",
      (q) => q.not("business_id", "is", null).in("status", ["open", "acknowledged"]).in("severity", ["warning", "urgent"]))),
    optional(every("integrations", "id, business_id, status", (q) => q.in("status", ["error", "disconnected"]))),
  ]);
  if (!core) throw new k.InputError("Businesses could not be loaded. Try again.", 500);
  const [businesses, industries, invitations] = core;

  const unavailable: string[] = [];
  if (!plans) unavailable.push("plans");
  if (!subscriptions) unavailable.push("subscriptions");
  if (!alerts || !integrations) unavailable.push("problems");
  if (f.plan && !plans) throw new k.InputError("Saved plans couldn't be loaded, so the plan filter can't be used right now. Try again.", 503);
  if ((f.problem || f.sort === "problems") && unavailable.includes("problems")) {
    throw new k.InputError("Problems couldn't be loaded, so that filter or sort can't be used right now. Try again.", 503);
  }

  const industryName = new Map(industries.map((i) => [i.id, i.name]));
  const owners = latestOwners(invitations, now);
  const planOf = latestPlans(plans ?? []);
  const subOf = new Map((subscriptions ?? []).map((s) => [s.business_id, s]));
  const group = (rows: Row[] | null) => {
    const m = new Map<string, Row[]>();
    for (const r of rows ?? []) {
      const list = m.get(r.business_id);
      if (list) list.push(r);
      else m.set(r.business_id, [r]);
    }
    return m;
  };
  const alertsOf = group(alerts), failingOf = group(integrations);

  const all = businesses.map((b) => {
    const owner = owners.get(b.id);
    const plan = planOf.get(b.id);
    const items = unavailable.includes("problems") ? [] : problemsOf(b, owner, alertsOf.get(b.id) ?? [], failingOf.get(b.id) ?? []);
    return {
      ...b,
      industry_name: industryName.get(b.industry_id) ?? null,
      stage: stageOf(b), cancelling: isCancelling(b), setupDone: setupDone(b.onboarding_status),
      owner: owner ?? null,
      plan: plans ? (plan ? { tier: plan.tier, version: plan.version, billing_interval: plan.billing_interval } : null) : undefined,
      subscription: subscriptions ? (subOf.has(b.id) ? { status: subOf.get(b.id)?.status } : null) : undefined,
      problems: unavailable.includes("problems") ? null : { count: items.length, items: items.slice(0, 3) },
    } as Row;
  });

  const matching = sortRows(all.filter((b) => matchesFilters(b, f)), f.sort);
  const lastPage = Math.max(0, Math.ceil(matching.length / f.size) - 1);
  const page = Math.min(f.page, lastPage);
  const rows = matching.slice(page * f.size, page * f.size + f.size);

  // The last call, for this page only.
  const calls = await Promise.all(rows.map((r) =>
    admin.from("calls").select("created_at").eq("business_id", r.id).order("created_at", { ascending: false }).limit(1)));
  if (calls.some((c) => c.error)) { console.error("Businesses list last call lookup failed", calls.find((c) => c.error)?.error); unavailable.push("lastCalls"); }
  rows.forEach((r, i) => { r.lastCallAt = calls[i].error ? undefined : (calls[i].data?.[0]?.created_at ?? null); });

  const used = new Set(businesses.map((b) => b.industry_id));
  return {
    total: matching.length, page, size: f.size, sort: f.sort, unavailable,
    industries: industries.filter((i) => i.is_active || used.has(i.id))
      .sort((a, b) => String(a.name).localeCompare(String(b.name))).map(({ id, name, is_active }) => ({ id, name, is_active })),
    stats: {
      totalBusinesses: all.length,
      activeWorkspaces: all.filter((b) => b.is_active).length,
      pendingInvitations: all.filter((b) => !b.cancelled_at && b.owner && ["pending", "sent"].includes(b.owner.status) && !b.owner.expired).length,
      withProblems: unavailable.includes("problems") ? null : all.filter((b) => b.problems.count > 0).length,
    },
    rows,
  };
}
