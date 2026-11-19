import { test } from "node:test";
import assert from "node:assert/strict";
import { lookupProblem } from "../src/contactLookup.js";

test("a lookup needs a business, 4 digits or a full email, and a reason", () => {
  const ok = { business: "b", query: "7788", reason: "Texts stopped" };
  assert.equal(lookupProblem(ok), "");
  assert.equal(lookupProblem({ ...ok, query: "casey@example.org" }), "");
  assert.equal(lookupProblem({ ...ok, query: "(555) 201-7788" }), "");
  assert.match(lookupProblem({ ...ok, business: null }), /business/);
  assert.match(lookupProblem({ ...ok, query: "778" }), /4 digits/);
  assert.match(lookupProblem({ ...ok, query: "casey" }), /4 digits/);
  assert.match(lookupProblem({ ...ok, reason: " " }), /reason/);
});
