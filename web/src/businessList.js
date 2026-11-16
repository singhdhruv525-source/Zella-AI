// The admin Businesses list: filter choices, how each cell reads, and the fallback for an older server.
//
// The list comes from the businesses_list action (owner-provision-business/businesses.ts): the server searches,
// filters, sorts and pages, and its totals are exact. A server deployed before that action answers 400 "Unknown
// action"; then, and only then, the page falls back to dashboard_data (one unpaged list, filtered here, with no plans,
// problems or last calls). Any other error is shown as an error, never as a shorter list.
import { businessState, setupDone, timeAgo, formatDateTime } from "./ownerFormat.js";
import { humanize } from "./copy/labels.js";

export const STAGE_OPTIONS = [
  ["draft", "Draft"],
  ["complete", "Setup complete"],
  ["live", "Live"],
  ["paused", "Paused"],
  ["failed", "Setup failed"],
  ["cancelling", "Canceling"],
  ["suspended", "Suspended"],
  ["cancelled", "Canceled"],
];
export const PLAN_OPTIONS = [["pro", "Pro"], ["base", "Base"], ["none", "Without a plan"]];
export const SORT_OPTIONS = [["newest", "Newest first"], ["oldest", "Oldest first"], ["name", "Name, A to Z"], ["problems", "Most problems"]];
export const PAGE_SIZE = 25;
export const EMPTY_FILTERS = { industryId: "", stage: "", plan: "", problem: false, sort: "newest" };

// The older server's list can't filter by plan or problem or sort by problems, so those are dropped when it takes over.
export const legacyFilters = (f) => ({ ...f, plan: "", problem: false, sort: f.sort === "problems" ? "newest" : f.sort });
export const legacyIgnores = (f) => Boolean(f.plan || f.problem || f.sort === "problems");

export const hasFilters = (search, f) => Boolean(String(search ?? "").trim() || f.industryId || f.stage || f.plan || f.problem);

// What businesses_list is asked for.
export function listRequest(search, f, page) {
  const out = { q: String(search ?? "").trim().slice(0, 80), sort: f.sort || "newest", page, size: PAGE_SIZE };
  if (f.industryId) out.industryId = f.industryId;
  if (f.stage) out.stage = f.stage;
  if (f.plan) out.plan = f.plan;
  if (f.problem) out.problem = true;
  return out;
}

// The old deployed function refuses an action it doesn't know with 400 {error: "Unknown action"} and no code.
export const isUnknownAction = (error) => error?.status === 400 && error?.message === "Unknown action";

// A businesses_list answer this page can read: anything else (an empty or odd answer) is an error, not "no businesses".
export function readList(data) {
  if (!data || !Array.isArray(data.rows) || typeof data.total !== "number") throw new Error("The server's answer couldn't be read. Try again.");
  return {
    mode: "server",
    rows: data.rows,
    total: data.total,
    page: Number(data.page) || 0,
    industries: Array.isArray(data.industries) ? data.industries : [],
    stats: data.stats && typeof data.stats === "object" ? data.stats : null,
    unavailable: Array.isArray(data.unavailable) ? data.unavailable : [],
  };
}

// The fallback: dashboard_data's unpaged list, shaped like businesses_list rows and filtered, sorted and paged here.
// Plans, problems and last calls are unknown (undefined), so they read "Not available", never "none".
export function legacyList(data, search, f, page) {
  if (!data || !Array.isArray(data.businesses)) throw new Error("The server's answer couldn't be read. Try again.");
  const industries = Array.isArray(data.industries) ? data.industries : [];
  const nameOf = new Map(industries.map((i) => [i.id, i.name]));
  const all = data.businesses.map((b) => {
    const state = businessState(b);
    const invite = (b.invitations ?? []).find((i) => i.status !== "revoked");
    const sub = b.subscriptions?.[0];
    return {
      ...b,
      industry_name: nameOf.get(b.industry_id) ?? (b.industry_name && b.industry_name !== "Unassigned" ? b.industry_name : null),
      stage: state.key, cancelling: Boolean(state.cancelling), setupDone: setupDone(b.onboarding_status),
      owner: invite ? { name: invite.owner_name ?? null, email: invite.email ?? null, status: invite.status,
        expired: invite.status === "expired" || (["sent", "pending"].includes(invite.status) && Boolean(invite.expires_at) && Date.parse(invite.expires_at) < Date.now()) } : null,
      subscription: sub ? { status: sub.status } : null,
      plan: undefined, problems: undefined, lastCallAt: undefined,
    };
  });
  const q = String(search ?? "").trim().toLowerCase();
  const matching = all.filter((b) => {
    if (f.industryId && b.industry_id !== f.industryId) return false;
    if (f.stage === "cancelling" ? !b.cancelling : f.stage && b.stage !== f.stage) return false;
    if (!q) return true;
    return [b.name, b.phone, b.industry_name, b.owner?.name, b.owner?.email].some((v) => String(v ?? "").toLowerCase().includes(q));
  });
  const sorters = {
    oldest: (a, b) => String(a.created_at ?? "").localeCompare(String(b.created_at ?? "")),
    name: (a, b) => String(a.name ?? "").localeCompare(String(b.name ?? ""), undefined, { sensitivity: "base" }),
  };
  const sorted = [...matching].sort(sorters[f.sort] ?? ((a, b) => String(b.created_at ?? "").localeCompare(String(a.created_at ?? ""))));
  const last = Math.max(0, Math.ceil(sorted.length / PAGE_SIZE) - 1);
  const at = Math.min(page, last);
  return {
    mode: "legacy",
    rows: sorted.slice(at * PAGE_SIZE, at * PAGE_SIZE + PAGE_SIZE),
    total: sorted.length,
    page: at,
    industries,
    stats: data.stats && typeof data.stats === "object" ? data.stats : null,
    unavailable: ["plans", "problems", "lastCalls"],
  };
}

const TIER = { base: "Base", pro: "Pro" };

// "Pro, v2" or "No plan saved". undefined means the plan couldn't be looked up.
export function planLabel(plan) {
  if (plan === undefined) return "Not available";
  if (!plan) return "No plan saved";
  const tier = TIER[plan.tier] ?? humanize(plan.tier);
  return plan.version ? `${tier}, v${plan.version}` : tier;
}

export function subscriptionLabel(subscription) {
  if (subscription === undefined) return "Subscription: Not available";
  if (!subscription?.status) return "No subscription";
  return `Subscription: ${humanize(subscription.status)}`;
}

// "Plans and subscriptions show as Not available." for the sources the server couldn't read.
const SOURCE_NAMES = [["plans", "plans"], ["subscriptions", "subscriptions"], ["problems", "problems"], ["lastCalls", "last calls"]];
export function unavailableNote(missing) {
  const names = SOURCE_NAMES.filter(([key]) => missing.has(key)).map(([, name]) => name);
  if (!names.length) return "";
  const list = names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
  return `${list[0].toUpperCase()}${list.slice(1)} show as Not available. Refresh to try again.`;
}

export function lastCallLabel(at) {
  if (at === undefined) return "Not available";
  if (!at) return "No calls yet";
  return timeAgo(at);
}
export const lastCallTitle = (at) => (at ? formatDateTime(at) : undefined);

// Problems: a count with the first one's title. null or undefined means they couldn't be looked up.
export function problemSummary(problems) {
  if (!problems) return { label: "Not available", tone: "neutral", detail: "", count: null };
  if (!problems.count) return { label: "No problems", tone: "success", detail: "", count: 0 };
  const urgent = problems.items?.some((p) => p.severity === "urgent");
  return {
    label: problems.count === 1 ? "1 open" : `${problems.count} open`,
    tone: urgent ? "danger" : "warning",
    detail: problems.items?.[0]?.title ?? "",
    count: problems.count,
  };
}

// The owner cell: one clear line when nobody has been invited, never "Not invited" over "None".
export function ownerCell(owner) {
  if (!owner) return { title: "No owner invited yet", sub: "", status: null };
  const status = owner.expired && owner.status !== "expired" ? "expired" : owner.status;
  return { title: owner.name || owner.email || "Owner", sub: owner.name ? owner.email ?? "" : "", status };
}

// The row's actions. "View" is the main one for any business that finished setup; "Continue setup" is the main one
// for a draft. Setup buttons need businesses.manage (the server checks again); a canceled business has none.
export function rowActions(row, canManage) {
  const finished = row.setupDone ?? setupDone(row.onboarding_status);
  const setup = canManage && row.stage !== "cancelled" ? (finished ? "Edit setup" : "Continue setup") : null;
  return { main: setup && !finished ? "setup" : "view", setup };
}
