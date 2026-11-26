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
