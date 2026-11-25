import { test } from "node:test";
import assert from "node:assert/strict";
import { formatWallTime } from "../src/lib/format.js";
import { timeAgo, timeAgoLabel } from "../src/businessTime.js";

test("an offer's wall clock time reads in words, never shifted by the viewer's zone (A43)", () => {
  assert.equal(formatWallTime("2026-11-15T10:00"), "Nov 15, 2026, 10:00 AM");
  assert.equal(formatWallTime("2026-12-15 22:05:00"), "Dec 15, 2026, 10:05 PM");
  assert.equal(formatWallTime(""), "");
  assert.equal(formatWallTime(null), "");
  assert.doesNotMatch(formatWallTime("2026-11-15T10:00"), /→|-/);
});

test("CRM times read in full words: inside a sentence and on their own (C5)", () => {
  const ago = (ms) => new Date(Date.now() - ms).toISOString();
  assert.equal(timeAgo(ago(13 * 60 * 1000)), "13 minutes ago");
  assert.equal(timeAgo(ago(2 * 3600 * 1000)), "2 hours ago");
  assert.equal(timeAgo(ago(24 * 3600 * 1000)), "yesterday");
  assert.equal(timeAgoLabel(ago(24 * 3600 * 1000)), "Yesterday");
  assert.equal(timeAgo(ago(5 * 24 * 3600 * 1000)), "5 days ago");
  assert.equal(timeAgo(ago(10 * 1000)), "just now");
  assert.equal(timeAgo(null), "None");
  assert.doesNotMatch(timeAgo(ago(3 * 3600 * 1000)), / h ago| min ago| d ago/);
});
