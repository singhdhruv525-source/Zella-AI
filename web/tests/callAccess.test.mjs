// Staff access to transcripts and recordings in Settings (src/settings/callAccess.js): a check that couldn't run says
// so and offers Try again; it is never shown as access being off.
//   cd web && node --test tests/callAccess.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { CALL_ACCESS_UNKNOWN, callAccessState } from "../src/settings/callAccess.js";

test("a check that couldn't run is unknown, not off", () => {
  assert.equal(callAccessState(null), "unknown");
  assert.equal(callAccessState(undefined), "unknown");
  assert.match(CALL_ACCESS_UNKNOWN, /couldn't check/);
  assert.doesNotMatch(CALL_ACCESS_UNKNOWN, /isn't switched on|off/i);
});

test("a confirmed answer keeps its own message", () => {
  assert.equal(callAccessState(true), "blocked");
  assert.equal(callAccessState(false), "choose");
});
