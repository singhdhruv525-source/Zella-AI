import { test } from "node:test";
import assert from "node:assert/strict";
import { evalPill, evalSummary } from "../src/aiTestingWords.js";

test("a failing run reads as a warning, never as a block", () => {
  assert.deepEqual(evalPill({ business_passes: true, total: 3, passed: 3 }, 3), ["success", "Passes"]);
  assert.deepEqual(evalPill({ business_passes: false, total: 3, passed: 2 }, 3), ["warning", "Warning"]);
  assert.deepEqual(evalPill({ business_passes: false, total: 2, passed: 2 }, 2), ["warning", "Too few questions"]);
  assert.deepEqual(evalPill(null, 4), ["neutral", "Not run yet"]);
  assert.deepEqual(evalPill(null, 0), ["neutral", "No questions"]);
  for (const run of [{ business_passes: false, total: 5, passed: 0 }, { business_passes: false, total: 1, passed: 0 }]) {
    assert.notEqual(evalPill(run, 5)[0], "danger");
  }
});

test("the run summary counts the questions", () => {
  assert.equal(evalSummary({ total: 3, passed: 2 }), "2 of 3 questions answered as expected");
  assert.equal(evalSummary({ total: 0, passed: 0 }), "No test questions");
  assert.equal(evalSummary(null), "");
});
