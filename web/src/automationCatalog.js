// One list of automations, used by the setup wizard, the admin's business page and the business app,
// so all three show the same names, the same order and the same "Preferred for this business" label.
import { automationDefaultsFor } from "./industryAutomations";

// [type, title(appointmentWord), description(appointmentWord)]
export const CATALOG = [
  ["appointment_reminder", (a) => `${a} reminders`, (a) => `Remind customers before their ${a}.`],
  ["appointment_confirmation", () => "Confirmation & check-in", (a) => `Ask customers to confirm their ${a}.`],
  ["no_show_follow_up", () => "No-show follow-up", (a) => `Reach out when someone misses their ${a} and offer to rebook.`],
  ["missed_call_follow_up", () => "Missed-call recovery", () => "Call back anyone whose call was missed."],
  ["new_lead_callback", () => "New lead callback", () => "Call new leads from Meta, the website and other sources."],
  ["post_appointment_follow_up", (a) => `After-${a.toLowerCase()} follow-up`, () => "Thank customers and ask for feedback."],
  ["quote_follow_up", () => "Quote follow-up", () => "Check in with people who were sent a quote and haven't replied."],
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

export const catalogEntry = (type) => CATALOG.find(([k]) => k === type);
