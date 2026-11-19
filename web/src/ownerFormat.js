// Shared labels and formatting for the owner admin pages. Numbers, times, phones and time zones come from
// lib/format.js, re-exported here so pages have one import.
import { RESUME_AT, resumeStep } from "./wizardProgress.js";
import { formatRelative } from "./lib/format.js";

export { formatCount, formatRelative, formatPhone, formatTimeZone, formatDateTime as formatFullDateTime } from "./lib/format.js";

export const ACTION_LABELS = {
  "business.draft_created": "Created business draft",
  "business.updated": "Updated business details",
  "business.industry_changed": "Changed industry",
  "owner.saved": "Saved business owner",
  "terminology.updated": "Updated terminology",
  "modules.updated": "Updated modules",
  "ai_receptionist.updated": "Updated AI receptionist",
  "integrations.preferences_updated": "Updated phone & integrations",
  "automations.updated": "Updated automations",
  "invitation.sent": "Finished setup · invitation sent",
  "invitation.failed": "Finished setup · invitation failed",
  "setup.finished": "Finished setup",
  "industry.created": "Created industry",
  "industry.updated": "Updated industry configuration",
  "admin.added": "Added platform admin",
  "admin.reactivated": "Reactivated platform admin",
  "admin.updated": "Changed platform admin access",
  "ticket.created": "Created support ticket",
  "ticket.updated": "Updated support ticket",
  "plan.created": "Created plan",
  "plan.updated": "Updated plan",
  "business.suspended": "Suspended business",
  "business.reactivated": "Reactivated business",
  "business.cancellation_scheduled": "Scheduled cancellation",
  "business.cancellation_undone": "Undid cancellation",
  "business.cancelled": "Business canceled (end of month)",
  "invitation.resent": "Resent owner invitation",
  "business.continued_by_owner": "Owner continued their plan (email link)",
};

export function actionLabel(action) {
  return ACTION_LABELS[action] ?? String(action ?? "").replace(/[._]/g, " ");
}

// A draft's label names the wizard step it reopens at (RESUME_AT in wizardProgress.js), so "Draft · next: Team" is
// where "Continue setup" lands. The other stages have their own words.
const draftLabel = (status) => `Draft · next: ${resumeStep(status).label}`;
const DRAFT_STATUSES = Object.keys(RESUME_AT).filter((s) => RESUME_AT[s] !== "review");
export const STAGE_LABELS = {
  ...Object.fromEntries(DRAFT_STATUSES.map((s) => [s, draftLabel(s)])),
  testing: "Setup complete",
  ready: "Ready to go live",
  active: "Live",
  paused: "Paused",
  failed: "Failed",
  suspended: "Suspended",
  cancelled: "Canceled",
};

// A status with no label of its own (older ones such as plan_setup) reopens at the first step, so it says so.
export function stageLabel(status) {
  if (!status) return "Draft";
  return STAGE_LABELS[status] ?? draftLabel(status);
}

// The shared tone map (docs/DESIGN_SYSTEM.md, Badges): Live and Ready are success, Setup complete (testing) is in
// progress so info, every draft step is warning.
export function stageTone(status) {
  if (["active", "ready"].includes(status)) return "success";
  if (status === "cancelled") return "neutral";
  if (["suspended", "failed"].includes(status)) return "danger";
  if (status === "testing") return "info";
  return "warning";
}

export function formatDate(value) {
  if (!value) return "None";
  return new Date(value).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export function formatDateTime(value) {
  if (!value) return "None";
  return new Date(value).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

// "5 days ago", "Yesterday" (lib/format.js). Put formatDateTime in a title for the exact time.
export function timeAgo(value) {
  if (!value) return "None";
  return formatRelative(value) || "Not recorded";
}

export function formatDuration(seconds) {
  if (seconds == null) return "None";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

// Setup is finished from "testing" on, whatever happened to the business after (BIZ-24): a suspended business that
// finished setup offers "Edit setup", not "Continue setup". The same rule as setupDone in businesses.ts.
const SETUP_DONE = ["testing", "ready", "active", "paused"];
export const setupDone = (status) => SETUP_DONE.includes(status);

// The stage bucket the Businesses filters use; the same buckets as stageOf in businesses.ts.
function stageKey(status) {
  if (status === "active") return "live";
  if (status === "testing" || status === "ready") return "complete";
  if (status === "paused" || status === "failed") return status;
  return "draft";
}

// Overall state of a business: cancellation and suspension take priority over the setup stage for the label, never
// for whether setup is done.
export function businessState(business) {
  const status = business.onboarding_status;
  const done = setupDone(status);
  if (business.cancelled_at) {
    return { key: "cancelled", label: "Canceled", tone: "neutral", done };
  }
  if (business.suspended_at) {
    return { key: "suspended", label: "Suspended", tone: "danger", done };
  }
  const base = { key: stageKey(status), label: stageLabel(status), tone: stageTone(status), done };
  if (business.cancel_at) {
    return { ...base, cancelling: true, label: `${base.label} · cancels ${formatDate(business.cancel_at)}`, tone: "warning" };
  }
  return base;
}
