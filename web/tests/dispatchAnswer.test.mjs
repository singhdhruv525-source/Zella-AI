// n8n's answer per workflow in words (web/src/admin/dispatchAnswer.js, OPS-17).
import { test } from "node:test";
import assert from "node:assert/strict";
import { answersByWorkflow, dispatchAnswer } from "../src/admin/dispatchAnswer.js";

test("each answer reads in plain words with its tone", () => {
  assert.deepEqual(dispatchAnswer({ status_code: 200 }), { tone: "success", label: "Accepted (200)", kind: "accepted" });
  assert.equal(dispatchAnswer({ status_code: 401 }).label, "Refused: wrong secret (401)");
  assert.equal(dispatchAnswer({ status_code: 403 }).tone, "danger");
  assert.equal(dispatchAnswer({ status_code: 404 }).label, "Workflow not published (404)");
  assert.equal(dispatchAnswer({ status_code: 500 }).label, "Answered 500");
  assert.equal(dispatchAnswer({ status_code: null, error: "Timed out" }).label, "No answer: Timed out");
  assert.equal(dispatchAnswer({ status_code: null, waiting: true }).label, "Waiting for the answer");
  assert.equal(dispatchAnswer({ status_code: null }).label, "Not recorded yet");
});

test("another request still waiting is shown beside the previous answer, never as a plain success", () => {
  const a = dispatchAnswer({ status_code: 200, waiting: true });
  assert.equal(a.label, "Accepted (200), another request is waiting");
  assert.equal(a.tone, "neutral");
  assert.equal(a.pending, true);
  assert.equal(dispatchAnswer({ status_code: 401, waiting: true }).tone, "danger");
});

test("nothing known is null, never a guess", () => {
  assert.equal(dispatchAnswer(undefined), null);
  assert.equal(answersByWorkflow(null).size, 0);
  assert.equal(answersByWorkflow([{ workflow: "sms-sender", status_code: 200 }]).get("sms-sender").status_code, 200);
});

test("no label has a dash", () => {
  for (const r of [{ status_code: 200 }, { status_code: 401 }, { status_code: 404 }, { status_code: 502 }, { error: "x" }, { waiting: true }, { status_code: 200, waiting: true }, {}]) {
    assert.doesNotMatch(dispatchAnswer(r).label, /[-‐–—]/);
  }
});
