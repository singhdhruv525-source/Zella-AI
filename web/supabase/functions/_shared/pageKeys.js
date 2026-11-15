// Notification page keys -> the business app's pages (web/src/BusinessApp.jsx KNOWN_PAGES). Some notifications were
// written with older or broader names; they open the page that holds that work. Shared by the bell and email links.
export const PAGE_ALIAS = { on_call: "team", home: "today", dashboard: "today", appointments: "calendar" };
export const pageFor = (key) => {
  const k = String(key ?? "").trim().replace(/^\/+|\/+$/g, "");
  if (!k) return "today";
  return PAGE_ALIAS[k] ?? k;
};
// The address of a page in the business app: /app is Today, /app/<page> otherwise. With a business id the link also
// opens that business (?business=<id>), so an email about business A never lands in business B; the app accepts it only
// for a business the person belongs to.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const appPath = (key, businessId) => {
  const p = pageFor(key);
  const path = p === "today" ? "/app" : `/app/${p}`;
  return UUID.test(String(businessId ?? "")) ? `${path}?business=${String(businessId).toLowerCase()}` : path;
};
