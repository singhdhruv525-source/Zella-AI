// Phone navigation (approved 25 Nov 2026, P1 to P29): which five tabs the bottom bar shows on a phone, as pure
// functions. The CRM tabs are built from buildNavigation()'s output (navConfig.js), so a tab can never open a page the
// menu hides for this person's role, this business's plan or its industry. The admin tabs come from the admin's own
// NAVIGATION list and the person's permissions. Every page stays in the side panel; the bar is a shortcut, never the
// only way in.
//
// CRM rule: Today | work | focus | Inbox | More. Today and Inbox are always there and More is always last.
//   work:  Dispatch (dispatch on) · Calendar (scheduling on) · the first Orders record type (orders on) · Leads
//   focus: Tables (tables on) · Check ins (clinic, dental or vet, with check ins on) · Leads (dispatch on) ·
//          Customers, named by the industry (Guests, Clients, Patients)
// A choice the person can't open is skipped and the next takes its place. The work tab always says "Calendar"
// (owner decision 3, 25 Nov 2026), whatever the industry calls a booking.
import { flatten } from "./navConfig.js";

// Under 768 wide: bottom bar and side panel. From 768 to 1023 the slim icon rail stays (owner decision 7).
export const PHONE_MAX = 767;
export const PHONE_QUERY = `(max-width: ${PHONE_MAX}px)`;

// Industries whose front desk runs on arrivals (todayConfig.js uses the same slugs).
const CLINICS = new Set(["dental", "healthcare", "pet-care-veterinary"]);
const RESTAURANTS = new Set(["restaurant"]);

export const MORE_TAB = { key: "more", label: "More", icon: "menu" };

// A count on a tab: plain numbers, capped at 99+, nothing for zero or an unknown count.
export function badgeText(count) {
  const n = Number(count);
  if (!Number.isFinite(n) || n <= 0) return "";
  return n > 99 ? "99+" : String(Math.floor(n));
}

// The tab's name for screen readers: the count is part of it ("Inbox, 2 waiting"). state "failed": the count couldn't
// be read; "stale": it is the last one read and may be out of date.
export function tabName(label, count, noun = "waiting", state = "ok") {
  if (state === "failed") return `${label}, count not available`;
  const text = badgeText(count);
  const name = text ? `${label}, ${text} ${noun}` : label;
  return state === "stale" ? `${name}, may be out of date` : name;
}

// Is a capability on? true or false when the database says; undefined on an older database without capability data.
function capability(capabilities, key) {
  if (!capabilities) return undefined;
  if (!capabilities[key]) return false;
  return Boolean(capabilities[key].enabled);
}

const tab = (item, label, icon) => item && { key: item.page, page: item.page, label: label ?? item.label, icon: icon ?? item.icon };

/**
 * The CRM's four page tabs (More is added by the bar).
 *   groups:       buildNavigation(access, term) for this business and person
 *   capabilities: zella_capabilities() result, or undefined on an older database
 *   industry:     the industry slug (restaurant, beauty-salon, dental, plumbing, ecommerce ...)
 *   recordTypes:  this business's record types (crm_record_types), for the Orders tab
 * Returns [{ key, page, label, icon }], in bar order, without duplicates.
 */
export function crmTabs({ groups = [], capabilities, industry, recordTypes = [] } = {}) {
  const items = flatten(groups);
  const find = (page) => items.find((i) => i.page === page) ?? null;
  const used = new Set();
  const first = (choices) => {
    for (const pick of choices) {
      const t = pick();
      if (t && !used.has(t.key)) { used.add(t.key); return t; }
    }
    return null;
  };

  const dispatchOn = Boolean(find("dispatch"));   // capabilityRequired: only listed once the database says it is on
  const orders = () => {
    if (capability(capabilities, "orders") !== true) return null;
    const type = recordTypes.find((t) => t.enabled && t.capability === "orders" && find(`rec:${t.key}`));
    return type ? tab(find(`rec:${type.key}`), type.plural, type.icon || "receipt_long") : null;
  };
  // Tables and check ins need the capability on. Without capability data (an older database) the industry decides,
  // so a dental clinic never gets a Tables tab just because nothing says tables are off.
  const tablesOn = () => {
    const on = capability(capabilities, "tables");
    return on === true || (on === undefined && RESTAURANTS.has(industry));
  };
  const checkinsOn = () => CLINICS.has(industry) && capability(capabilities, "checkins") !== false;

  const today = first([() => tab(find("today"))]);
  const work = first([
    () => tab(find("dispatch"), "Dispatch"),
    () => tab(find("calendar"), "Calendar"),
    orders,
    () => tab(find("leads"), "Leads"),
  ]);
  const focus = first([
    () => (tablesOn() ? tab(find("tables"), "Tables") : null),
    () => (checkinsOn() ? tab(find("checkins"), "Check ins") : null),
    () => (dispatchOn ? tab(find("leads"), "Leads") : null),
    () => tab(find("customers")),
    () => tab(find("leads"), "Leads"),
  ]);
  const inbox = first([
    () => tab(find("inbox"), "Inbox"),
    () => tab(find("attention"), "Inbox"),
    () => tab(find("messages"), "Inbox"),
  ]);
  return [today, work, focus, inbox].filter(Boolean);
}

// The admin bar: Overview | Businesses | Support | Operations | More (owner decision 4). A page the role can't open
// gives its place to the next allowed of Verification and Audit logs.
const ADMIN_PREFERRED = [
  ["Overview", "Overview", "space_dashboard"],
  ["Businesses", "Businesses", "storefront"],
  ["Support", "Support", "support_agent"],
  ["Platform operations", "Operations", "monitor_heart"],
];
const ADMIN_REPLACEMENTS = [
  ["Verification", "Verification", "verified_user"],
  ["Audit logs", "Audit logs", "history"],
];

/**
 * The admin's four page tabs (More is added by the bar).
 *   navigation: the admin NAVIGATION list ({ label, perm, path, ... })
 *   can:        (perm) => boolean, the person's permissions (null perm = everyone)
 * Returns [{ key, page, label, icon, path }]: key and page are the NAVIGATION label (the page's key).
 */
export function adminTabs(navigation = [], can = () => false) {
  const allowed = (label) => {
    const item = navigation.find((n) => n.label === label);
    return item && (!item.perm || can(item.perm)) ? item : null;
  };
  const spare = ADMIN_REPLACEMENTS.filter(([label]) => allowed(label));
  const out = [];
  for (const [label, short, icon] of ADMIN_PREFERRED) {
    const item = allowed(label);
    if (item) { out.push({ key: label, page: label, label: short, icon, path: item.path }); continue; }
    const next = spare.shift();
    if (next) {
      const [rLabel, rShort, rIcon] = next;
      out.push({ key: rLabel, page: rLabel, label: rShort, icon: rIcon, path: allowed(rLabel).path });
    }
  }
  return out;
}

// Which tab is selected: the tab for the open page, or More when the page came from the side panel (P4).
export function selectedTab(tabs, page) {
  return tabs.some((t) => t.key === page) ? page : MORE_TAB.key;
}
