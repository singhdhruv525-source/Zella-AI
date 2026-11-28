// Add ons on the Pay pages (owner decisions, 27 Nov 2026) and the required "I agree" words. Pure: no React, no network,
// unit tested in web/tests/glassCheckout.test.mjs. Every price here is the server's (zella_owner_addon_catalog); the
// page sends pack codes only, and the server prices them again.
import { consentText } from "../../supabase/functions/_shared/paymentConsent.js";

export { consentHash, consentText } from "../../supabase/functions/_shared/paymentConsent.js";

const UNIT = { minutes: "AI minutes", texts: "texts", emails: "emails" };
const SHORT = { minutes: "minutes", texts: "texts", emails: "emails" };
const ABOUT = {
  minutes: "Extra call time for your AI receptionist",
  texts: "Extra text messages to your customers",
  emails: "Extra emails to your customers",
};
export const GROUPS = [["minutes", "Minutes"], ["texts", "Texts"], ["emails", "Emails"]];
const CODE = /^[a-z]+_[0-9]+$/;

// "100 AI minutes"
export const addonName = (a) => `${Number(a?.quantity).toLocaleString("en-US")} ${UNIT[a?.resource] ?? a?.resource ?? ""}`.trim();
// "100 minutes", for "Plan paid. 100 minutes not added"
export const addonShort = (a) => `${Number(a?.quantity).toLocaleString("en-US")} ${SHORT[a?.resource] ?? a?.resource ?? ""}`.trim();
export const addonAbout = (a) => ABOUT[a?.resource] ?? "";

// The server's catalogue, cleaned: known resources, whole positive prices, valid codes, grouped minutes, texts, emails.
// Anything but a list is not a catalogue (review round 4): null, which the pages show as "not available right now",
// never as an empty offer; an empty list is an empty catalogue.
export function offerFrom(catalog) {
  if (!Array.isArray(catalog)) return null;
  return catalog.filter((a) => a && CODE.test(String(a.code)) && UNIT[a.resource] && Number.isInteger(Number(a.price_cents)) && Number(a.price_cents) > 0
    && Number.isInteger(Number(a.quantity)) && Number(a.quantity) > 0)
    .map((a) => ({ code: a.code, resource: a.resource, quantity: Number(a.quantity), price_cents: Number(a.price_cents) }));
}
export function groupOffer(offer) {
  return GROUPS.map(([resource, title]) => ({ resource, title, items: (offer ?? []).filter((a) => a.resource === resource).sort((x, y) => x.quantity - y.quantity) }))
    .filter((g) => g.items.length > 0);
}

// The ticked packs in the offer, in the offer's order (codes not on offer are dropped)
export const chosen = (offer, codes) => (offer ?? []).filter((a) => (codes ?? []).includes(a.code));
export const addonsTotal = (offer, codes) => chosen(offer, codes).reduce((s, a) => s + a.price_cents, 0);
export const toggle = (codes, code, on) => (on ? [...new Set([...(codes ?? []), code])] : (codes ?? []).filter((c) => c !== code)).sort();
// a stable key for a selection: the onboarding session must be made again when it changes
export const selectionKey = (codes) => [...new Set(codes ?? [])].sort().join(",");

// The words for the onboarding payment (todayMinor: everything due today, addonsMinor: the add ons in it), for Pay now
// (the plan on this card, the add ons on the saved card right after) and for one pack
export const planConsent = ({ todayMinor, autopay, renewalMinor, addonsMinor = 0 }) => consentText({ kind: "plan", todayMinor, autopay, renewalMinor, addonsMinor });
export const invoiceConsent = ({ planMinor, addonsMinor = 0, autopay, renewalMinor }) => consentText({ kind: "invoice", todayMinor: planMinor, addonsMinor, autopay, renewalMinor });
export const packConsent = (priceMinor) => consentText({ kind: "pack", todayMinor: priceMinor });

// One key per add on, made when Pay is first pressed and kept on retry and reload (sessionStorage, per payment): the
// same key always reaches the same purchase, never a second charge.
const newKey = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`).replace(/[^A-Za-z0-9_-]/g, "");
export function addonKeys(storeKey, codes, storage = globalThis.sessionStorage) {
  let kept = {};
  try { kept = JSON.parse(storage?.getItem(storeKey) ?? "{}") ?? {}; } catch { kept = {}; }
  const out = {};
  for (const c of codes ?? []) out[c] = typeof kept[c] === "string" && /^[A-Za-z0-9_-]{8,100}$/.test(kept[c]) ? kept[c] : `addon-${newKey()}`.slice(0, 100);
  try { storage?.setItem(storeKey, JSON.stringify({ ...kept, ...out })); } catch { /* private mode: the keys live for this page only */ }
  return out;
}

// After the plan payment (Pay now): each agreed add on's state, from the server's list (zella_owner_invoice_pay_status)
//   todo     not bought yet (the page buys it now, with its key)
//   adding   bought, Stripe is taking it
//   added    granted
//   failed   not added: Try again for this pack only (a declined card opens its own pack page)
// The add on rows shown after Pay now: the server's list, with this page's own failures (and their words) on top. The
// server's "granted" always wins (a lost answer for a purchase that went through; review round 3); otherwise a local
// failure stays until the server says otherwise.
export function addonRows(list, local = {}) {
  return (Array.isArray(list) ? list : []).map((a) => (addonStep(a) === "added"
    ? { ...a, step: "added", words: undefined }
    : { ...a, step: local[a.code]?.step ?? addonStep(a), words: local[a.code]?.words }));
}

export function addonStep(a) {
  if (!a?.purchase_id) return "todo";
  if (a.status === "granted") return "added";
  if (a.status === "failed" || a.status === "cancelled") return "failed";
  return "adding";
}
