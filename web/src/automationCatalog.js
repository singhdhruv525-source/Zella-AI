// One list of automations, used by the setup wizard, the admin's business page and the business app,
// so all three show the same names, the same order and the same "Preferred for this business" label.
import { automationDefaultsFor } from "./industryAutomations";

// A title always starts with a capital, whatever case the business's appointment word is in ("visit" or "Visit").
const cap = (word) => String(word ?? "").replace(/^./, (c) => c.toUpperCase());

// [type, title(appointmentWord), description(appointmentWord)]
export const CATALOG = [
  ["appointment_reminder", (a) => `${cap(a)} reminders`, (a) => `Remind customers before their ${a}.`],
  ["appointment_confirmation", () => "Confirmation and check in", (a) => `Ask customers to confirm their ${a}.`],
  ["no_show_follow_up", () => "No show follow up", (a) => `Reach out when someone misses their ${a} and offer to rebook.`],
  ["missed_call_follow_up", () => "Missed call recovery", () => "Call back anyone whose call was missed."],
  ["new_lead_callback", () => "New lead callback", () => "Call new leads from Meta, the website and other sources."],
  ["post_appointment_follow_up", (a) => `Follow up after ${a.toLowerCase()}`, () => "Thank customers and ask for feedback."],
  ["quote_follow_up", () => "Quote follow up", () => "Check in with people who were sent a quote and haven't replied."],
  ["lead_reactivation", () => "Win back quiet customers", () => "Reach out to people you haven't heard from in a while."],
  ["waitlist_offer", () => "Waitlist offers", (a) => `When ${/^[aeiou]/i.test(a) ? "an" : "a"} ${a} opens up, offer it to people waiting.`],
  ["staff_unavailable", () => "Team member unavailable", (a) => `Offer another time when a ${a} can't go ahead.`],
];

// Rules added for a business's industry (see sql/zella_industry_engine.sql). All of them are "preferred".
export const INDUSTRY_RULE_TYPES = ["record_status_action", "record_due_reminder", "record_stale", "appointment_followup", "seasonal_reminder", "service_due"];

// How the owner hears about what an automation did.
export const NOTIFY_OPTIONS = [["sms", "Text"], ["email", "Email"], ["both", "Text and email"]];
export const NOTIFY_LABEL = Object.fromEntries(NOTIFY_OPTIONS);

export function isPreferred(type, industryName) {
  if (INDUSTRY_RULE_TYPES.includes(type)) return true;
  return Boolean(automationDefaultsFor(industryName)[type]?.enabled);
}

// Preferred first, then the rest, each group keeping the order above. Unknown types go last.
export function orderTypes(types, industryName) {
  const rank = (t) => { const i = CATALOG.findIndex(([k]) => k === t); return i === -1 ? 999 : i; };
  return [...types].sort((a, b) => (isPreferred(b, industryName) - isPreferred(a, industryName)) || (rank(a) - rank(b)));
}

// One status language for automations everywhere (OPS-22, docs/ZELLA_STATUS_LANGUAGE_GUIDE.md): the stored
// status, the word admins see and the pill tone. "disabled" is "Turned off", never "off" or "Archived".
export const AUTOMATION_STATUS = {
  active: { label: "Active", tone: "success" },
  paused: { label: "Paused", tone: "warning" },
  disabled: { label: "Turned off", tone: "neutral" },
};

// The pill for a stored status; an unknown status still reads as words.
export function automationStatusPill(status) {
  return AUTOMATION_STATUS[status] ?? { label: String(status ?? "Unknown").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase()), tone: "neutral" };
}

export const catalogEntry = (type) => CATALOG.find(([k]) => k === type);
