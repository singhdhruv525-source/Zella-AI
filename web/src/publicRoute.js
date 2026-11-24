// Which top level page the address opens (App.jsx). Pure, so it is tested without a browser (publicRoute.test.mjs).
//
//   "app-home"    app.<domain>/ : the front page of the business CRM host opens /app
//   "continue"    /continue-plan, the link in the cancellation email
//   "broken-link" a customer link (/r/, /u/, /w/) cut short or mistyped
//   "reschedule", "unsubscribe", "waitlist"   complete customer links
//   "status", "privacy", "terms"               public pages
//   "business"    /app and /welcome, the business CRM and its email links
//   "admin"       / on any other host, and the admin dashboard's own pages (it shows its own "Page not found" inside)
//   "unknown"     anything else: "Page not found" for someone signed out (a signed in person keeps the dashboard)

// The admin dashboard's top level pages (the paths in NAVIGATION, OwnerDashboard.jsx). A signed out admin who opens a
// saved address for one of them gets the sign in, then that page. The test checks this list against NAVIGATION.
export const ADMIN_PAGES = ["businesses", "verification", "industries", "modules", "plans", "offers", "agents", "voice",
  "messaging", "operations", "automations", "integrations", "support", "security-abuse", "users", "audit-logs", "settings"];

export function publicRoute(pathname, hostname = "") {
  const path = typeof pathname === "string" && pathname ? pathname : "/";
  if (path === "/") return /^app\./i.test(String(hostname)) ? "app-home" : "admin";
  if (path.startsWith("/continue-plan")) return "continue";
  if (/^\/(r|u|w)(\/|$)/.test(path) && !/^\/(r|w)\/[0-9a-fA-F]{64}\/?$|^\/u\/[0-9a-fA-F]{32}\/?$/.test(path)) return "broken-link";
  if (/^\/r\/[0-9a-fA-F]{64}\/?$/.test(path)) return "reschedule";
  if (/^\/status\/?$/.test(path)) return "status";
  if (/^\/privacy\/?$/.test(path)) return "privacy";
  if (/^\/terms\/?$/.test(path)) return "terms";
  if (/^\/u\/[0-9a-fA-F]{32}\/?$/.test(path)) return "unsubscribe";
  if (/^\/w\/[0-9a-fA-F]{64}\/?$/.test(path)) return "waitlist";
  if (/^\/(app|welcome)(\/|$)/.test(path)) return "business";
  const first = path.split("/")[1] ?? "";
  if (ADMIN_PAGES.includes(first)) return "admin";
  return "unknown";
}
