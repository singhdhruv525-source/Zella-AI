import { test } from "node:test";
import assert from "node:assert/strict";
import { DRAFT_DELETE_ROLES, nextRedrawMs, requestWaitHours, since } from "../src/businessLifecycle.js";

const NOW = Date.parse("2026-11-16T12:00:00Z");

test("only a Zella Voice owner and a super admin may delete a draft", () => {
  assert.deepEqual(DRAFT_DELETE_ROLES, ["zella_owner", "super_admin"]);
});

test("since says how long ago a draft last changed, in words", () => {
  assert.equal(since("2026-11-16T08:00:00Z", NOW), "Today");
  assert.equal(since("2026-11-15T08:00:00Z", NOW), "Yesterday");
  assert.equal(since("2026-10-16T11:00:00Z", NOW), "31 days ago");
  assert.equal(since("2026-11-17T08:00:00Z", NOW), "Today");
  assert.equal(since(null, NOW), "Not known");
  assert.equal(since("not a date", NOW), "Not known");
  // by calendar day in the viewer's time zone, not 24 hour blocks: 23:30 seen at 00:30 is yesterday
  const late = new Date(2026, 10, 18, 23, 30).toISOString(), justAfter = new Date(2026, 10, 19, 0, 30).getTime();
  assert.equal(since(late, justAfter), "Yesterday");
  assert.equal(since(new Date(2026, 10, 19, 0, 5).toISOString(), justAfter), "Today");
  assert.equal(since(new Date(2026, 10, 17, 1, 0).toISOString(), new Date(2026, 10, 19, 23, 0).getTime()), "2 days ago");
});

test("retention state: past, kept, or no date", async () => {
  const { retentionState } = await import("../src/businessLifecycle.js");
  assert.deepEqual(retentionState({ retention_until: "2026-11-01T00:00:00Z" }, NOW), ["Past retention", "danger"]);
  assert.deepEqual(retentionState({ retention_until: "2026-12-01T00:00:00Z" }, NOW), ["Kept", "neutral"]);
  assert.deepEqual(retentionState({ retention_until: "2026-12-01T00:00:00Z", past_retention: true }, NOW), ["Past retention", "danger"]);
  assert.deepEqual(retentionState({ retention_until: null }, NOW), ["No retention date", "warning"]);
});

test("documents requests: hours to wait, and what happened in words", async () => {
  const { documentRequestNotice, requestWaitHours } = await import("../src/businessLifecycle.js");
  assert.equal(requestWaitHours(null, 24, NOW), 0);
  assert.equal(requestWaitHours("2026-11-16T10:00:00Z", 24, NOW), 22);
  assert.equal(requestWaitHours("2026-11-15T11:00:00Z", 24, NOW), 0);
  assert.match(documentRequestNotice({ name: "Glow", email: "queued", to: "o…@glow.test" }), /queued and goes out once email sending is live/);
  assert.match(documentRequestNotice({ name: "Glow", email: "not_installed" }), /Email isn't live yet/);
  assert.match(documentRequestNotice({ name: "Glow", email: "no_address" }), /no owner email address/);
});

test("a failed step offers Retry step only for internal steps", async () => {
  const { retryAction } = await import("../src/businessLifecycle.js");
  assert.deepEqual(["modules", "receptionist", "automations", "owner_invitation", "finish", "integrations"].map(retryAction),
    ["retry", "retry", "retry", "resend", "setup", "setup"]);
});

test("an export's state in words", async () => {
  const { exportState } = await import("../src/businessLifecycle.js");
  assert.deepEqual(["requested", "running", "ready", "failed", "expired", "odd"].map((status) => exportState({ status })[0]),
    ["Waiting for approval", "Being prepared", "Ready to download", "Failed", "Expired", "Unknown"]);
});

test("request waits end on their own, and a list loaded after a long idle reads the time of the load", () => {
  const t0 = Date.parse("2026-11-19T00:00:00Z"), H = 3_600_000;
  const rows = [{ last_requested_at: new Date(t0 - 23.5 * H).toISOString() }, { last_requested_at: new Date(t0 - 2 * H).toISOString() }, { last_requested_at: null }];
  assert.equal(nextRedrawMs(rows, 24, t0), H / 2 + 1000, "the first wait ends in half an hour");
  assert.equal(nextRedrawMs([{ last_requested_at: new Date(t0 - 30 * H).toISOString() }], 24, t0), null, "nothing waiting: no timer");
  assert.equal(nextRedrawMs([{ last_requested_at: new Date(t0 - 1 * H).toISOString() }], 24, t0), H, "capped at an hour");
  // idle: the page's clock stopped at t0, the list is reloaded 30 hours later; with the load's time the button is back
  const later = t0 + 30 * H, asked = [{ last_requested_at: new Date(t0 - 2 * H).toISOString() }];
  assert.equal(requestWaitHours(asked[0].last_requested_at, 24, t0), 22, "with the stale clock it would still wait");
  assert.equal(requestWaitHours(asked[0].last_requested_at, 24, later), 0, "with the load's time it doesn't");
  assert.equal(nextRedrawMs(asked, 24, later), null);
});
