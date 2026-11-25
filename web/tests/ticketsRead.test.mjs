// The Support page shows a tickets_list answer only when it holds a list of tickets; anything else is a failed read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readTickets } from "../src/admin/ticketsRead.js";

test("a tickets answer needs a list of tickets; an empty list is a real none", () => {
  assert.deepEqual(readTickets({ tickets: [], assignees: [] }).tickets, []);
  const ok = { tickets: [{ id: "st1" }], conversations: true };
  assert.equal(readTickets(ok), ok);
  for (const bad of [null, undefined, "", 0, [], {}, { tickets: null }, { tickets: "none" }, { tickets: {} }, { error: "x" }]) {
    assert.throws(() => readTickets(bad), /couldn't be read/, JSON.stringify(bad));
  }
});
