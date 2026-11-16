import { test } from "node:test";
import assert from "node:assert/strict";
import { formatCount, formatDateTime, formatDuration, formatPhone, formatRelative, formatTimeZone } from "../src/lib/format.js";

test("counts use thousands separators and empty stays empty", () => {
  assert.equal(formatCount(1203), "1,203");
  assert.equal(formatCount(0), "0");
  assert.equal(formatCount(null), "");
  assert.equal(formatCount("x"), "");
});

test("relative times are written out, never abbreviated", () => {
  const now = Date.parse("2026-11-16T15:00:00Z");
  assert.equal(formatRelative(now - 30 * 1000, now), "Just now");
  assert.equal(formatRelative(now - 5 * 60 * 1000, now), "5 minutes ago");
  assert.equal(formatRelative(now - 60 * 60 * 1000, now), "1 hour ago");
  assert.equal(formatRelative(now - 24 * 3600 * 1000, now), "Yesterday");
  assert.equal(formatRelative(now - 5 * 24 * 3600 * 1000, now), "5 days ago");
  assert.equal(formatRelative(null, now), "");
  assert.doesNotMatch(formatRelative(now - 10 * 24 * 3600 * 1000, now), / d ago/);
});

test("full date and time", () => {
  assert.equal(formatDateTime("2026-11-16T14:49:00"), "Nov 16, 2026 at 2:49 PM");
  assert.equal(formatDateTime(""), "");
});

test("phones use spaces, never dashes", () => {
  assert.equal(formatPhone("+15551230001"), "(555) 123 0001");
  assert.equal(formatPhone("5551230001"), "(555) 123 0001");
  assert.equal(formatPhone("+442071234567"), "+44 207 123 4567");
  for (const v of ["+15551230001", "+442071234567"]) assert.doesNotMatch(formatPhone(v), /-/);
});

test("time zones read as words", () => {
  assert.equal(formatTimeZone("America/New_York"), "Eastern Time (New York)");
  assert.equal(formatTimeZone("Not/A_Zone"), "A Zone");
});

test("durations", () => {
  assert.equal(formatDuration(45), "45 s");
  assert.equal(formatDuration(75), "1 min 15 s");
  assert.equal(formatDuration(undefined), "");
});
