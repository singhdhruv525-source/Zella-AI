// Phone navigation (approved 25 Nov 2026): the bottom bar's tab rule for each industry and each role, the admin's
// tabs for each permission set, and the pure helpers behind the gestures, the live strip, "Needs you now", the per
// tab memory and the Undo window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildNavigation, flatten } from "../src/navigation/navConfig.js";
import { MORE_TAB, PHONE_QUERY, adminTabs, badgeText, crmTabs, selectedTab, tabName } from "../src/navigation/phoneTabs.js";
import {
  adminStrip, createTabMemory, crmStrip, deferChange, keyboardOpen, needsNowRows, panelDrag, panelReleaseCloses,
  pullDistance, pullReleaseRefreshes, rowDrag, rowReleaseOpens, sheetRelease, waitLabel,
} from "../src/navigation/phoneHelpers.js";

const ROLES = ["owner", "admin", "manager", "staff", "viewer"];
const on = (...keys) => Object.fromEntries(keys.map((k) => [k, { enabled: true }]));
const off = (...keys) => Object.fromEntries(keys.map((k) => [k, { enabled: false }]));
const ALL_MODULES = new Set(["ai-receptionist", "automations", "calendar", "calls", "sms", "email"]);

// The industries the owner approved tabs for, with the capabilities each turns on by default.
const INDUSTRIES = {
  restaurant: { words: { customers: "Guests" }, capabilities: { ...on("scheduling", "checkins", "waitlist", "tables"), ...off("dispatch", "orders", "money") } },
  "beauty-salon": { words: { customers: "Clients" }, capabilities: { ...on("scheduling", "checkins", "waitlist"), ...off("tables", "dispatch", "orders") } },
  dental: { words: { customers: "Patients" }, capabilities: { ...on("scheduling", "checkins", "waitlist"), ...off("tables", "dispatch", "orders") } },
  healthcare: { words: { customers: "Patients" }, capabilities: { ...on("scheduling", "checkins"), ...off("tables", "dispatch", "orders") } },
  "pet-care-veterinary": { words: { customers: "Clients" }, capabilities: { ...on("scheduling", "checkins"), ...off("tables", "dispatch", "orders") } },
  plumbing: { words: { customers: "Customers" }, capabilities: { ...on("scheduling", "dispatch", "money"), ...off("tables", "checkins", "orders") } },
  hvac: { words: { customers: "Customers" }, capabilities: { ...on("scheduling", "dispatch"), ...off("tables", "checkins", "orders") } },
  "cleaning-services": { words: { customers: "Clients" }, capabilities: { ...on("scheduling", "dispatch"), ...off("tables", "checkins", "orders") } },
  ecommerce: {
    words: { customers: "Customers" }, capabilities: { ...on("orders", "money"), ...off("scheduling", "checkins", "tables", "dispatch") },
    recordTypes: [{ key: "orders", plural: "Orders", icon: "receipt_long", enabled: true, capability: "orders" }],
  },
};

function tabsFor(industry, role = "owner", { capabilities, recordTypes } = {}) {
  const cfg = INDUSTRIES[industry];
  const caps = capabilities === undefined ? cfg.capabilities : capabilities ?? undefined;
  const types = recordTypes ?? cfg.recordTypes ?? [];
  const term = (k) => cfg.words[k] ?? k;
  const groups = buildNavigation({ role, modules: ALL_MODULES, recordTypes: types, operationsLabel: "Operations", configured: true, capabilities: caps }, term);
  return { tabs: crmTabs({ groups, capabilities: caps, industry, recordTypes: types }), groups };
}
const labels = (tabs) => tabs.map((t) => t.label);

test("each approved industry gets its tabs (owner decisions 2 and 3, 25 Nov 2026)", () => {
  assert.deepEqual(labels(tabsFor("restaurant").tabs), ["Today", "Calendar", "Tables", "Inbox"]);
  assert.deepEqual(labels(tabsFor("beauty-salon").tabs), ["Today", "Calendar", "Clients", "Inbox"]);
  for (const clinic of ["dental", "healthcare", "pet-care-veterinary"]) {
    assert.deepEqual(labels(tabsFor(clinic).tabs), ["Today", "Calendar", "Check ins", "Inbox"], clinic);
  }
  for (const home of ["plumbing", "hvac", "cleaning-services"]) {
    assert.deepEqual(labels(tabsFor(home).tabs), ["Today", "Dispatch", "Leads", "Inbox"], home);
  }
  assert.deepEqual(labels(tabsFor("ecommerce").tabs), ["Today", "Orders", "Customers", "Inbox"]);
});

test("the work tab always says Calendar, whatever the industry calls a booking", () => {
  for (const industry of ["restaurant", "beauty-salon", "dental"]) {
    assert.equal(tabsFor(industry).tabs[1].label, "Calendar");
    assert.equal(tabsFor(industry).tabs[1].page, "calendar");
  }
});

test("every role gets only pages it can open, with no repeats, Today first and Inbox last", () => {
  for (const industry of Object.keys(INDUSTRIES)) {
    for (const role of ROLES) {
      const { tabs, groups } = tabsFor(industry, role);
      const pages = new Set(flatten(groups).map((i) => i.page));
      assert.ok(tabs.length >= 2 && tabs.length <= 4, `${industry} ${role}: ${tabs.length} tabs`);
      assert.equal(tabs[0].page, "today", `${industry} ${role}`);
      assert.equal(tabs.at(-1).label, "Inbox", `${industry} ${role}`);
      assert.equal(new Set(tabs.map((t) => t.key)).size, tabs.length, `${industry} ${role}: a repeated tab`);
      for (const t of tabs) assert.ok(pages.has(t.page), `${industry} ${role}: ${t.page} is not in this person's menu`);
    }
  }
});

test("a tab whose page the person can't open gives its place to the next choice", () => {
  const term = (k) => ({ customers: "Guests" }[k] ?? k);
  const caps = INDUSTRIES.restaurant.capabilities;
  const groups = buildNavigation({ role: "staff", modules: ALL_MODULES, recordTypes: [], configured: true, capabilities: caps }, term)
    .map((g) => ({ ...g, items: g.items.filter((i) => i.page !== "tables" && i.page !== "calendar") }));
  assert.deepEqual(labels(crmTabs({ groups, capabilities: caps, industry: "restaurant" })), ["Today", "Leads", "Guests", "Inbox"]);
  const noInbox = groups.map((g) => ({ ...g, items: g.items.map((i) => (i.children ? { ...i, children: i.children.filter((c) => c.page !== "inbox") } : i)) }));
  const inbox = crmTabs({ groups: noInbox, capabilities: caps, industry: "restaurant" }).at(-1);
  assert.equal(inbox.page, "attention");
  assert.equal(inbox.label, "Inbox");
});

test("tabs follow each business's own switches, not only its industry", () => {
  // a restaurant that turned tables off gets its guests instead
  assert.deepEqual(labels(tabsFor("restaurant", "owner", { capabilities: { ...INDUSTRIES.restaurant.capabilities, tables: { enabled: false } } }).tabs),
    ["Today", "Calendar", "Guests", "Inbox"]);
  // a clinic without check ins gets its patients
  assert.deepEqual(labels(tabsFor("dental", "owner", { capabilities: { ...INDUSTRIES.dental.capabilities, checkins: { enabled: false } } }).tabs),
    ["Today", "Calendar", "Patients", "Inbox"]);
  // a salon with check ins on still gets Clients (staff look clients up more often)
  assert.equal(tabsFor("beauty-salon").tabs[2].label, "Clients");
  // a shop without an orders record type falls back to Leads
  assert.deepEqual(labels(tabsFor("ecommerce", "owner", { recordTypes: [] }).tabs), ["Today", "Leads", "Customers", "Inbox"]);
  // an orders record type that is switched off doesn't count
  assert.deepEqual(labels(tabsFor("ecommerce", "owner", { recordTypes: [{ key: "orders", plural: "Orders", enabled: false, capability: "orders" }] }).tabs),
    ["Today", "Leads", "Customers", "Inbox"]);
});

test("an older database without capability data still gets sensible tabs", () => {
  assert.deepEqual(labels(tabsFor("restaurant", "owner", { capabilities: null }).tabs), ["Today", "Calendar", "Tables", "Inbox"]);
  assert.deepEqual(labels(tabsFor("dental", "owner", { capabilities: null }).tabs), ["Today", "Calendar", "Check ins", "Inbox"]);
  // Dispatch needs the database to say it is on, so a plumber on an old database sees Calendar and Customers
  assert.deepEqual(labels(tabsFor("plumbing", "owner", { capabilities: null }).tabs), ["Today", "Calendar", "Customers", "Inbox"]);
  // no Tables tab for a salon just because nothing says tables are off
  assert.deepEqual(labels(tabsFor("beauty-salon", "owner", { capabilities: null }).tabs), ["Today", "Calendar", "Clients", "Inbox"]);
});

test("nothing loaded yet means no tabs", () => {
  assert.deepEqual(crmTabs({ groups: [] }), []);
  assert.deepEqual(crmTabs(), []);
});

// The admin NAVIGATION list (OwnerDashboard.jsx): label, permission and path of each page the rule can use.
const ADMIN_NAV = [
  { label: "Overview", path: "/", perm: "businesses.view" },
  { label: "Businesses", path: "/businesses", perm: "businesses.view" },
  { label: "Verification", path: "/verification", perm: "businesses.manage" },
  { label: "Platform Operations", path: "/operations", perm: "businesses.view" },
  { label: "Support", path: "/support", perm: "support.manage" },
  { label: "Audit Logs", path: "/audit-logs", perm: "audit.view" },
  { label: "Settings", path: "/settings", perm: null },
];
const canAll = (...perms) => (p) => perms.includes(p);

test("admin: Overview, Businesses, Support and Operations for a full role (owner decision 4)", () => {
  const tabs = adminTabs(ADMIN_NAV, canAll("businesses.view", "businesses.manage", "support.manage", "audit.view"));
  assert.deepEqual(labels(tabs), ["Overview", "Businesses", "Support", "Operations"]);
  assert.deepEqual(tabs.map((t) => t.page), ["Overview", "Businesses", "Support", "Platform Operations"]);
});

test("admin: a page the role can't use is replaced by Verification, then Audit logs", () => {
  assert.deepEqual(labels(adminTabs(ADMIN_NAV, canAll("businesses.view", "businesses.manage", "audit.view"))),
    ["Overview", "Businesses", "Verification", "Operations"]);
  assert.deepEqual(labels(adminTabs(ADMIN_NAV, canAll("businesses.view", "audit.view"))), ["Overview", "Businesses", "Audit logs", "Operations"]);
  assert.deepEqual(labels(adminTabs(ADMIN_NAV, canAll("support.manage", "audit.view"))), ["Audit logs", "Support"]);
  assert.deepEqual(labels(adminTabs(ADMIN_NAV, canAll())), []);
});

test("the selected tab, and More for a page from the side panel", () => {
  const tabs = tabsFor("restaurant").tabs;
  assert.equal(selectedTab(tabs, "tables"), "tables");
  assert.equal(selectedTab(tabs, "settings"), MORE_TAB.key);
  assert.equal(PHONE_QUERY, "(max-width: 767px)");
});

test("counts are plain, capped at 99+ and part of the tab's name", () => {
  assert.equal(badgeText(0), "");
  assert.equal(badgeText(undefined), "");
  assert.equal(badgeText(-2), "");
  assert.equal(badgeText(7), "7");
  assert.equal(badgeText(99), "99");
  assert.equal(badgeText(100), "99+");
  assert.equal(tabName("Inbox", 2), "Inbox, 2 waiting");
  assert.equal(tabName("Support", 120, "open"), "Support, 99+ open");
  assert.equal(tabName("Today", 0), "Today");
});

const NOW = Date.parse("2026-11-25T18:00:00Z");
const ago = (min) => new Date(NOW - min * 60000).toISOString();

test("wait labels", () => {
  assert.equal(waitLabel(ago(4), NOW), "4 min");
  assert.equal(waitLabel(ago(0), NOW), "1 min");
  assert.equal(waitLabel(ago(-3), NOW), "1 min");
  assert.equal(waitLabel(ago(130), NOW), "2 hr");
  assert.equal(waitLabel("not a date", NOW), "");
});

test("the CRM live strip shows callers waiting only (owner decision 6)", () => {
  assert.equal(crmStrip(0, null, NOW), null);
  assert.deepEqual(crmStrip(2, { name: "Tom Becker", since: ago(4) }, NOW), { title: "2 callers want a person", sub: "Tom Becker, waiting 4 min", action: "Open" });
  assert.equal(crmStrip(1, null, NOW).title, "1 caller wants a person");
  assert.equal(crmStrip(1, { since: ago(9) }, NOW).sub, "Waiting 9 min");
});

test("the admin live strip shows open incidents, the oldest first", () => {
  assert.equal(adminStrip([], NOW), null);
  assert.equal(adminStrip([{ status: "resolved", title: "Old", created_at: ago(500) }], NOW), null);
  const strip = adminStrip([
    { status: "open", title: "Calls slow", created_at: ago(5) },
    { status: "open", title: "Texts delayed for 3 businesses", created_at: ago(18) },
  ], NOW);
  assert.equal(strip.title, "Texts delayed for 3 businesses");
  assert.equal(strip.sub, "Incident open for 18 min · 2 open incidents");
  assert.equal(strip.action, "View");
});

test("Needs you now lists only what needs the owner, each with its page", () => {
  assert.deepEqual(needsNowRows({ now: NOW }), []);
  const rows = needsNowRows({
    waiting: 2, oldest: { name: "Tom Becker", since: ago(4), summary: "Private dining for 20" },
    overdue: [{ title: "Confirm cake delivery", due_at: ago(60), who: "Maya Chen" }], spam: 1, now: NOW,
  });
  assert.deepEqual(rows.map((r) => [r.key, r.page]), [["waiting", "attention"], ["overdue", "tasks"], ["spam", "spam"]]);
  assert.equal(rows[0].title, "2 callers want a person");
  assert.equal(rows[0].sub, "Tom Becker asked about private dining for 20");
  assert.equal(rows[0].meta, "4 min");
  assert.equal(rows[1].sub, "Task for Maya Chen, due 1 hr ago");
  assert.equal(rows[2].title, "1 call to review in Spam protection");
  assert.equal(needsNowRows({ overdue: [{ title: "A", due_at: ago(5) }, { title: "B", due_at: ago(2) }], now: NOW })[0].title, "2 overdue tasks");
});

test("gestures: panel swipe, sheet heights and swipe rows", () => {
  assert.equal(panelDrag(40), 0);
  assert.equal(panelDrag(-30), -30);
  assert.equal(panelReleaseCloses(-71), true);
  assert.equal(panelReleaseCloses(-40), false);

  assert.equal(sheetRelease("half", -70), "full");
  assert.equal(sheetRelease("half", 100), "close");
  assert.equal(sheetRelease("half", 30), "half");
  assert.equal(sheetRelease("full", 100), "half");
  assert.equal(sheetRelease("full", 300), "close");
  assert.equal(sheetRelease("full", -50), "full");
  assert.equal(sheetRelease("fit", 100), "close");
  assert.equal(sheetRelease("fit", -100), "fit");

  assert.equal(rowDrag(-200, false, 152), -152);
  assert.equal(rowDrag(40, false, 152), 0);
  assert.equal(rowDrag(20, true, 152), -132);
  assert.equal(rowReleaseOpens(-80), true);
  assert.equal(rowReleaseOpens(-30), false);
});

test("pull to refresh and the keyboard", () => {
  assert.equal(pullDistance(-10), 0);
  assert.equal(pullDistance(60), 30);
  assert.equal(pullDistance(1000), 96);
  assert.equal(pullReleaseRefreshes(pullDistance(100)), true);
  assert.equal(pullReleaseRefreshes(pullDistance(40)), false);
  assert.equal(keyboardOpen(800, 480), true);
  assert.equal(keyboardOpen(800, 760), false);
  assert.equal(keyboardOpen(800, undefined), false);
});

test("each tab keeps its own scroll and search", () => {
  const m = createTabMemory();
  m.save("today", { scroll: 420 });
  m.save("customers", { search: "maya" });
  m.save("today", { search: "" });
  assert.deepEqual(m.read("today"), { scroll: 420, search: "" });
  assert.deepEqual(m.read("customers"), { search: "maya" });
  assert.deepEqual(m.read("inbox"), {});
  m.save(null, { scroll: 1 });
  assert.deepEqual(m.read(null), {});
});

function fakeTimers() {
  let queue = [];
  return {
    setTimeout: (fn, ms) => { const t = { fn, ms }; queue.push(t); return t; },
    clearTimeout: (t) => { queue = queue.filter((q) => q !== t); },
    run: async () => { const q = queue; queue = []; for (const t of q) await t.fn(); },
    get pending() { return queue.length; },
  };
}

test("Undo: the change shows at once and is only sent after the window", async () => {
  const timers = fakeTimers();
  const log = [];
  const c = deferChange({ apply: () => log.push("apply"), commit: async () => { log.push("commit"); }, revert: () => log.push("revert"), timers, ms: 5000 });
  assert.deepEqual(log, ["apply"]);
  assert.equal(timers.pending, 1);
  await timers.run();
  assert.deepEqual(log, ["apply", "commit"]);
  assert.equal(c.state, "sent");
  assert.equal(c.undo(), false, "too late to undo once sent");
});

test("Undo within the window never sends anything", async () => {
  const timers = fakeTimers();
  const log = [];
  const c = deferChange({ apply: () => log.push("apply"), commit: async () => { log.push("commit"); }, revert: () => log.push("revert"), timers });
  assert.equal(c.undo(), true);
  await timers.run();
  assert.deepEqual(log, ["apply", "revert"]);
  assert.equal(c.state, "undone");
});

test("a failed save puts the change back and says so", async () => {
  const timers = fakeTimers();
  const log = [];
  deferChange({ apply: () => log.push("apply"), commit: async () => ({ error: new Error("offline") }), revert: () => log.push("revert"), onError: (e) => log.push(`error:${e.message}`), timers });
  await timers.run();
  assert.deepEqual(log, ["apply", "revert", "error:offline"]);
  const log2 = [];
  deferChange({ apply: () => {}, commit: async () => { throw new Error("denied"); }, revert: () => log2.push("revert"), onError: (e) => log2.push(e.message), timers });
  await timers.run();
  assert.deepEqual(log2, ["revert", "denied"]);
});

test("leaving the page sends a waiting change straight away", async () => {
  const timers = fakeTimers();
  let sent = 0;
  const c = deferChange({ commit: async () => { sent++; }, timers });
  await c.flush();
  await c.flush();
  assert.equal(sent, 1);
  assert.equal(timers.pending, 0);
});
