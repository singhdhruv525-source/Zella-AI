import test from "node:test";
import assert from "node:assert/strict";
import { msUntilNextDay } from "./businessTime.js";

test("the wait runs to one second past the business's next midnight", () => {
  // 22:30 in New York (03:30 UTC next day in November): 1 hour 30 minutes, plus a second
  const now = new Date("2026-11-26T03:30:00Z");
  assert.equal(msUntilNextDay("America/New_York", now), (90 * 60 + 1) * 1000);
});

test("a timer fired just after midnight arms the next one about a day later, never a used up wait", () => {
  const justAfter = new Date("2026-11-26T05:00:01Z");   // 00:00:01 in New York
  const wait = msUntilNextDay("America/New_York", justAfter);
  assert.ok(wait > 23 * 3600 * 1000 && wait <= 24 * 3600 * 1000 + 1000, String(wait));
});

test("each time zone uses its own midnight", () => {
  const now = new Date("2026-11-26T03:30:00Z");
  assert.equal(msUntilNextDay("UTC", now), (20 * 3600 + 30 * 60 + 1) * 1000);
});

test("the wait stays within what a browser timer accepts", () => {
  const w = msUntilNextDay("Asia/Tokyo", new Date());
  assert.ok(w >= 1000 && w <= 2147483647);
});

test("Santiago on 6 Sep 2026, where midnight is skipped: the day starts at 04:00Z (01:00 local)", async () => {
  const { dayRange } = await import("./businessTime.js");
  assert.equal(dayRange("America/Santiago", 0, new Date("2026-09-06T12:00:00Z")).start.toISOString(), "2026-09-06T04:00:00.000Z");
  // the evening before: the next day begins at 04:00Z, so the wait ends one second after it, not in a 1 second loop
  assert.equal(msUntilNextDay("America/Santiago", new Date("2026-09-06T02:30:00Z")), (90 * 60 + 1) * 1000);
});

test("Santiago on an ordinary day: midnight is 03:00Z", async () => {
  const { dayRange } = await import("./businessTime.js");
  const d = dayRange("America/Santiago", 0, new Date("2026-09-10T12:00:00Z"));
  assert.equal(d.start.toISOString(), "2026-09-10T03:00:00.000Z");
  assert.equal(d.end.toISOString(), "2026-09-11T03:00:00.000Z");
});

test("New York and UTC days are unchanged", async () => {
  const { dayRange } = await import("./businessTime.js");
  assert.equal(dayRange("America/New_York", 0, new Date("2026-11-26T12:00:00Z")).start.toISOString(), "2026-11-26T05:00:00.000Z");
  assert.equal(dayRange("America/New_York", 0, new Date("2026-03-08T12:00:00Z")).end.toISOString(), "2026-03-09T04:00:00.000Z");
  assert.equal(dayRange("UTC", 0, new Date("2026-11-26T12:00:00Z")).start.toISOString(), "2026-11-26T00:00:00.000Z");
});
