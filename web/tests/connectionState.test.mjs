import { test } from "node:test";
import assert from "node:assert/strict";
import { answeringText, livePill, missingForLive, NOT_TRACKED } from "../src/connectionState.js";

test("live comes from the server's flag only, and never shows when the definition isn't available", () => {
  assert.deepEqual(livePill({ live: true, status: "active" }), ["success", "Live"]);
  assert.deepEqual(livePill({ live: false, status: "active", checks: { phone: true, voice: true } }), ["neutral", "Not live"]);
  assert.deepEqual(livePill({ live: true, status: "active" }, false), ["neutral", "Not available"]);
  assert.deepEqual(livePill({ live: false, status: "paused" }), ["warning", "Paused"]);
  assert.deepEqual(livePill({ live: false, status: "active", businessState: "suspended" }), ["warning", "Business suspended"]);
  assert.deepEqual(livePill({ live: false, status: "weird" }), ["neutral", "Unknown"]);
});

test("answering is its own line, with the time of the last served call", () => {
  const day = new Date(Date.now() - 86400000).toISOString();
  assert.match(answeringText(true, day), /^Answered a call /);
  assert.match(answeringText(false, day), /^No call answered in 7 days \(last /);
  assert.equal(answeringText(false, null), "No call answered yet");
  assert.equal(answeringText(true, day, false), "Answering not available");
});

test("what is missing before a receptionist can be live", () => {
  assert.deepEqual(missingForLive({ businessState: "active", status: "active", checks: { phone: true, voice: false } }), ["the number linked to Vapi"]);
  assert.deepEqual(missingForLive({ businessState: "setup", status: "paused", checks: { phone: false } }), ["setup finished", "receptionist switched on", "an active phone number"]);
  assert.deepEqual(missingForLive({ businessState: "active", status: "active", checks: { phone: true, voice: true } }), []);
  assert.equal(NOT_TRACKED, "Not tracked");
});
