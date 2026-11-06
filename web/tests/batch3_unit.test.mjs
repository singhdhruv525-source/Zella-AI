// Batch 3 unit tests: escalation count states, server paging state, linked-record titles, inbox support data.
//   cd web && node --test tests/batch3_unit.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { ATTENTION_START, attentionCount, attentionReduce, attentionWarning } from "../src/crm/attention.js";
import { PAGE_START, pageCursor, pageReduce, pageRows, pageStatus } from "../src/crm/pagingState.js";
import { linkIdsOf, linkTitle } from "../src/crm/links.js";
import { connected, inboxItem, replyBlock, supportProblems } from "../src/crm/inbox.js";

const A = "a0000000-0000-0000-0000-000000000001", B = "b0000000-0000-0000-0000-000000000002";
const start = (id = A) => attentionReduce(ATTENTION_START, { type: "reset", businessId: id });

test("B3-01: a real zero is zero; three is three", () => {
  const zero = attentionReduce(start(), { type: "ok", count: 0, businessId: A });
  assert.equal(zero.status, "ok"); assert.equal(attentionCount(zero), 0); assert.equal(attentionWarning(zero), false);
  const three = attentionReduce(start(), { type: "ok", count: 3, businessId: A });
  assert.equal(attentionCount(three), 3); assert.equal(attentionWarning(three), false);
});

test("B3-01: a failed refresh keeps the last count and marks it stale", () => {
  const three = attentionReduce(start(), { type: "ok", count: 3, businessId: A });
  const failed = attentionReduce(three, { type: "fail", businessId: A });
  assert.equal(failed.status, "stale"); assert.equal(attentionCount(failed), 3); assert.equal(attentionWarning(failed), true);
  const back = attentionReduce(failed, { type: "ok", count: 1, businessId: A });
  assert.equal(back.status, "ok"); assert.equal(attentionCount(back), 1);
});

test("B3-01: a first failure is 'unavailable', never 0 callers", () => {
  const s = attentionReduce(start(), { type: "fail", businessId: A });
  assert.equal(s.status, "unavailable"); assert.equal(s.count, null); assert.equal(attentionWarning(s), true);
  assert.equal(attentionCount(s), 0, "no badge is drawn, and the warning says the count is unknown");
  assert.equal(attentionReduce(start(), { type: "ok", count: null, businessId: A }).status, "unavailable", "a malformed answer is a failure");
  assert.equal(attentionReduce(start(), { type: "ok", count: -1, businessId: A }).status, "unavailable");
});

test("B3-01: switching business drops the old count and ignores answers for the old business", () => {
  const three = attentionReduce(start(A), { type: "ok", count: 3, businessId: A });
  const switched = attentionReduce(three, { type: "reset", businessId: B });
  assert.equal(switched.count, null); assert.equal(switched.status, "loading"); assert.equal(attentionCount(switched), 0);
  const late = attentionReduce(switched, { type: "ok", count: 9, businessId: A });
  assert.equal(late, switched, "a late answer for A changes nothing on B");
});

const page = (rows, next = null, total = rows.length) => ({ rows, next, total });

test("paging: newer request wins; an older answer is dropped", () => {
  let s = pageReduce({ ...PAGE_START, key: "k1" }, { type: "request", seq: 0 });
  s = pageReduce(s, { type: "filters", key: "k2" });          // filter changed while k1 was loading
  s = pageReduce(s, { type: "request", seq: s.seq });
  const old = pageReduce(s, { type: "ok", seq: 0, key: "k1", data: page([{ id: "old" }]) });
  assert.equal(old, s, "the old filter's answer is ignored");
  s = pageReduce(s, { type: "ok", seq: s.seq, key: "k2", data: page([{ id: "new" }]) });
  assert.deepEqual(pageRows(s).map((r) => r.id), ["new"]);
});

test("paging: next and previous follow the server's cursors", () => {
  let s = pageReduce({ ...PAGE_START, key: "k" }, { type: "request", seq: 0 });
  s = pageReduce(s, { type: "ok", seq: 0, key: "k", data: page([{ id: 1 }], { t: "2026-01-02", id: "x" }, 60) });
  assert.equal(pageCursor(s), null);
  s = pageReduce(s, { type: "next" });
  assert.equal(s.page, 1); assert.deepEqual(pageCursor(s), { t: "2026-01-02", id: "x" });
  s = pageReduce(s, { type: "request", seq: s.seq });
  assert.equal(pageReduce(s, { type: "next" }), s, "no double step while a page is loading");
  s = pageReduce(s, { type: "ok", seq: s.seq, key: "k", data: page([{ id: 2 }], null, 60) });
  assert.equal(pageReduce(s, { type: "next" }), s, "no next page when the server says there is none");
  s = pageReduce(s, { type: "prev" });
  assert.equal(s.page, 0); assert.equal(pageCursor(s), null);
});

test("paging: a failed refresh keeps the rows and is 'stale'; a first failure is 'failed'", () => {
  let s = pageReduce({ ...PAGE_START, key: "k" }, { type: "request", seq: 0 });
  assert.equal(pageStatus(s), "loading");
  const failedFirst = pageReduce(s, { type: "fail", seq: 0, key: "k", error: "boom" });
  assert.equal(pageStatus(failedFirst), "failed"); assert.deepEqual(pageRows(failedFirst), []);
  s = pageReduce(s, { type: "ok", seq: 0, key: "k", data: page([{ id: 1 }]) });
  s = pageReduce(s, { type: "reload" });
  s = pageReduce(s, { type: "request", seq: s.seq });
  s = pageReduce(s, { type: "fail", seq: s.seq, key: "k", error: "boom" });
  assert.equal(pageStatus(s), "stale"); assert.deepEqual(pageRows(s).map((r) => r.id), [1]);
  assert.equal(pageReduce(s, { type: "filters", key: "other" }).data, null, "another business or filter never shows the old rows");
});

test("B3-07: links resolve for the rows shown; missing, failed and loading are explicit", () => {
  const cols = [{ key: "property", type: "record" }, { key: "details", type: "text" }];
  const id1 = "11111111-1111-1111-1111-111111111111", id2 = "22222222-2222-2222-2222-222222222222";
  const rows = [{ data: { property: id1 } }, { data: { property: id1 } }, { data: { property: id2, details: id2 } }, { data: { property: "not-an-id" } }, { data: null }];
  assert.deepEqual(linkIdsOf(rows, cols), [id1, id2], "distinct, well-formed, from record columns only");
  assert.deepEqual(linkIdsOf(rows, [{ key: "details", type: "text" }]), []);
  assert.equal(linkTitle({ status: "ok", map: { [id1]: "12 Elm St" } }, id1), "12 Elm St");
  assert.equal(linkTitle({ status: "ok", map: {} }, id2), "Unavailable record", "deleted or another business's record");
  assert.equal(linkTitle({ status: "failed", map: {} }, id2), "Couldn't load");
  assert.equal(linkTitle({ status: "loading", map: {} }, id2), "…");
  assert.equal(linkTitle({ [id1]: "Old map" }, id1), "Old map", "plain maps still work");
});

const person = { id: "p", phone: "+15551234567", email: "a@b.test" };
const ok = (rows) => ({ status: "ok", rows });

test("B3-06: unknown integrations are not 'not connected'", () => {
  assert.equal(connected({ status: "failed", rows: [] }, "sms"), null);
  assert.equal(connected(ok([]), "sms"), false);
  assert.equal(connected(ok([{ provider: "telnyx", status: "active" }]), "sms"), true);
  assert.match(replyBlock({ channel: "sms", person, personStatus: "ok", integrations: { status: "failed", rows: [] } }).text, /Couldn't check whether text messaging is connected/);
  assert.match(replyBlock({ channel: "sms", person, personStatus: "ok", integrations: ok([]) }).text, /isn't connected yet/);
});

test("B3-06: a failed consent lookup never allows a reply", () => {
  const ints = ok([{ provider: "telnyx", status: "active" }, { provider: "resend", status: "active" }]);
  const b = replyBlock({ channel: "sms", person: undefined, personStatus: "failed", integrations: ints });
  assert.ok(b && b.retry, "paused, with Try again");
  assert.ok(replyBlock({ channel: "sms", person, personStatus: "loading", integrations: ints }), "still checking: not yet");
  assert.match(replyBlock({ channel: "sms", person: { ...person, do_not_sms: true }, personStatus: "ok", integrations: ints }).text, /asked not to be contacted/);
  assert.match(replyBlock({ channel: "email", person: { ...person, do_not_contact: true }, personStatus: "ok", integrations: ints }).text, /asked not to be contacted/);
  assert.equal(replyBlock({ channel: "sms", person, personStatus: "ok", integrations: ints }), null, "everything known: reply allowed (the server checks again)");
});

test("B3-06: the partial-data warning names what failed and carries no message content", () => {
  assert.equal(supportProblems({ previews: {}, people: {}, integrations: {} }), "");
  const t = supportProblems({ previews: { error: "secret message body" }, people: { error: "x" }, integrations: {} });
  assert.match(t, /message previews and names and contact preferences/);
  assert.doesNotMatch(t, /secret/);
});

test("B3-02: inbox rows map to items with stable keys", () => {
  assert.deepEqual(inboxItem({ kind: "call", id: "1", at: "t", row: { id: "1", customer_id: "c" } }).key, "c1");
  const v = inboxItem({ kind: "convo", id: "2", at: "t", row: { id: "2" } });
  assert.equal(v.key, "v2"); assert.equal(v.kind, "convo"); assert.equal(v.customer_id, null);
});
