import { test } from "node:test";
import assert from "node:assert/strict";
import { CLASS_LABELS, classLabel, periodWords } from "../src/settings/panels/retentionLabels.js";

test("periods read as days or whole years", () => {
  assert.equal(periodWords(30), "30 days");
  assert.equal(periodWords(1), "1 day");
  assert.equal(periodWords(365), "1 year");
  assert.equal(periodWords(730), "2 years");
  assert.equal(periodWords(2555), "7 years");
  assert.equal(periodWords(400), "400 days");
  assert.equal(periodWords(366), "366 days");
  assert.equal(periodWords(729), "729 days");
  assert.equal(periodWords(0), "Not set");
  assert.equal(periodWords(null), "Not set");
});

test("every kind of data the server knows has a name and an explanation without dashes", () => {
  for (const c of ["call_recordings", "call_transcripts", "message_bodies", "audit_logs", "documents_replaced", "documents_owner_id_verified", "documents_cancelled_business", "cancelled_business"]) {
    assert.ok(CLASS_LABELS[c], c);
    assert.doesNotMatch(CLASS_LABELS[c].join(" "), /[-–—]/);
  }
  assert.equal(classLabel("unknown_kind"), "unknown_kind");
});
