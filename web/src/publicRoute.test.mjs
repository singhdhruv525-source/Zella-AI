// node --test web/src/publicRoute.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ADMIN_PAGES, publicRoute } from "./publicRoute.js";

const R64 = "a".repeat(64), U32 = "b".repeat(32);

test("an unknown top level address is unknown (Page not found when signed out), never the admin sign in", () => {
  for (const path of ["/pricing", "/pricing/", "/about", "/login", "/Status", "/app-store", "/welcomex", "/continue", "/rr", "/x/y"]) {
    assert.equal(publicRoute(path, "admin.example.test"), "unknown", path);
    assert.equal(publicRoute(path, "app.example.test"), "unknown", path);
  }
});

test("the front page: the admin dashboard on admin hosts, the CRM on the app host", () => {
  assert.equal(publicRoute("/", "admin.example.test"), "admin");
  assert.equal(publicRoute("/", "localhost"), "admin");
  assert.equal(publicRoute("/", "app.example.test"), "app-home");
  assert.equal(publicRoute("/", "APP.example.test"), "app-home");
  assert.equal(publicRoute("", "admin.example.test"), "admin");
  assert.equal(publicRoute(undefined, "app.example.test"), "app-home");
});

test("known routes open the same page as before, on every host", () => {
  for (const host of ["admin.example.test", "app.example.test"]) {
    const cases = {
      "/app": "business", "/app/": "business", "/app/settings/team": "business", "/welcome": "business", "/welcome/setup": "business",
      "/continue-plan": "continue", "/continue-plan/": "continue",
      "/status": "status", "/status/": "status", "/privacy": "privacy", "/terms/": "terms",
      [`/r/${R64}`]: "reschedule", [`/u/${U32}/`]: "unsubscribe", [`/w/${R64}`]: "waitlist",
      "/r/": "broken-link", "/r": "broken-link", "/u/abc": "broken-link", [`/w/${R64}/x`]: "broken-link",
      "/businesses": "admin", "/businesses/new": "admin", "/settings/profile/appearance": "admin", "/voice/numbers": "admin",
      "/audit-logs": "admin", "/security-abuse": "admin",
    };
    for (const [path, want] of Object.entries(cases)) assert.equal(publicRoute(path, host), want, `${host}${path}`);
  }
});

test("ADMIN_PAGES matches the admin dashboard's own pages (NAVIGATION in OwnerDashboard.jsx)", () => {
  const src = readFileSync(new URL("./OwnerDashboard.jsx", import.meta.url), "utf8");
  const nav = src.slice(src.indexOf("const NAVIGATION = ["), src.indexOf("];", src.indexOf("const NAVIGATION = [")));
  const paths = [...nav.matchAll(/path: "\/([^"]*)"/g)].map((m) => m[1]).filter(Boolean);
  assert.ok(paths.length > 10);
  assert.deepEqual([...paths].sort(), [...ADMIN_PAGES].sort());
});
