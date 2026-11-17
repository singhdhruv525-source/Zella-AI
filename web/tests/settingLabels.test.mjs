// Platform settings are shown to admins by name, never by their key (UI-32).
import test from "node:test";
import assert from "node:assert/strict";
import { SETTING_LABELS, settingLabel } from "../src/copy/settingLabels.js";

const OPERATIONAL_KEYS = ["response_time_minutes", "task_overdue_grace_minutes", "task_escalate_hours", "team_summary_hour",
  "missed_call_max_seconds", "transfer_failure_threshold", "call_intel_monthly_limit", "ai_low_confidence_questions",
  "knowledge_repeat_threshold", "response_sample_rate", "invitation_reminder_hours", "setup_incomplete_after_days", "trial_notice_days"];

test("every operational rule has a label in words", () => {
  for (const key of OPERATIONAL_KEYS) {
    const label = settingLabel(key);
    assert.ok(SETTING_LABELS[key], `${key} has a label`);
    assert.doesNotMatch(label, /_/, `${key} label has no underscores`);
    assert.doesNotMatch(label, /[A-Za-z]-[A-Za-z]|[—–]/, `${key} label has no dashes`);
  }
});

test("a setting without a label still reads as words", () => {
  assert.equal(settingLabel("some_new_setting"), "Some new setting");
});
