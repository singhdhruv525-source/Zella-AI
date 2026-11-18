// The admin Businesses list (UI-03, UI-04, BIZ-15, BIZ-16, BIZ-23, BIZ-24, BIZ-27, BIZ-29): stage labels from the
// wizard's resume step, setup done for suspended businesses, the cell wording, the fallback for an older server, and
// that the web app and the server put each business in the same stage.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { STAGE_LABELS, businessState, stageLabel } from "../src/ownerFormat.js";
import { RESUME_AT, WIZARD_STEPS, resumeStep } from "../src/wizardProgress.js";
import {
  EMPTY_FILTERS, hasFilters, isUnknownAction, formatRelative, lastCallLabel, legacyList, planCell, shortDate, stageCell, listRequest, ownerCell, planLabel, problemSummary,
  legacyFilters, legacyIgnores, readList, rowActions, subscriptionLabel, unavailableNote,
} from "../src/businessList.js";

const fn = (name) => new URL(`../supabase/functions/owner-provision-business/${name}`, import.meta.url);
const toUrl = (src) => "data:text/javascript;base64," + Buffer.from(src).toString("base64");
const settingsUrl = toUrl(stripTypeScriptTypes(readFileSync(fn("settings.ts"), "utf8")));
const server = await import(toUrl(stripTypeScriptTypes(readFileSync(fn("businesses.ts"), "utf8")).replace('"./settings.ts"', JSON.stringify(settingsUrl))));
const { PERMISSIONS } = await import(settingsUrl);

test("a draft's stage label names the step the wizard reopens at (BIZ-27)", () => {
  for (const [status, key] of Object.entries(RESUME_AT)) {
    if (key === "review") continue;
    const step = WIZARD_STEPS.find((s) => s.key === key);
    assert.ok(step, `${status} reopens at a real step`);
    assert.equal(STAGE_LABELS[status], `Draft · next: ${step.label}`);
  }
  assert.equal(stageLabel("owner_setup"), "Draft · next: Hours & services");
  assert.equal(stageLabel("industry_setup"), "Draft · next: Team");
  assert.equal(stageLabel("automation_setup"), "Draft · next: CRM setup");
  // an older status the wizard doesn't know reopens at the first step, and says so (never the raw value)
  assert.equal(resumeStep("plan_setup").key, "business");
  assert.equal(stageLabel("plan_setup"), "Draft · next: Business");
  assert.equal(stageLabel(null), "Draft");
  for (const [status, label] of [["testing", "Setup complete"], ["ready", "Ready to go live"], ["active", "Live"], ["paused", "Paused"], ["failed", "Failed"], ["suspended", "Suspended"], ["cancelled", "Canceled"]]) {
    assert.equal(stageLabel(status), label);
  }
});

test("the wizard reads its steps and resume points from wizardProgress.js", () => {
  const wizard = readFileSync(new URL("../src/CreateBusinessWizard.jsx", import.meta.url), "utf8");
  assert.match(wizard, /const STEPS = WIZARD_STEPS;/);
  assert.match(wizard, /Object\.entries\(RESUME_AT\)/);
  assert.doesNotMatch(wizard, /owner_setup: STEP\./, "no second copy of the resume map");
});

test("setup done follows onboarding_status, even when suspended or canceled (BIZ-24)", () => {
  assert.deepEqual(businessState({ onboarding_status: "active", suspended_at: "2026-10-01" }), { key: "suspended", label: "Suspended", tone: "danger", done: true });
  assert.equal(businessState({ onboarding_status: "testing", cancelled_at: "2026-10-01" }).done, true);
  assert.equal(businessState({ onboarding_status: "owner_setup", suspended_at: "2026-10-01" }).done, false);
  assert.equal(businessState({ onboarding_status: "paused" }).key, "paused");
  assert.equal(businessState({ onboarding_status: "failed" }).key, "failed");
  const cancelling = businessState({ onboarding_status: "active", cancel_at: "2026-12-01T12:00:00Z" });
  assert.equal(cancelling.cancelling, true);
  assert.equal(cancelling.key, "live");
  assert.match(cancelling.label, /^Live · cancels /);
});

test("the web app and the server put every business in the same stage", () => {
  const statuses = ["started", "business_info", "owner_setup", "industry_setup", "ai_setup", "communications_setup", "automation_setup",
    "testing", "ready", "active", "paused", "failed", "plan_setup", "calendar_setup", "team_setup", "customer_import", null];
  for (const onboarding_status of statuses) {
    for (const extra of [{}, { suspended_at: "x" }, { cancelled_at: "y" }, { cancel_at: "2026-12-01" }, { suspended_at: "x", cancel_at: "z" }]) {
      const b = { onboarding_status, ...extra };
      const s = businessState(b);
      assert.equal(server.stageOf(b), s.key, JSON.stringify(b));
      assert.equal(server.setupDone(onboarding_status), s.done, JSON.stringify(b));
      assert.equal(server.isCancelling(b), Boolean(s.cancelling), JSON.stringify(b));
    }
  }
});

test("plan, subscription, last call and problems read plainly (BIZ-16, UI-03)", () => {
  assert.equal(planLabel({ tier: "pro", version: 2 }), "Pro, v2");
  assert.equal(planLabel({ tier: "base", version: 1 }), "Base, v1");
  assert.equal(planLabel(null), "No plan saved");
  assert.equal(planLabel(undefined), "Not available");
  assert.equal(subscriptionLabel({ status: "past_due" }), "Subscription: Past due");
  assert.equal(subscriptionLabel(null), "No subscription");
  assert.equal(subscriptionLabel(undefined), "Subscription: Not available");
  assert.equal(lastCallLabel(null), "No calls yet");
  assert.equal(lastCallLabel(undefined), "Not available");
  assert.equal(lastCallLabel(new Date().toISOString()), "Just now");
  assert.deepEqual(problemSummary({ count: 0, items: [] }).label, "No problems");
  assert.deepEqual(problemSummary(null).label, "Not available");
  const two = problemSummary({ count: 2, items: [{ title: "A payment failed", severity: "urgent" }, { title: "x", severity: "warning" }] });
  assert.deepEqual([two.label, two.tone, two.detail], ["2 open", "danger", "A payment failed"]);
  assert.equal(problemSummary({ count: 1, items: [{ title: "y", severity: "warning" }] }).tone, "warning");
});

test("the owner cell says it once when nobody is invited", () => {
  assert.deepEqual(ownerCell(null), { title: "No owner invited yet", sub: "", status: null });
  assert.deepEqual(ownerCell({ name: "Sam Rivera", email: "sam@example.test", status: "accepted", expired: false }), { title: "Sam Rivera", sub: "sam@example.test", status: "accepted" });
  assert.deepEqual(ownerCell({ name: null, email: "sam@example.test", status: "sent", expired: true }), { title: "sam@example.test", sub: "", status: "expired" });
});

test("View is the main action once setup is done; setup buttons need businesses.manage (BIZ-23, UI-03)", () => {
  assert.deepEqual(rowActions({ stage: "live", setupDone: true }, true), { main: "view", setup: "Edit setup" });
  assert.deepEqual(rowActions({ stage: "suspended", setupDone: true }, true), { main: "view", setup: "Edit setup" });
  assert.deepEqual(rowActions({ stage: "draft", setupDone: false }, true), { main: "setup", setup: "Continue setup" });
  assert.deepEqual(rowActions({ stage: "draft", setupDone: false }, false), { main: "view", setup: null });
  assert.deepEqual(rowActions({ stage: "live", setupDone: true }, false), { main: "view", setup: null });
  assert.deepEqual(rowActions({ stage: "cancelled", setupDone: true }, true), { main: "view", setup: null });
  assert.deepEqual(rowActions({ stage: "draft", onboarding_status: "testing" }, true), { main: "view", setup: "Edit setup" });
});

test("the request carries only the filters that are set", () => {
  assert.deepEqual(listRequest("  sam ", EMPTY_FILTERS, 0), { q: "sam", sort: "newest", page: 0, size: 25 });
  assert.deepEqual(listRequest("", { ...EMPTY_FILTERS, stage: "live", plan: "pro", problem: true, industryId: "i1", sort: "name" }, 3),
    { q: "", sort: "name", page: 3, size: 25, stage: "live", plan: "pro", problem: true, industryId: "i1" });
  assert.equal(hasFilters(" ", EMPTY_FILTERS), false);
  assert.equal(hasFilters("", { ...EMPTY_FILTERS, problem: true }), true);
});

test("only an older server's Unknown action falls back; an odd answer is an error, never an empty list", () => {
  assert.equal(isUnknownAction(Object.assign(new Error("Unknown action"), { status: 400 })), true);
  assert.equal(isUnknownAction(Object.assign(new Error("Unknown action"), { status: 500 })), false);
  assert.equal(isUnknownAction(Object.assign(new Error("Something went wrong"), { status: 400 })), false);
  assert.equal(isUnknownAction(new Error("Failed to fetch")), false);
  assert.throws(() => readList({}), /couldn't be read/);
  assert.throws(() => readList({ rows: [] }), /couldn't be read/);
  assert.throws(() => readList({ rows: [], total: 0 }), /couldn't be read/, "a missing industry list is unreadable, not an empty one");
  const ok = readList({ rows: [{ id: "a" }], total: 30, page: 1, industries: [], stats: { totalBusinesses: 30 }, unavailable: ["lastCalls"] });
  assert.deepEqual([ok.mode, ok.total, ok.page, ok.unavailable], ["server", 30, 1, ["lastCalls"]]);
});

test("the older server's list is filtered, sorted and paged here, with plans and problems unknown", () => {
  const businesses = Array.from({ length: 30 }, (_, i) => ({
    id: `b${i}`, name: `Shop ${String(i).padStart(2, "0")}`, industry_id: i % 2 ? "i2" : "i1", onboarding_status: i % 3 ? "owner_setup" : "active",
    created_at: new Date(Date.UTC(2026, 0, 1 + i)).toISOString(), invitations: i === 4 ? [{ owner_name: "Ana", email: "ana@example.test", status: "sent" }] : [],
    subscriptions: i === 4 ? [{ status: "trial" }] : [],
  }));
  const data = { businesses, industries: [{ id: "i1", name: "Plumbing" }, { id: "i2", name: "Dental" }], stats: { totalBusinesses: 30, provisioningIssues: 0 } };
  const first = legacyList(data, "", EMPTY_FILTERS, 0);
  assert.deepEqual([first.mode, first.total, first.rows.length, first.rows[0].name], ["legacy", 30, 25, "Shop 29"]);
  assert.deepEqual(legacyList(data, "", EMPTY_FILTERS, 1).rows.length, 5);
  assert.equal(legacyList(data, "", EMPTY_FILTERS, 9).page, 1);   // past the end: the last page
  const ana = legacyList(data, "ana@", EMPTY_FILTERS, 0);
  assert.deepEqual(ana.rows.map((r) => r.id), ["b4"]);
  assert.deepEqual(ana.rows[0].owner, { name: "Ana", email: "ana@example.test", status: "sent", expired: false });
  assert.deepEqual(ana.rows[0].subscription, { status: "trial" });
  assert.equal(ana.rows[0].plan, undefined);
  assert.equal(ana.rows[0].problems, undefined);
  assert.equal(legacyList(data, "", { ...EMPTY_FILTERS, stage: "live" }, 0).total, 10);
  assert.equal(legacyList(data, "", { ...EMPTY_FILTERS, industryId: "i2" }, 0).total, 15);
  assert.equal(legacyList(data, "", { ...EMPTY_FILTERS, sort: "name" }, 0).rows[0].name, "Shop 00");
  assert.equal(legacyList(data, "dental", EMPTY_FILTERS, 0).total, 15);   // the industry name is searched
  assert.deepEqual(first.unavailable, ["plans", "problems", "lastCalls"]);
  assert.throws(() => legacyList({}, "", EMPTY_FILTERS, 0), /couldn't be read/);
});

test("businesses_list needs businesses.view and is wired in; dashboard_data no longer sends members (BIZ-29)", () => {
  assert.equal(PERMISSIONS.businesses_list, "businesses.view");
  const index = readFileSync(fn("index.ts"), "utf8");
  assert.match(index, /businesses_list: async \(\) => \{\s*await processCancellations\(adminClient\);/);
  const dash = index.slice(index.indexOf('if (action === "dashboard_data")'), index.indexOf("const handlers: Record<string"));
  assert.ok(dash.length > 500);
  for (const gone of ["business_members", "totalMembers", "totalSubscriptions", "members:"]) assert.ok(!dash.includes(gone), `dashboard_data still has ${gone}`);
  // what Offers, the setup wizard and an older web app still read
  for (const kept of ['from("businesses")', 'from("industries")', 'from("business_invitations")', 'from("subscriptions")', "invitations:", "subscriptions:", "pendingInvitations", "provisioningIssues"]) {
    assert.ok(dash.includes(kept), `dashboard_data lost ${kept}`);
  }
});

test("the Businesses page has no marketing banner and gates its write buttons (UI-04, BIZ-23)", () => {
  const page = readFileSync(new URL("../src/BusinessesPage.jsx", import.meta.url), "utf8");
  const shell = readFileSync(new URL("../src/OwnerDashboard.jsx", import.meta.url), "utf8");
  assert.ok(!page.includes("owner-info-banner") && !shell.includes("owner-info-banner"));
  assert.ok(!page.includes("One platform. Separate business workspaces."));
  assert.match(page, /\{canManage && \(\s*<button className="owner-primary-button" type="button" onClick=\{onCreate\}>/);
  assert.match(shell, /canManage=\{can\("businesses\.manage"\)\}/);
  assert.match(shell, /onCreateBusiness=\{can\("businesses\.manage"\) \?/);
  assert.match(shell, /can=\{can\}/);
});

test("B2-08: when the older list takes over, plan, problem and 'most problems' are dropped, not silently ignored", () => {
  const set = { ...EMPTY_FILTERS, industryId: "i1", plan: "pro", problem: true, sort: "problems" };
  assert.equal(legacyIgnores(set), true);
  const dropped = legacyFilters(set);
  assert.deepEqual(dropped, { ...EMPTY_FILTERS, industryId: "i1" });
  assert.equal(legacyIgnores(dropped), false);
  assert.equal(legacyFilters({ ...EMPTY_FILTERS, sort: "name" }).sort, "name");
  const page = readFileSync(new URL("../src/BusinessesPage.jsx", import.meta.url), "utf8");
  assert.match(page, /legacyIgnores\(f\)\) \{ f = legacyFilters\(f\); setFiltersState\(legacyFilters\)/);
});

test("the couldn't be loaded notice reads as a sentence and says only what the page shows", () => {
  assert.equal(unavailableNote(new Set(["plans"])), "Plans show as Not available. Refresh to try again.");
  assert.equal(unavailableNote(new Set(["plans", "subscriptions"])), "Plans and subscriptions show as Not available. Refresh to try again.");
  assert.equal(unavailableNote(new Set(["subscriptions", "problems", "lastCalls"])), "Subscriptions, problems and last calls show as Not available. Refresh to try again.");
  assert.equal(unavailableNote(new Set()), "");
});

test("the business detail page uses the list's setup done rule, so a paused business offers Edit setup (BIZ-24)", () => {
  const detail = readFileSync(new URL("../src/BusinessDetails.jsx", import.meta.url), "utf8");
  assert.match(detail, /isSetupDone\(b\.onboarding_status\)/);
  assert.doesNotMatch(detail, /\["testing", "ready", "active"\]\.includes/);
});

test("stat cards format counts like the footer", () => {
  const page = readFileSync(new URL("../src/BusinessesPage.jsx", import.meta.url), "utf8");
  assert.match(page, /isCount\(v\) \? num\(v\)/);
});

test("relative times and short dates read in words", () => {
  const now = Date.parse("2026-11-16T15:00:00Z");
  const ago = (ms) => new Date(now - ms).toISOString();
  assert.equal(formatRelative(ago(30 * 1000), now), "Just now");
  assert.equal(formatRelative(ago(60 * 1000), now), "1 minute ago");
  assert.equal(formatRelative(ago(5 * 60 * 1000), now), "5 minutes ago");
  assert.equal(formatRelative(ago(3 * 3600 * 1000), now), "3 hours ago");
  assert.equal(formatRelative(ago(30 * 3600 * 1000), now), "Yesterday");
  assert.equal(formatRelative(ago(10 * 86400 * 1000), now), "10 days ago");
  assert.doesNotMatch(formatRelative(ago(10 * 86400 * 1000), now), / d ago/);
  assert.equal(formatRelative("not a date", now), "Not available");
  assert.equal(shortDate(null), "");
  assert.match(shortDate("2026-11-16T12:00:00Z", new Date("2026-11-20T00:00:00Z")), /Nov/);
  assert.doesNotMatch(shortDate("2026-11-16T12:00:00Z", new Date("2026-11-20T00:00:00Z")), /2026/);
  assert.match(shortDate("2025-11-16T12:00:00Z", new Date("2026-11-20T00:00:00Z")), /2025/);
});

test("the stage cell is one word with the next step below", () => {
  assert.deepEqual(stageCell({ onboarding_status: "owner_setup" }).label, "Draft");
  assert.match(stageCell({ onboarding_status: "owner_setup" }).note, /^Next: /);
  assert.doesNotMatch(stageCell({ onboarding_status: "owner_setup" }).note, /&/);
  assert.deepEqual(stageCell({ onboarding_status: "active" }), { label: "Live", tone: "success", note: "" });
  assert.equal(stageCell({ onboarding_status: "active", suspended_at: "2026-11-01" }).label, "Suspended");
  const cancelling = stageCell({ onboarding_status: "active", cancel_at: "2026-12-01T12:00:00Z" });
  assert.deepEqual([cancelling.label, cancelling.tone], ["Live", "warning"]);
  assert.match(cancelling.note, /^Cancels /);
});

test("the plan cell merges plan and subscription", () => {
  assert.deepEqual(planCell(null, null), { label: "No plan", none: true, note: "", sub: null });
  assert.deepEqual(planCell({ tier: "pro", version: 2, billing_interval: "monthly" }, { status: "past_due" }), { label: "Pro, v2", note: "Monthly", sub: "Past due" });
  assert.equal(planCell(undefined, undefined).label, null);
});
