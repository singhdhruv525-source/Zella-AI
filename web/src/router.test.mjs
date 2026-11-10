// node --test web/src/router.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { segments } from "./router.js";

test("segments() decodes normal parts and never throws on malformed encoding", () => {
  assert.deepEqual(segments("/app/records/hair%20color"), ["app", "records", "hair color"]);
  assert.deepEqual(segments("/app/%"), ["app", "%"]);
  assert.deepEqual(segments("/app/%E0%A4%A/x"), ["app", "%E0%A4%A", "x"]);
  assert.deepEqual(segments(""), []);
  assert.deepEqual(segments(undefined), []);
});
