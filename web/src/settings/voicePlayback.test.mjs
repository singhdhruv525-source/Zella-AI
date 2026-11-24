// The voice cards' play button: one sample at a time, press again to stop, quiet notes when there is no sample.
//   cd web && node --test src/settings/voicePlayback.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { answerToAction, buttonFor, initialPlayback, noteText, playbackReducer } from "./voicePlayback.js";

const run = (actions, s = initialPlayback) => actions.reduce(playbackReducer, s);

test("press loads, then plays, then ends", () => {
  let s = run([{ type: "press", voiceId: "katie" }]);
  assert.deepEqual([s.status, s.voiceId], ["loading", "katie"]);
  assert.equal(buttonFor(s, "katie", "Katie").mode, "loading");
  s = run([{ type: "playing", voiceId: "katie" }], s);
  assert.equal(buttonFor(s, "katie", "Katie").mode, "stop");
  assert.equal(buttonFor(s, "katie", "Katie").label, "Stop sample of Katie");
  s = run([{ type: "ended", voiceId: "katie" }], s);
  assert.deepEqual([s.status, s.voiceId], ["idle", null]);
});

test("pressing the same voice again stops it, while loading or playing", () => {
  assert.equal(run([{ type: "press", voiceId: "k" }, { type: "press", voiceId: "k" }]).status, "idle");
  assert.equal(run([{ type: "press", voiceId: "k" }, { type: "playing", voiceId: "k" }, { type: "press", voiceId: "k" }]).status, "idle");
});

test("only one plays at a time: another voice takes over, and the first's late answers are ignored", () => {
  const s = run([{ type: "press", voiceId: "a" }, { type: "playing", voiceId: "a" }, { type: "press", voiceId: "b" }]);
  assert.deepEqual([s.status, s.voiceId], ["loading", "b"]);
  assert.equal(buttonFor(s, "a", "A").mode, "play");
  assert.equal(run([{ type: "ended", voiceId: "a" }, { type: "playing", voiceId: "a" }, { type: "failed", voiceId: "a", kind: "try_again" }], s), s);
});

test("no sample yet: a quiet note on that card only, cleared by the next press", () => {
  let s = run([{ type: "press", voiceId: "elliot" }, { type: "failed", voiceId: "elliot", kind: "not_available" }]);
  assert.equal(s.status, "idle");
  assert.equal(buttonFor(s, "elliot", "Elliot").note, "Sample not available yet");
  assert.equal(buttonFor(s, "katie", "Katie").note, null);
  s = run([{ type: "press", voiceId: "elliot" }], s);
  assert.equal(buttonFor(s, "elliot", "Elliot").note, null);
  s = run([{ type: "failed", voiceId: "elliot", kind: "other" }], s);
  assert.equal(buttonFor(s, "elliot", "Elliot").note, "Sample didn't load. Try again.");
});

test("stop ends whatever plays", () => {
  assert.equal(run([{ type: "press", voiceId: "a" }, { type: "stop" }]).status, "idle");
});

test("the function's answers become actions", () => {
  assert.deepEqual(answerToAction("k", { ok: true, url: "https://x/s.mp3" }, null), { type: "url", voiceId: "k", url: "https://x/s.mp3" });
  assert.deepEqual(answerToAction("k", { ok: false, state: "not_available" }, null), { type: "failed", voiceId: "k", kind: "not_available" });
  assert.deepEqual(answerToAction("k", null, new Error("503")), { type: "failed", voiceId: "k", kind: "try_again" });
});

test("labels and notes have no dashes", () => {
  const s = run([{ type: "press", voiceId: "k" }]);
  for (const w of [buttonFor(s, "k", "Katie").label, buttonFor(initialPlayback, "k", "Katie").label, noteText("not_available"), noteText("try_again")]) {
    assert.doesNotMatch(w, /[-‐-―]/, w);
  }
});
