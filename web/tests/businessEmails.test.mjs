// Emails to businesses (src/emails/businessEmails.js): every code renders, every billing email in
// docs/BILLING_EMAILS.md exists, the wording follows the writing rules, values are escaped, links are https only, and
// the colours still match web/src/styles/tokens.css.
//   cd web && node --test tests/businessEmails.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { EMAILS, EMAIL_COLORS, GROUPS, renderEmail } from "../src/emails/businessEmails.js";

test("codes are unique and every email has a known group", () => {
  assert.equal(new Set(EMAILS.map((e) => e.code)).size, EMAILS.length);
  const groups = new Set(GROUPS.map(([k]) => k));
  for (const e of EMAILS) assert.ok(groups.has(e.group), e.code);
});

test("every billing email in docs/BILLING_EMAILS.md is in the catalogue", () => {
  const doc = readFileSync(new URL("../../docs/BILLING_EMAILS.md", import.meta.url), "utf8");
  const codes = [...doc.matchAll(/^\| ([A-I][0-9]) \|/gm)].map((m) => m[1]);
  assert.ok(codes.length >= 59, `found ${codes.length}`);
  const ours = new Set(EMAILS.map((e) => e.code));
  for (const c of codes) assert.ok(ours.has(c), `missing ${c}`);
});

test("every email renders with no gaps, no dashes, no emoji", () => {
  for (const e of EMAILS) {
    const r = renderEmail(e.code);
    assert.ok(r.subject && r.subject.length <= 120, `${e.code} subject`);
    assert.doesNotMatch(r.html + r.text, /undefined|NaN|\[object /, e.code);
    for (const t of [r.subject, r.preheader, r.text]) {
      assert.doesNotMatch(t, /[–—]/, `${e.code} long dash: ${t}`);
      assert.doesNotMatch(t.replace(/https:\/\/\S+/g, "").replace(/\S+@\S+/g, ""), /[A-Za-z]-[A-Za-z]/, `${e.code} hyphen: ${t}`);
      assert.doesNotMatch(t, /\p{Extended_Pictographic}/u, `${e.code} emoji`);
    }
    assert.match(r.html, /Zella Voice/);
    assert.match(r.text, e.mandatory ? /always sent/ : /turn this email off/);
  }
});

test("values are escaped and links must be https", () => {
  const r = renderEmail("S1", { business: '<script>alert(1)</script>"', owner: "A & B", appUrl: "javascript:alert(1)//" });
  assert.doesNotMatch(r.html, /<script>/);
  assert.match(r.html, /&lt;script&gt;/);
  assert.match(r.html, /A &amp; B/);
  assert.doesNotMatch(r.html, /href="javascript:/);
  assert.throws(() => renderEmail("Z9"), /UNKNOWN_EMAIL/);
});

test("email colours match the design tokens", () => {
  const tokens = readFileSync(new URL("../src/styles/tokens.css", import.meta.url), "utf8");
  const root = tokens.slice(tokens.indexOf(":root"), tokens.indexOf("}", tokens.indexOf(":root")));
  const token = (n) => root.match(new RegExp(`--zella-${n}:\\s*(#[0-9A-Fa-f]{6})`))?.[1]?.toUpperCase();
  const map = { bg: "bg", card: "card", subtle: "subtle", primary: "primary", primarySoft: "primary-soft", text: "text", text2: "text-2",
    faint: "text-faint", border: "border", success: "success", successBg: "success-bg", info: "info", infoBg: "info-bg",
    warning: "warning", warningBg: "warning-bg", danger: "danger", dangerBg: "danger-bg" };
  for (const [k, n] of Object.entries(map)) assert.equal(EMAIL_COLORS[k].toUpperCase(), token(n), `${k} vs --zella-${n}`);
});
