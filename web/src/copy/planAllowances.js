// What a plan includes, in words. The keys are the ones plans.limits and the per business plans use
// (zella_plan_limits: voice_minutes, texts, emails, team_members, phone_numbers, locations, languages; the plan
// entitlements form: sms_messages, automations, integrations, reporting, support_level, onboarding). A key that isn't
// listed is still shown, in words, so no allowance the page receives is hidden (UI-12).
import { humanize } from "./labels.js";

// [key, label, kind]: "count" is a number (empty means no limit), "choice" a level (empty means not set).
export const PLAN_ALLOWANCES = [
  ["voice_minutes", "AI voice minutes per period", "count"],
  ["texts", "Texts per period", "count"],
  ["sms_messages", "Texts per period", "count"],
  ["emails", "Emails per period", "count"],
  ["phone_numbers", "Phone numbers", "count"],
  ["team_members", "Team seats (including the owner)", "count"],
  ["locations", "Business locations", "count"],
  ["languages", "Languages the AI receptionist speaks", "count"],
  ["automations", "Active automations", "count"],
  ["integrations", "Connected integrations", "count"],
  ["reporting", "Reporting", "choice"],
  ["support_level", "Support level", "choice"],
  ["onboarding", "Onboarding service", "choice"],
];
const KNOWN = new Map(PLAN_ALLOWANCES.map(([k, label, kind]) => [k, { label, kind }]));

const empty = (v) => v === null || v === undefined || v === "";

function valueText(v, kind) {
  if (empty(v)) return kind === "choice" ? "Not set" : "No limit";
  if (typeof v === "boolean") return v ? "Included" : "Not included";
  if (Array.isArray(v)) return v.length ? v.map(humanize).join(", ") : "None included";
  if (typeof v === "object") return Object.entries(v).map(([k, x]) => `${humanize(k)} ${valueText(x, "count")}`).join(", ");
  if (typeof v === "number" || /^\d+(\.\d+)?$/.test(String(v))) return Number(v).toLocaleString("en-US");
  return humanize(v);
}

// Every allowance a plan card shows, as [label, value] in a fixed order. The known count allowances are always
// listed (empty means no limit, as on the plan entitlements form); "texts" and "sms_messages" are one line, so the
// card never says the same thing twice. Then any other key the plan carries.
export function planAllowances(limits) {
  const l = limits && typeof limits === "object" && !Array.isArray(limits) ? limits : {};
  const rows = [];
  for (const [key, label, kind] of PLAN_ALLOWANCES) {
    if (key === "sms_messages" && (!empty(l.texts) || empty(l.sms_messages))) continue;
    if (key === "texts" && empty(l.texts) && !empty(l.sms_messages)) continue;
    if (kind === "choice" && empty(l[key])) continue;
    rows.push([label, valueText(l[key], kind)]);
  }
  for (const [key, v] of Object.entries(l)) {
    if (!KNOWN.has(key)) rows.push([humanize(key), valueText(v, "count")]);
  }
  return rows;
}

// A plan's features (plans.features) in words: a switch reads "Included" or "Not included".
export function planFeatures(features) {
  if (!features || typeof features !== "object") return [];
  if (Array.isArray(features)) return features.map((f) => [humanize(f), "Included"]);
  return Object.entries(features).map(([k, v]) => [humanize(k), valueText(v, "count")]);
}

// The label for one allowance key, for anywhere that lists them (the plan entitlements form).
export const allowanceLabel = (key) => KNOWN.get(key)?.label ?? humanize(key);
