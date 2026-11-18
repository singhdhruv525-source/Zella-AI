// web/public/_headers (security audit 18 Nov 2026, M14): the security headers Cloudflare Pages sends, and a report only
// CSP that covers every outside address the built app actually uses.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync } from "node:fs";

const file = new URL("../public/_headers", import.meta.url);
const lines = readFileSync(file, "utf8").split("\n").filter((l) => l.startsWith("  "));
const h = Object.fromEntries(lines.map((l) => { const i = l.indexOf(":"); return [l.slice(0, i).trim().toLowerCase(), l.slice(i + 1).trim()]; }));
const csp = Object.fromEntries(h["content-security-policy-report-only"].split(";").map((d) => d.trim().split(/\s+/)).map(([k, ...v]) => [k, v]));

test("the basic security headers are set", () => {
  assert.equal(h["x-content-type-options"], "nosniff");
  assert.equal(h["x-frame-options"], "DENY");
  assert.equal(h["referrer-policy"], "strict-origin-when-cross-origin");
  assert.match(h["strict-transport-security"], /max-age=31536000/);
  for (const f of ["camera", "microphone", "geolocation"]) assert.match(h["permissions-policy"], new RegExp(`${f}=\\(\\)`));
});
test("the CSP is report only for now, blocks framing and plugins, and allows no inline or eval scripts", () => {
  assert.ok(!("content-security-policy" in h));
  assert.deepEqual(csp["frame-ancestors"], ["'none'"]);
  assert.deepEqual(csp["object-src"], ["'none'"]);
  assert.ok(!csp["script-src"].some((s) => /unsafe/.test(s)));
});
test("every outside address in the built app is allowed by the CSP", () => {
  const dist = new URL("../dist/", import.meta.url);
  if (!existsSync(dist)) return;   // run after `npx vite build`
  const files = ["index.html", ...readdirSync(new URL("assets/", dist)).map((f) => "assets/" + f)].filter((f) => /\.(html|js|css)$/.test(f));
  const text = files.map((f) => readFileSync(new URL(f, dist), "utf8")).join("\n");
  const allowed = new Set(Object.values(csp).flat());
  // only real loads: stylesheet and font links, and fetch/URL literals; documentation links in bundled code are not loads
  for (const origin of ["https://fonts.googleapis.com", "https://fonts.gstatic.com"]) if (text.includes(origin)) assert.ok(allowed.has(origin), origin);
  assert.ok(allowed.has("https://pffqxlumqhjdbzvvoszm.supabase.co") && allowed.has("wss://pffqxlumqhjdbzvvoszm.supabase.co"));
  assert.ok(!/<script>(?!\s*<\/script>)/.test(readFileSync(new URL("index.html", dist), "utf8")), "no inline script");
});
