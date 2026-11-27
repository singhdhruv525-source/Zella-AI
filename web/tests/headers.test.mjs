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
  // each origin is checked in the directive that governs its kind of load (CSP evaluates them separately); only real
  // loads count: the stylesheet and font links, and the Supabase API and realtime
  if (text.includes("https://fonts.googleapis.com")) assert.ok(csp["style-src"].includes("https://fonts.googleapis.com"), "stylesheet in style-src");
  if (text.includes("https://fonts.gstatic.com")) assert.ok(csp["font-src"].includes("https://fonts.gstatic.com"), "fonts in font-src");
  for (const o of ["https://pffqxlumqhjdbzvvoszm.supabase.co", "wss://pffqxlumqhjdbzvvoszm.supabase.co"]) assert.ok(csp["connect-src"].includes(o), `${o} in connect-src`);
  assert.ok(csp["img-src"].includes("https://pffqxlumqhjdbzvvoszm.supabase.co"), "stored images in img-src");
  assert.ok(!/<script>(?!\s*<\/script>)/.test(readFileSync(new URL("index.html", dist), "utf8")), "no inline script");
});

test("Stripe Embedded Checkout on the Pay step: exactly what Stripe's guide lists for Stripe.js and Checkout", async () => {
  const { STRIPE_JS_URL } = await import("../src/billing/stripeEmbedded.js");
  assert.equal(new URL(STRIPE_JS_URL).origin, "https://js.stripe.com", "Stripe.js only from js.stripe.com");
  assert.ok(csp["script-src"].includes("https://js.stripe.com") && csp["script-src"].includes("https://*.js.stripe.com"));
  for (const f of ["https://js.stripe.com", "https://*.js.stripe.com", "https://hooks.stripe.com", "https://checkout.stripe.com"]) assert.ok(csp["frame-src"].includes(f), `${f} in frame-src`);
  for (const c of ["https://api.stripe.com", "https://checkout.stripe.com"]) assert.ok(csp["connect-src"].includes(c), `${c} in connect-src`);
  // nothing wider than needed: no stripe wildcard for scripts or connections beyond those, and no other Stripe host
  const stripeHosts = Object.values(csp).flat().filter((v) => /stripe\.com/.test(v));
  assert.deepEqual([...new Set(stripeHosts)].sort(), ["https://*.js.stripe.com", "https://api.stripe.com", "https://checkout.stripe.com", "https://hooks.stripe.com", "https://js.stripe.com"]);
  assert.deepEqual(csp["frame-ancestors"], ["'none'"], "our own pages still can't be framed");
});
