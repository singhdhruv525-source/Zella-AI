import { test } from "node:test";
import assert from "node:assert/strict";
import { DRAFT_DELETE_ROLES, since } from "../src/businessLifecycle.js";

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
});

test("retention state: past, kept, or no date", async () => {
  const { retentionState } = await import("../src/businessLifecycle.js");
  assert.deepEqual(retentionState({ retention_until: "2026-11-01T00:00:00Z" }, NOW), ["Past retention", "danger"]);
  assert.deepEqual(retentionState({ retention_until: "2026-12-01T00:00:00Z" }, NOW), ["Kept", "neutral"]);
  assert.deepEqual(retentionState({ retention_until: "2026-12-01T00:00:00Z", past_retention: true }, NOW), ["Past retention", "danger"]);
  assert.deepEqual(retentionState({ retention_until: null }, NOW), ["No retention date", "warning"]);
});
