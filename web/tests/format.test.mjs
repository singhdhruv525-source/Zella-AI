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
  assert.equal(formatPhone("+61293744000"), "+61 29 374 4000");
  assert.equal(formatPhone("+442071838750"), "+44 207 183 8750");
  assert.equal(formatPhone("+919876543210"), "+91 987 654 3210");
  assert.equal(formatPhone("+35312345678"), "+353 1 234 5678");
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
  assert.equal(formatDuration(120), "2 min");
  assert.equal(formatDuration(3720), "1 h 2 min");
  assert.equal(formatDuration(3600), "1 h");
  assert.equal(formatDuration(undefined), "");
});

test("counts agree with their number (C39) and use each kind's own plural (C33)", async () => {
  const { countWord } = await import("../src/lib/format.js");
  assert.equal(countWord(1, "arrival"), "1 arrival");
  assert.equal(countWord(0, "arrival"), "0 arrivals");
  assert.equal(countWord(3, "arrival"), "3 arrivals");
  assert.equal(countWord(1, "no show"), "1 no show");
  assert.equal(countWord(2, "no show"), "2 no shows");
  assert.equal(countWord(4, "event or catering enquiry", "event or catering enquiries"), "4 event or catering enquiries");
  assert.equal(countWord(1, "event or catering enquiry", "event or catering enquiries"), "1 event or catering enquiry");
  assert.doesNotMatch(countWord(4, "enquiry", "enquiries"), /enquirys/);
});

test("chart days read as dates, not codes with a hyphen (C36)", async () => {
  const { formatMonthDay } = await import("../src/lib/format.js");
  assert.equal(formatMonthDay("2026-11-23"), "Nov 23");
  assert.equal(formatMonthDay("2026-01-01"), "Jan 1");   // read in UTC: never shifts to Dec 31
  assert.equal(formatMonthDay(""), "");
  assert.equal(formatMonthDay(null), "");
  assert.equal(formatMonthDay("not a day"), "");
});

test("formatPhone keeps a number with an extension as written; phoneMatches finds raw and shown numbers", async () => {
  const { formatPhone: fp, phoneMatches: pm } = await import("../src/lib/format.js");
  assert.equal(fp("+1 202 555 0123 ext 45"), "+1 202 555 0123 ext 45");
  assert.equal(fp("2025550123 x45"), "2025550123 x45");
  assert.equal(fp("+1 202 555 0123"), "(202) 555 0123");
  assert.equal(pm("+12025550123", "(202) 555 0123"), true);
  assert.equal(pm("+12025550123", "+12025550123"), true);
  assert.equal(pm("2025550123", "+1 202 555 0123"), true);
  assert.equal(pm("+12025550123", "555 01"), true);
  assert.equal(pm("+12025550123", "99"), false);
  assert.equal(pm("+12025550123", "303"), false);
  assert.equal(pm(null, "202"), false);
});
