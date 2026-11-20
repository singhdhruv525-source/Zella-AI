// The one go live checklist (web/src/admin/goLive.js, UI-23).
import { test } from "node:test";
import assert from "node:assert/strict";
import { goLiveChecklist } from "../src/admin/goLive.js";

const server = {
  secrets: [
    { key: "ZELLA_APP_URL", label: "App URL", set: true, required: true, group: "core" },
    { key: "RESEND_API_KEY", label: "Resend", set: false, required: false, group: "email" },
    { key: "GOOGLE_CALENDAR_CLIENT_ID", label: "Google id", set: false, required: false, group: "calendar" },
    { key: "CALENDAR_REDIRECT_URL", label: "Return address", set: false, required: false, group: "calendar" },
  ],
  addresses: [{ key: "platform_emails_url", set: false }, { key: "email_from_address", set: true }, { key: "app_base_url", set: true }, { key: "n8n_base_url", set: false }, { key: "sms_from_number", set: false }],
  switches: [{ key: "email_live", on: false }, { key: "sms_live", on: false }, { key: "calls_live", on: false }, { key: "n8n_dispatch_enabled", on: true },
    { key: "provider_checks_live", on: false }, { key: "calendar_sync_live", on: false }, { key: "spam_workflow_live", on: false }],
};
const health = { n8n_secret_stored: false, jobs: [
  { name: "zella_dispatch", active: false, intended: "off", intent_reason: "Deliberately off until go live", intent_matches: true },
  { name: "zella_usage_thresholds", active: true },
], intent_only: [{ name: "zella_platform_emails", intended: "off", intent_reason: "Deliberately off until go live" }] };
const rows = (l) => Object.fromEntries(l.groups.flatMap((g) => g.rows).map((r) => [r.key, r]));

test("every go live item is on the one list: Resend key, email function address, email triggers, jobs and switches", () => {
  const r = rows(goLiveChecklist({ server, health, triggers: { platform_emails: false, staff_notifications: null } }));
  for (const k of ["RESEND_API_KEY", "platform_emails_url", "email_from_address", "zella_n8n_secret", "trigger_platform_emails", "trigger_staff_notifications",
    "zella_dispatch", "zella_platform_emails", "email_live", "sms_live", "calls_live", "n8n_dispatch_enabled"]) assert.ok(r[k], `${k} missing`);
  assert.equal(r.RESEND_API_KEY.state, "not_ready");
  assert.equal(r.ZELLA_APP_URL.state, "ready");
  assert.equal(r.CALENDAR_REDIRECT_URL.state, "ready", "the default return address is fine");
  assert.equal(r.zella_dispatch.state, "off_on_purpose");
  assert.equal(r.zella_dispatch.note, "Deliberately off until go live");
  assert.equal(r.zella_usage_thresholds.state, "ready");
  assert.equal(r.n8n_dispatch_enabled.state, "ready");
  assert.equal(r.trigger_staff_notifications.note, "Not created");
  assert.equal(r.email_live.approval, true, "live switches need the owner");
});

test("keys are tooltips only; the words shown have no keys and no dashes", () => {
  const l = goLiveChecklist({ server, health, triggers: { platform_emails: true, staff_notifications: true } });
  for (const r of l.groups.flatMap((g) => g.rows)) {
    assert.ok(r.hint, `${r.key} has no hint`);
    assert.doesNotMatch(`${r.label} ${r.detail}`, /[a-z]+_[a-z]+|[A-Z]{3,}_[A-Z]/, `${r.key} shows a key: ${r.label} ${r.detail}`);
    assert.doesNotMatch(`${r.label} ${r.detail} ${r.note ?? ""}`, /[-‐–—]/);
  }
});

test("a part that didn't load reads not checked, never ready", () => {
  const l = goLiveChecklist({ server: null, health: null, triggers: null });
  assert.equal(l.ready, 0);
  assert.ok(l.unknown > 0);
  assert.equal(l.unknown, l.total);
});

test("counts: ready, total and steps waiting for the owner", () => {
  const l = goLiveChecklist({ server, health, triggers: { platform_emails: false, staff_notifications: false } });
  const all = l.groups.flatMap((g) => g.rows);
  assert.equal(l.total, all.length);
  assert.equal(l.ready, all.filter((r) => r.state === "ready").length);
  assert.equal(l.approvals, all.filter((r) => r.approval && r.state !== "ready").length);
});
