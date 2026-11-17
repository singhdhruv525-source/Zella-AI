// Live switches are described to admins in words; the setting key is only a tooltip (UI-21).
import test from "node:test";
import assert from "node:assert/strict";
import { LIVE_SWITCHES, offSentence, switchHint, switchText } from "../src/copy/liveSwitches.js";

test("each live switch reads as words, on and off", () => {
  assert.equal(switchText("sms_live", false), "Texts are in test mode");
  assert.equal(switchText("email_live", true), "Emails are live");
  assert.equal(switchText("calls_live", false), "Outbound AI calls are off");
  assert.equal(switchText("provider_checks_live", false), "Provider checks are off");
  for (const key of Object.keys(LIVE_SWITCHES)) {
    for (const on of [true, false]) {
      const text = switchText(key, on);
      assert.doesNotMatch(text, /_|[A-Za-z]-[A-Za-z]|[—–]/, `${key} ${on} has no key or dash`);
    }
  }
});

test("an unknown switch still reads as words", () => {
  assert.equal(switchText("calendar_sync_live", true), "Calendar sync is on");
});

test("switches that are off, as one sentence", () => {
  assert.equal(offSentence(["sms_live"]), "Texts are in test mode.");
  assert.equal(offSentence(["sms_live", "email_live"]), "Texts and emails are in test mode.");
  assert.equal(offSentence([]), "");
});

test("the tooltip names the setting", () => {
  assert.equal(switchHint("sms_live"), "Setting sms_live");
});
