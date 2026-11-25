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
