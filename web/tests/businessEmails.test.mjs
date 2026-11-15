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

test("facts come from the data passed in, in the HTML and the plain text", () => {
  const r = renderEmail("C7", { invoice: "ZV 9", credit: "$5.00", newTotal: "$95.00" });
  for (const t of [r.html, r.text]) { assert.match(t, /\$95\.00/); assert.match(t, /\$5\.00/); assert.doesNotMatch(t, /\$150\.80/); }
  const e6 = renderEmail("E6", { newInterval: "Monthly", intervalAmount: "$149.00", unusedCredit: "$10.00", nextRenewal: "1 Jan 2027" });
  assert.match(e6.subject, /billed monthly/);
  for (const t of [e6.html, e6.text]) assert.match(t, /\$10\.00/);
  const i2 = renderEmail("I2", { month: "March", invoiced: "$1.00", paid: "$1.00", credits: "$0.50", balance: "$0.50" });
  assert.match(i2.subject, /March/);
  assert.match(i2.text, /Credits: \$0\.50/);
  assert.match(renderEmail("V5", { answerBy: "2 Feb 2027" }).text, /Answer by: 2 Feb 2027/);
  assert.match(renderEmail("F7", { paygMinutes: 7, paygAmount: "$2.45" }).text, /Minutes: 7[\s\S]*Amount: \$2\.45/);
});

test("emails about a change say which way it went", () => {
  const pairs = [["K2", "mfaOn", /turned on/, /turned off/], ["H1", "autoPayOn", /switched on/, /switched off/],
    ["H6", "billingAccessGranted", /can now see/, /can no longer see/], ["E9", "accountPaused", /paused/, /restored|active again/],
    ["G6", "disputeWon", /in our favour/, /in your favour/]];
  for (const [code, flag, yes, no] of pairs) {
    const a = renderEmail(code, { [flag]: true }), b = renderEmail(code, { [flag]: false });
    assert.match(a.subject + a.text, yes, `${code} true`);
    assert.match(b.subject + b.text, no, `${code} false`);
    assert.doesNotMatch(b.subject + b.text, yes, `${code} false says the opposite`);
  }
});

test("strict mode (the sender): a missing fact stops the email instead of using a sample value", () => {
  assert.throws(() => renderEmail("C3", { business: "B", role: "owner" }, { strict: true }), /MISSING_FIELD:C3:/);
  const n = renderEmail("N1", { business: "Glow Studio", role: "admin", title: "A task is late", severity: "warning" }, { strict: true });
  assert.equal(n.subject, "A task is late");
  assert.doesNotMatch(n.html + n.text, /Maple Street Dental|support@example\.com|Open Zella Voice/);
  assert.match(n.text, /an admin of Glow Studio/);
  assert.match(n.text, /Questions\? Reply to this email\./);
  const u = renderEmail("N1", { business: "B", role: "owner", title: "Emergency", severity: "urgent", mandatory: true, appUrl: "https://app.example.com", pagePath: "/calls" }, { strict: true });
  assert.equal(u.mandatory, true);
  assert.match(u.html, /https:\/\/app\.example\.com\/calls/);
});
