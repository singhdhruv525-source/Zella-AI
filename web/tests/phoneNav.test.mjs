// Phone navigation (approved 25 Nov 2026): the bottom bar's tab rule for each industry and each role, the admin's
// tabs for each permission set, and the pure helpers behind the gestures, the live strip, "Needs you now", the per
// tab memory and the Undo window.
import { test } from "node:test";
import { createScrollLock } from "../src/navigation/bodyScrollLock.js";
import assert from "node:assert/strict";
import { buildNavigation, flatten } from "../src/navigation/navConfig.js";
import { MORE_TAB, PHONE_QUERY, adminTabs, badgeText, crmTabs, selectedTab, tabName } from "../src/navigation/phoneTabs.js";
import { SIGNAL_START, adminStripFor, createKeepaliveSender, createPendingStore, createToastStore, keepaliveRequest, panelReplacesPending, pendingToastText, signalCount, signalReduce, undoAll } from "../src/navigation/phoneHelpers.js";
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

test("Undo for a dismissed task: the same deferral, the cancel only sent after the window, put back on failure", async () => {
  const timers = fakeTimers();
  const sent = [];
  const shown = new Set(["task-1"]);
  const dismiss = (fail) => deferChange({
    apply: () => shown.delete("task-1"),
    commit: async () => { sent.push({ p_task_id: "task-1", p_cancel: true }); return fail ? { error: new Error("offline") } : {}; },
    revert: () => shown.add("task-1"), timers,
  });
  const a = dismiss(false);
  assert.equal(shown.has("task-1"), false, "gone from the list at once");
  assert.equal(sent.length, 0, "nothing sent inside the Undo window");
  a.undo();
  assert.equal(shown.has("task-1"), true);
  await timers.run();
  assert.equal(sent.length, 0, "Undo sends nothing");
  dismiss(true);
  await timers.run();
  assert.deepEqual(sent, [{ p_task_id: "task-1", p_cancel: true }]);
  assert.equal(shown.has("task-1"), true, "a failed dismiss comes back");
});

test("admin readings: a failure is never shown as nothing wrong, and a later failure marks the value stale", () => {
  let st = SIGNAL_START;
  assert.deepEqual(signalCount(st), { count: null, state: "loading" });
  st = signalReduce(st, { type: "fail" });
  assert.deepEqual(st, { status: "failed", value: null });
  assert.deepEqual(signalCount(st), { count: null, state: "failed" });
  st = signalReduce(st, { type: "ok", value: 0 });
  assert.deepEqual(signalCount(st), { count: 0, state: "ok" }, "0 only for a read that worked");
  st = signalReduce(st, { type: "ok", value: 5 });
  st = signalReduce(st, { type: "fail" });
  assert.deepEqual(st, { status: "stale", value: 5 });
  assert.deepEqual(signalReduce(st, { type: "fail" }), { status: "stale", value: 5 });
  assert.deepEqual(signalReduce(st, { type: "reset" }), SIGNAL_START, "lost permission: nothing kept");
  assert.equal(tabName("Support", null, "open", "failed"), "Support, count not available");
  assert.equal(tabName("Support", 5, "open", "stale"), "Support, 5 open, may be out of date");
  assert.equal(tabName("Support", 5, "open", "ok"), "Support, 5 open");
});

test("the admin live strip from the incidents reading", () => {
  const inc = [{ status: "open", title: "Texts delayed for 3 businesses", created_at: ago(18) }];
  assert.equal(adminStripFor(SIGNAL_START, NOW), null);
  assert.equal(adminStripFor({ status: "ok", value: [] }, NOW), null, "a successful empty read: no strip");
  assert.equal(adminStripFor({ status: "ok", value: inc }, NOW).title, "Texts delayed for 3 businesses");
  assert.equal(adminStripFor({ status: "failed", value: null }, NOW).title, "Incidents couldn't be checked");
  assert.equal(adminStripFor({ status: "stale", value: inc }, NOW).sub, "Incident open for 18 min · may be out of date");
  assert.equal(adminStripFor({ status: "stale", value: [] }, NOW).title, "Incidents couldn't be refreshed");
});

test("several quick changes waiting at once: one Undo calls off every one still in its window", async () => {
  const timers = fakeTimers();
  const sent = [];
  const make = (id) => deferChange({ commit: async () => { sent.push(id); }, timers });
  const a = make("a"), b = make("b");
  assert.equal(pendingToastText("Ticket resolved", 2), "2 changes made");
  assert.equal(pendingToastText("Ticket resolved", 1), "Ticket resolved");
  assert.equal(undoAll([a, b]), 2);
  await timers.run();
  assert.deepEqual(sent, [], "neither was sent");
  const c = make("c");
  await timers.run();
  assert.equal(undoAll([c]), 0, "one already sent is left alone");
  assert.deepEqual(sent, ["c"]);
});

test("a change already being sent: a later flush waits for that send (sign out waits for it)", async () => {
  const timers = fakeTimers();
  let finish;
  const log = [];
  const c = deferChange({ commit: () => new Promise((r) => { finish = r; }), timers });
  const first = c.flush();
  let waited = false;
  const second = c.flush().then(() => { waited = true; log.push("second done"); });
  await Promise.resolve();
  assert.equal(waited, false, "the second flush is still waiting for the send in flight");
  finish();
  await first; await second;
  assert.equal(waited, true);
  // an undone change has nothing to wait for
  const u = deferChange({ commit: async () => log.push("sent"), timers });
  u.undo();
  await u.flush();
  assert.deepEqual(log, ["second done"]);
});

test("closing the tab: waiting changes go out as keepalive requests where they can", async () => {
  const timers = fakeTimers();
  const beacons = [];
  const store = createPendingStore();
  const withBeacon = deferChange({ commit: async () => beacons.push("normal send"), beacon: () => { beacons.push("keepalive"); return true; }, timers });
  const noBeacon = deferChange({ commit: async () => beacons.push("fallback send"), timers });
  store.add("a", withBeacon, {}); store.add("b", noBeacon, {});
  assert.equal(store.waitingWithoutBeacon(), 1, "the browser asks before closing while this one waits");
  store.unloadAll();
  await Promise.resolve();
  assert.deepEqual(beacons.sort(), ["fallback send", "keepalive"]);
  assert.equal(withBeacon.state, "beaconed", "handed to the browser as a keepalive request");
  await timers.run();
  assert.equal(beacons.length, 2, "nothing is sent twice when the timers would have fired");
  // a beacon that couldn't start (no session): the usual send instead
  const tried = [];
  const c = deferChange({ commit: async () => tried.push("send"), beacon: () => false, timers });
  c.unload();
  await Promise.resolve();
  assert.deepEqual(tried, ["send"]);
});

test("the keepalive request: same endpoint and headers as the client, never without a token", () => {
  const cfg = { url: "https://example.supabase.co", key: "publishable-key", token: "user-token" };
  const rpc = keepaliveRequest(cfg, "rpc", "zella_complete_task", { p_task_id: "t1" });
  assert.equal(rpc.url, "https://example.supabase.co/rest/v1/rpc/zella_complete_task");
  assert.equal(rpc.init.method, "POST");
  assert.equal(rpc.init.keepalive, true);
  assert.deepEqual(rpc.init.headers, { "Content-Type": "application/json", apikey: "publishable-key", Authorization: "Bearer user-token" });
  assert.equal(rpc.init.body, JSON.stringify({ p_task_id: "t1" }));
  const fn = keepaliveRequest(cfg, "function", "owner-provision-business", { action: "ticket_update", ticketId: "st1", status: "resolved" });
  assert.equal(fn.url, "https://example.supabase.co/functions/v1/owner-provision-business");
  assert.equal(JSON.parse(fn.init.body).action, "ticket_update");
  assert.equal(keepaliveRequest({ ...cfg, token: null }, "rpc", "x", {}), null);
  assert.equal(keepaliveRequest({ ...cfg, key: "" }, "rpc", "x", {}), null);
  assert.equal(keepaliveRequest(cfg, "other", "x", {}), null);
});

test("a beacon that isn't ready (no token, no config, no fetch) still makes the browser ask before closing", async () => {
  const timers = fakeTimers();
  let ready = false;
  const sent = [];
  const store = createPendingStore();
  const c = deferChange({ commit: async () => sent.push("send"), beacon: () => { sent.push("keepalive"); return true; }, beaconReady: () => ready, timers });
  store.add("a", c, {});
  assert.equal(c.canBeacon, false);
  assert.equal(store.waitingWithoutBeacon(), 1, "the prompt is kept");
  assert.deepEqual(sent, [], "checking readiness sends nothing");
  ready = true;
  assert.equal(store.waitingWithoutBeacon(), 0, "ready: no prompt needed");
  ready = false;
  // not ready when the tab closes: the beacon itself reports it can't send, and the ordinary send runs instead
  const d = deferChange({ commit: async () => sent.push("send"), beacon: () => false, beaconReady: () => false, timers });
  d.unload();
  await Promise.resolve();
  assert.deepEqual(sent, ["send"]);
});

test("a plain message never replaces a toast that still offers Undo: it waits for it to end", () => {
  const timers = fakeTimers();
  const t = createToastStore(timers);
  const seen = [];
  t.subscribe((c) => seen.push(c?.text ?? null));
  let undone = 0;
  t.show("Task marked done", { undo: () => undone++ });
  t.show("Saved.");
  assert.equal(t.get().text, "Task marked done", "the Undo toast stays");
  assert.equal(typeof t.get().undo, "function");
  t.get().undo(); t.dismiss();                             // Undo pressed
  assert.equal(undone, 1);
  assert.equal(t.get().text, "Saved.", "the message shows once the Undo toast has ended");
  t.show("Ticket resolved", { undo: () => {} });          // a new Undo toast may replace a plain one
  assert.equal(t.get().text, "Ticket resolved");
  t.show("Another message");
  timers.run();                                            // the Undo toast's time is up
  assert.equal(t.get().text, "Another message");
  assert.deepEqual(seen, ["Task marked done", "Saved.", "Ticket resolved", "Another message"]);
});

test("one shared scroll lock: released in any order, the page gets its own value back only after the last", () => {
  const doc = { body: { style: { overflow: "auto" } } };
  const lock = createScrollLock(doc);
  const sheet = lock();
  const panel = lock();
  assert.equal(doc.body.style.overflow, "hidden");
  sheet();                                                 // the older lock goes first
  assert.equal(doc.body.style.overflow, "hidden", "still covered by the panel");
  sheet();                                                 // a second release of the same lock does nothing
  assert.equal(doc.body.style.overflow, "hidden");
  panel();
  assert.equal(doc.body.style.overflow, "auto", "the page's own value back");
  const again = lock();
  assert.equal(doc.body.style.overflow, "hidden");
  again();
  assert.equal(doc.body.style.overflow, "auto");
});

test("a note or a reply never calls off a waiting Resolve or Assign; the same field does", () => {
  const resolve = { status: "resolved" };
  const assign = { assigned_to: "u1", assignee: "me@zella.test" };
  assert.equal(panelReplacesPending(resolve, { note: "Called them" }), false);
  assert.equal(panelReplacesPending(resolve, { reply: "On it" }), false);
  assert.equal(panelReplacesPending(resolve, { status: "open" }), true);
  assert.equal(panelReplacesPending(resolve, { assignedTo: "u2" }), false);
  assert.equal(panelReplacesPending(assign, { assignedTo: "u2" }), true);
  assert.equal(panelReplacesPending(assign, { priority: "high" }), false);
  assert.equal(panelReplacesPending(null, { status: "open" }), false);
});

test("keepalive: the preview and the placeholder business never send anything; a real session does", () => {
  const PLACEHOLDER = "00000000-0000-0000-0000-000000000000";
  const calls = [];
  const fetchImpl = () => (url, init) => { calls.push(url); return Promise.resolve({ ok: true, init }); };
  const make = (preview) => createKeepaliveSender({
    getConfig: () => ({ url: "https://example.supabase.co", key: "publishable-key" }), getToken: () => "user-token",
    isPreview: () => preview, placeholderId: PLACEHOLDER, fetchImpl,
  });
  const preview = make(true);
  assert.equal(preview.ready(), false, "the preview is never ready, so the browser asks instead");
  assert.equal(preview.send("rpc", "zella_complete_task", { p_task_id: "t1" }), false);
  const live = make(false);
  assert.equal(live.send("function", "owner-provision-business", { action: "ticket_update", business_id: PLACEHOLDER }), false, "about the placeholder business");
  assert.deepEqual(calls, [], "fetch was never called");
  assert.equal(live.ready(), true);
  assert.equal(live.send("rpc", "zella_complete_task", { p_task_id: "t1" }), true);
  assert.deepEqual(calls, ["https://example.supabase.co/rest/v1/rpc/zella_complete_task"]);
  const noToken = createKeepaliveSender({ getConfig: () => ({ url: "https://example.supabase.co", key: "k" }), getToken: () => null, fetchImpl });
  assert.equal(noToken.ready(), false);
  assert.equal(noToken.send("rpc", "x", {}), false);
});

test("the back/forward cache: nothing is sent early, and waiting changes resume to their original Undo deadlines", async () => {
  let clock = 1000;
  const scheduled = [];
  const timers = { setTimeout: (fn, ms) => { const t = { fn, at: clock + ms }; scheduled.push(t); return t; }, clearTimeout: (t) => { const i = scheduled.indexOf(t); if (i >= 0) scheduled.splice(i, 1); } };
  const store = createPendingStore();
  const sent = [];
  const make = (id) => { const c = deferChange({ commit: async () => { sent.push(id); store.succeed(id); }, beacon: () => { sent.push(`${id} keepalive`); return true; }, timers, now: () => clock }); store.add(id, c, {}); return c; };
  const a = make("a");                                   // deadline 6000
  clock = 3000;
  store.onPageHide(true);                                // into the back/forward cache
  assert.deepEqual(sent, [], "nothing sent early");
  assert.equal(a.state, "waiting");
  clock = 4000;
  store.onPageShow(true);                                // back, 2 seconds left
  assert.equal(a.state, "waiting");
  assert.equal(scheduled.at(-1).at, 6000, "the original deadline, not a fresh 5 seconds");
  assert.equal(a.undo(), true, "Undo still works");
  const b = make("b");                                   // deadline 9000
  store.onPageHide(true);
  clock = 12000;                                         // back after the deadline passed
  store.onPageShow(true);
  await Promise.resolve();
  assert.deepEqual(sent, ["b"], "past its deadline: sent on return, the ordinary way");
  assert.equal(b.state, "sent");
  const c = make("c");
  store.onPageHide(false);                               // a real departure
  assert.deepEqual(sent, ["b", "c keepalive"]);
  assert.equal(c.state, "beaconed");
});
