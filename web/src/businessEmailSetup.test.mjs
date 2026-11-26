import { test } from "node:test";
import assert from "node:assert/strict";
import { reasonWords, recordRows, senderSummary } from "./businessEmailSetup.js";

const base = { route: null, active_route: "fallback", fallback: { from_name: "Test Salon", reply_to: "front@salon.example" }, domain_status: "none", mailbox_status: "none" };

test("nothing set up: the fallback, with where replies go", () => {
  assert.deepEqual(senderSummary(base), { badge: "Not set up", tone: "neutral", text: "Customer emails come from Test Salon at Zella Voice's address; replies go to front@salon.example." });
  assert.match(senderSummary({ ...base, fallback: { from_name: "Test Salon", reply_to: null } }).text, /replies have nowhere to go/);
});
test("a domain: waiting, not verified, verified but switched off, verified and sending", () => {
  const d = { ...base, route: "domain", address: "hello@salon.example", domain: "salon.example" };
  assert.equal(senderSummary({ ...d, domain_status: "pending" }).badge, "Waiting for DNS");
  assert.deepEqual([senderSummary({ ...d, domain_status: "failed" }).badge, senderSummary({ ...d, domain_status: "failed" }).tone], ["Not verified", "danger"]);
  assert.match(senderSummary({ ...d, domain_status: "verified" }).text, /once the Zella Voice team switches business addresses on/);
  assert.deepEqual(senderSummary({ ...d, domain_status: "verified", active_route: "domain" }), { badge: "Verified", tone: "success", text: "Customer emails come from hello@salon.example." });
});
test("a mailbox: sending, switched off, at its daily limit, needing a reconnect", () => {
  const m = { ...base, route: "mailbox", mailbox_provider: "gmail", mailbox_account: "salon@gmail.example", mailbox_status: "connected" };
  assert.equal(senderSummary({ ...m, active_route: "mailbox" }).text, "Customer emails come from salon@gmail.example through Gmail.");
  assert.match(senderSummary(m).text, /once the Zella Voice team switches mailboxes on/);
  assert.equal(senderSummary({ ...m, cap_reached_today: true }).badge, "Daily limit reached");
  assert.deepEqual([senderSummary({ ...m, mailbox_status: "reconnect_needed", mailbox_provider: "outlook" }).badge, senderSummary({ ...m, mailbox_status: "reconnect_needed" }).tone], ["Reconnect needed", "danger"]);
});
test("DNS records: only complete ones, in order, with their priority and whether Resend found them", () => {
  assert.deepEqual(recordRows([{ type: "mx", name: "send", value: "feedback.example", priority: 10, status: "verified" }, { type: "TXT", name: "resend._domainkey", value: "p=x" }, { type: "TXT", name: "", value: "x" }, null]), [
    { key: "0:MX:send", type: "MX", name: "send", value: "feedback.example", priority: "10", ok: true },
    { key: "1:TXT:resend._domainkey", type: "TXT", name: "resend._domainkey", value: "p=x", priority: "", ok: false }]);
  assert.deepEqual(recordRows(undefined), []);
});
test("every refusal says what happened and whether anything was saved; unknown ones fall back", () => {
  for (const code of ["bad_address", "free_mailbox_domain", "platform_domain", "domain_taken", "provider_not_configured", "provider_unavailable", "provider_refused"]) assert.match(reasonWords(code), /Nothing was saved/, code);
  assert.match(reasonWords("something_new"), /nothing was changed/);
});
test("no dashes or hyphens in what people read (BRD-6)", () => {
  const texts = [senderSummary(base).text, ...["bad_address", "free_mailbox_domain", "platform_domain", "domain_taken", "not_allowed", "not_set_up", "provider_not_configured", "provider_unavailable", "provider_refused", "rate_limited", "sign_in_required", "not_configured", "x"].map(reasonWords)];
  for (const t of texts) assert.doesNotMatch(t, /[-‐‑‒–—―]/, t);
});

import { mailboxReturn } from "./businessEmailSetup.js";
test("back from the provider: canceled, refused or an error, in words; nothing for an ordinary visit", () => {
  assert.equal(mailboxReturn(""), null);
  assert.equal(mailboxReturn("?mailbox=cancelled").tone, "warning");
  assert.match(mailboxReturn("?mailbox=cancelled&reason=access_denied").text, /access wasn't allowed/);
  assert.match(mailboxReturn("?mailbox=error&reason=link_expired").text, /took too long/);
  assert.match(mailboxReturn("?mailbox=error&reason=<script>").text, /nothing was changed/);
  for (const r of ["not_your_sign_in", "link_expired", "no_refresh_token", "no_account_email", "access_denied", "invalid_grant"]) assert.doesNotMatch(reasonWords(r), /[-‐‑‒–—―]/, r);
});

// the owner's decisions of 27 Nov 2026: mailbox limits, the admin's link, pending domains expiring
import { linkSummary, mailboxLimits } from "./businessEmailSetup.js";
test("mailbox limits: the type's daily cap, 20 a minute and today's count; a type not known says the lowest limit is used", () => {
  const m = { ...base, route: "mailbox", mailbox_provider: "gmail", mailbox_status: "connected", mailbox_per_minute: 20, mailbox_sent_today: 12 };
  assert.equal(mailboxLimits({ ...m, mailbox_type: "google_workspace", mailbox_daily_cap: 1600 }), "Up to 1,600 emails a day (Google Workspace) and 20 a minute. 12 sent today.");
  assert.equal(mailboxLimits({ ...m, mailbox_type: "unknown", mailbox_daily_cap: 400 }), "Up to 400 emails a day (the type isn't known, so the lowest Gmail limit) and 20 a minute. 12 sent today.");
  assert.match(mailboxLimits({ ...m, mailbox_provider: "outlook", mailbox_type: "microsoft_365", mailbox_daily_cap: 8000 }), /8,000 emails a day \(Microsoft 365\)/);
  assert.equal(mailboxLimits({ ...m, mailbox_daily_cap: undefined }), null);
  assert.equal(mailboxLimits(base), null);
});
test("the admin's link, in words: sent, opened, expired, replaced; nothing when none was sent", () => {
  assert.match(linkSummary({ status: "open", expires_on: "4 Dec 2026" }).text, /works once, until 4 Dec 2026/);
  assert.match(linkSummary({ status: "used" }).text, /opened the link/);
  assert.match(linkSummary({ status: "expired" }).text, /expired/);
  assert.match(linkSummary({ status: "replaced" }).text, /newer link/);
  assert.equal(linkSummary(null), null);
});
test("a pending domain says when it is removed, only when the server gives a date", () => {
  const d = { ...base, route: "domain", address: "hello@salon.example", domain: "salon.example", domain_status: "pending" };
  assert.match(senderSummary({ ...d, domain_expires_on: "4 Dec 2026" }).text, /If it isn't verified by 4 Dec 2026, it is removed from the setup/);
  assert.match(senderSummary({ ...d, domain_status: "failed", domain_expires_on: "4 Dec 2026" }).text, /verified by 4 Dec 2026/);
  assert.doesNotMatch(senderSummary(d).text, /removed/);
});
test("the new words have no dashes or hyphens (BRD-6), and none falls back to the unknown answer", () => {
  const codes = ["already_connected", "too_many_links", "no_owner", "no_owner_email", "business_not_active", "email_not_queued", "mailbox_link_not_found", "mailbox_link_used",
    "mailbox_link_replaced", "mailbox_link_expired", "mailbox_link_not_yours", "not_owner", "reason_required", "not_pending", "domain_taken"];
  for (const c of codes) { assert.notEqual(reasonWords(c), reasonWords("x"), c); assert.doesNotMatch(reasonWords(c), /[-‐‑‒–—―]/, c); }
  for (const t of [linkSummary({ status: "open", expires_on: "4 Dec 2026" }), linkSummary({ status: "used" }), linkSummary({ status: "expired" })].map((x) => x.text)) assert.doesNotMatch(t, /[-‐‑‒–—―]/);
  assert.doesNotMatch(mailboxLimits({ route: "mailbox", mailbox_provider: "outlook", mailbox_type: "unknown", mailbox_daily_cap: 240, mailbox_per_minute: 20 }), /[-‐‑‒–—―]/);
});
