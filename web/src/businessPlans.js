// CFG-14: words for each business's own plan (business_plans), as the Plans page shows them.
// Prices are stored in US cents. Payments aren't connected, so these are what the business would be charged.

export function money(cents, currency = "USD") {
  if (typeof cents !== "number" || !Number.isFinite(cents)) return "Not set";
  return (cents / 100).toLocaleString("en-US", { style: "currency", currency: currency || "USD" });
}

const PER = { monthly: "a month", yearly: "a year", annual: "a year" };
export function priceText(plan) {
  if (!plan) return "No plan saved";
  const per = PER[plan.billingInterval] ?? plan.billingInterval;
  const fee = plan.setupFeeCents > 0 ? `, plus ${money(plan.setupFeeCents, plan.currency)} setup` : "";
  return `${money(plan.priceCents, plan.currency)} ${per}${fee}`;
}

const TIER = { base: "Base", pro: "Pro" };
export function tierText(plan) {
  if (!plan) return "No plan saved";
  const tier = TIER[plan.tier] ?? plan.tier;
  return `${tier}, version ${plan.version}${plan.versions > 1 ? ` of ${plan.versions}` : ""}`;
}

// The short label for a table cell ("Pro v3"); the drawer keeps the full "Pro, version 3 of 3".
export const tierName = (tier) => TIER[tier] ?? tier;
export function tierShort(plan) {
  if (!plan) return "";
  return `${tierName(plan.tier)} v${plan.version}`;
}

const n = (v) => (typeof v === "number" ? v.toLocaleString("en-US") : "Not set");
export function allowanceText(plan) {
  if (!plan) return "";
  return `${n(plan.minutes)} minutes · ${n(plan.texts)} texts · ${n(plan.emails)} emails`;
}

// Every allowance of one plan, as [label, value] rows for the details drawer.
export function planFacts(plan) {
  if (!plan) return [];
  return [
    ["Plan", tierText(plan)],
    ["Price", priceText(plan)],
    ["Free trial", plan.trialEnabled ? "Yes" : "No"],
    ["AI voice minutes per period", n(plan.minutes)],
    ["Texts per period", n(plan.texts)],
    ["Emails per period", n(plan.emails)],
    ["Team seats (including the owner)", n(plan.teamSeats)],
    ["Phone numbers", n(plan.phoneNumbers)],
    ["Business locations", n(plan.locations)],
    ["Languages", Array.isArray(plan.languages) && plan.languages.length ? plan.languages.map((l) => ({ en: "English", es: "Spanish" }[l] ?? l)).join(", ") : "Not set"],
    ["Extra minutes", typeof plan.overageCentsPerMinute === "number" ? `${money(plan.overageCentsPerMinute, plan.currency)} a minute` : "Not set"],
  ];
}

// One allowance bucket from zella_billing_overview, in words.
const RESOURCE = { minutes: "Minutes", texts: "Texts", emails: "Emails" };
const KIND = { plan: "this period", rollover: "rolled over", pack: "pack", buffer: "small extra" };
export function balanceText(b) {
  const what = `${RESOURCE[b.resource] ?? b.resource} (${KIND[b.kind] ?? b.kind}${b.pack ? `, ${b.pack}` : ""})`;
  return [what, `${n(b.remaining)} left of ${n(b.granted)}`];
}
