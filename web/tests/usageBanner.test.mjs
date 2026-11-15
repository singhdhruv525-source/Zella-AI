// Usage banners on Today (src/usageBanner.js): nothing below 80%, a heads up at 80%, the right words at 100% for
// minutes, texts and emails, and the writing rules (no dashes, no emoji).
//   cd web && node --test tests/usageBanner.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { usageBanner } from "../src/usageBanner.js";

const u = (used, included, extra = {}) => ({ configured: true, used, included, percent_used: (used * 100) / included, exhausted: used >= included, buffer: 50, buffer_remaining: 12, ...extra });

test("quiet below 80%, and when nothing is configured", () => {
  assert.equal(usageBanner("minutes", u(700, 1000), 9), null);
  assert.equal(usageBanner("minutes", { configured: false }, 9), null);
  assert.equal(usageBanner("texts", u(0, 0), 9), null);
});

test("minutes at 80% and 100%", () => {
  const h = usageBanner("minutes", u(800, 1000), 9);
  assert.equal(h.tone, "heads");
  assert.match(h.body, /800 of 1,000 minutes used, 9 days to go\. Every call is still being answered\./);
  const out = usageBanner("minutes", u(1000, 1000), 2);
  assert.equal(out.tone, "urgent");
  assert.equal(out.kicker, "Action needed");
});

test("texts and emails: routine paused, appointments keep going from the reserve", () => {
  const t = usageBanner("texts", u(1000, 1000), 3);
  assert.equal(t.kicker, "Paused for now");
  assert.match(t.body, /reserve \(12 of 50 left\)/);
  assert.match(usageBanner("emails", u(850, 1000), 1).body, /1 day to go/);
});

test("no dashes or emoji in any banner", () => {
  for (const r of ["minutes", "texts", "emails"]) for (const used of [800, 1000]) {
    const b = usageBanner(r, u(used, 1000), 4);
    for (const t of [b.kicker, b.title, b.body, b.action]) {
      assert.doesNotMatch(t, /[–—]|[A-Za-z0-9]-[A-Za-z]/, t);
      assert.doesNotMatch(t, /\p{Extended_Pictographic}/u, t);
    }
  }
});
