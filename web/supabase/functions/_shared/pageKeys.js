// Notification page keys -> the business app's pages (web/src/BusinessApp.jsx KNOWN_PAGES). Some notifications were
// written with older or broader names; they open the page that holds that work. Shared by the bell and email links.
export const PAGE_ALIAS = { on_call: "team", home: "today", dashboard: "today", appointments: "calendar" };
export const pageFor = (key) => {
  const k = String(key ?? "").trim().replace(/^\/+|\/+$/g, "");
  if (!k) return "today";
  return PAGE_ALIAS[k] ?? k;
};
// The address of a page in the business app: /app is Today, /app/<page> otherwise.
export const appPath = (key) => { const p = pageFor(key); return p === "today" ? "/app" : `/app/${p}`; };
