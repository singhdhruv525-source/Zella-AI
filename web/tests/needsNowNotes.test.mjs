// "Needs you now" in the notification bell (owner, 25 Nov 2026): the mapping from Today's items to bell notes, no
// duplicates with server notifications about the same call or task, and notes leaving once the item is dealt with.
import { test } from "node:test";
import assert from "node:assert/strict";
import { COVERED_KINDS, mergeBellNotes, needsNowNotes, pruneRead } from "../src/crm/needsNowNotes.js";
import { createPendingStore, deferChange, needsNowRows, undoAll } from "../src/navigation/phoneHelpers.js";
import { SOURCES_START, countValue, listRead, nextSources, signalsFrom, spamRead } from "../src/crm/needsNowSignals.js";

const NOW = Date.parse("2026-11-25T18:00:00Z");
const ago = (min) => new Date(NOW - min * 60000).toISOString();
const SIGNALS = {
  waiting: [{ id: "call-1", name: "Tom Becker", summary: "Private dining for 20", since: ago(4) }, { id: "call-2", name: null, summary: null, since: ago(2) }],
  overdue: [{ id: "task-1", title: "Confirm cake delivery", who: "Maya Chen", due_at: ago(60) }, { id: "task-2", title: "", who: null, due_at: ago(5) }],
  spam: 1, at: ago(0), now: NOW,
};

test("every Needs you now item has a bell note that opens the same page", () => {
  const notes = needsNowNotes(SIGNALS);
  const rows = needsNowRows({ waiting: SIGNALS.waiting.length, oldest: SIGNALS.waiting[0], overdue: SIGNALS.overdue, spam: SIGNALS.spam, now: NOW });
  // each kind of row Today shows is covered, and the notes open the page that row opens
  for (const row of rows) assert.ok(notes.some((n) => n.page_key === row.page), `no note opens ${row.page}`);
  assert.deepEqual(notes.map((n) => [n.key, n.page_key]), [
    ["waiting:call-1", "attention"], ["waiting:call-2", "attention"], ["task:task-1", "tasks"], ["task:task-2", "tasks"], ["spam:1", "spam"],
  ]);
});

test("the notes' words", () => {
  const [a, b, t1, t2, s] = needsNowNotes(SIGNALS);
  assert.equal(a.title, "Tom Becker wants a person");
  assert.equal(a.body, "Asked about private dining for 20. Waiting 4 min");
  assert.equal(a.severity, "urgent");
  assert.equal(b.title, "A caller wants a person");
  assert.equal(b.body, "Your AI receptionist handed them over. Waiting 2 min");
  assert.equal(t1.title, "Overdue: Confirm cake delivery");
  assert.equal(t1.body, "Task for Maya Chen, due 1 hr ago");
  assert.equal(t2.title, "Overdue: a task");
  assert.equal(t2.body, "Due 5 min ago");
  assert.equal(s.title, "1 call to review in Spam protection");
  assert.equal(needsNowNotes({ spam: 3 })[0].title, "3 calls to review in Spam protection");
  for (const n of [a, b, t1, t2, s]) assert.ok(!/[A-Za-z]-[A-Za-z]|[—–]/.test(`${n.title} ${n.body}`), "no dashes in visible text");
});

test("nothing needs the owner: no notes", () => {
  assert.deepEqual(needsNowNotes({}), []);
  assert.deepEqual(needsNowNotes({ waiting: [{ name: "no id" }], overdue: [{ title: "no id" }], spam: 0 }), []);
});

test("one note per item, however often it is read", () => {
  const a = needsNowNotes(SIGNALS), b = needsNowNotes({ ...SIGNALS, now: NOW + 60000 });
  assert.deepEqual(a.map((n) => n.key), b.map((n) => n.key));
  const { rows, unread } = mergeBellNotes([], [...a, ...a.slice(0, 0)], new Set());
  assert.equal(rows.length, 5);
  assert.equal(unread, 5);
});

test("a server notification about the same call or task is not shown twice", () => {
  const notes = needsNowNotes(SIGNALS);
  const server = [
    { id: "s1", kind: "escalation_unacknowledged", entity_id: "call-1", created_at: ago(1), read_at: null },
    { id: "s2", kind: "task_overdue", entity_id: "task-1", created_at: ago(1), read_at: null },
    { id: "s3", kind: "new_lead", entity_id: "lead-9", created_at: ago(3), read_at: null },
  ];
  const { rows, unread, stale } = mergeBellNotes(server, notes, new Set(), { waiting: true, task: true }, ago(0));
  assert.deepEqual(rows.map((r) => r.id).sort(), ["s3", "spam:1", "task:task-1", "task:task-2", "waiting:call-1", "waiting:call-2"]);
  assert.deepEqual(rows.slice(0, 4).map((r) => r.id), ["waiting:call-1", "waiting:call-2", "task:task-1", "task:task-2"], "callers, then tasks, as Today lists them");
  assert.equal(rows[4].id, "spam:1");
  assert.equal(rows[5].id, "s3");
  assert.ok(!rows.some((r) => r.id === "s1" || r.id === "s2"));
  assert.equal(unread, 6);
  assert.deepEqual(stale, []);
  assert.deepEqual(Object.keys(COVERED_KINDS).sort(), ["escalation_unacknowledged", "task_overdue"]);
});

test("once the caller is handled or the task is done, the note leaves and the server one is marked read", () => {
  const server = [
    { id: "s1", kind: "escalation_unacknowledged", entity_id: "call-1", created_at: ago(1), read_at: null },
    { id: "s2", kind: "task_overdue", entity_id: "task-1", created_at: ago(1), read_at: null },
  ];
  // call-1 handled and task-1 done: neither is in "Needs you now" any more
  const notes = needsNowNotes({ waiting: [SIGNALS.waiting[1]], overdue: [SIGNALS.overdue[1]], now: NOW });
  const { rows, unread, stale } = mergeBellNotes(server, notes, new Set(), { waiting: true, task: true }, ago(0));
  assert.ok(!rows.some((r) => r.key === "waiting:call-1" || r.key === "task:task-1"));
  assert.deepEqual(stale.sort(), ["s1", "s2"]);
  assert.ok(!rows.some((r) => r.id === "s1" || r.id === "s2"), "handled: they leave the bell, as the notes did");
  assert.equal(unread, 2);
  // already read and handled: it leaves the bell too, but needs no mark read
  const readOne = mergeBellNotes([{ ...server[0], read_at: ago(0) }], notes, new Set(), { waiting: true }, ago(0));
  assert.ok(!readOne.rows.some((r) => r.id === "s1"));
  assert.deepEqual(readOne.stale, []);
  // not proven handled (the list wasn't read in full): kept, unread
  const unsure = mergeBellNotes(server, notes, new Set(), { waiting: false, task: false }, ago(0));
  assert.ok(unsure.rows.some((r) => r.id === "s1") && unsure.rows.some((r) => r.id === "s2"));
  // a list cut off at its limit (or that failed to load) proves nothing: nothing is marked read
  assert.deepEqual(mergeBellNotes(server, notes, new Set(), { waiting: false, task: false }).stale, []);
  // an already read server notification isn't marked again
  assert.deepEqual(mergeBellNotes([{ ...server[0], read_at: ago(0) }], [], new Set(), { waiting: true }, ago(0)).stale, []);
});

test("read on this device, counted out of the unread total, and forgotten once the item leaves", () => {
  const notes = needsNowNotes(SIGNALS);
  const read = new Set(["waiting:call-1", "spam:1", "task:gone"]);
  const { rows, unread } = mergeBellNotes([{ id: "s9", kind: "new_lead", created_at: ago(1), read_at: ago(0) }], notes, read);
  assert.equal(unread, 3);
  assert.equal(rows.find((r) => r.key === "spam:1").read_at, "read");
  assert.deepEqual([...pruneRead(read, notes)].sort(), ["spam:1", "waiting:call-1"]);
  // more spam to review than when it was read: a new, unread note
  const more = needsNowNotes({ spam: 2 });
  assert.equal(mergeBellNotes([], more, read).unread, 1);
});

test("a server notification is only cleared by a read newer than it", () => {
  const row = { id: "s1", kind: "escalation_unacknowledged", entity_id: "call-7", created_at: ago(5), read_at: null };
  // read after the notification was written, and the call isn't waiting any more: cleared
  assert.deepEqual(mergeBellNotes([row], [], new Set(), { waiting: true }, ago(1)).stale, ["s1"]);
  // read before it was written: that read can't have seen the call, so nothing is cleared
  assert.deepEqual(mergeBellNotes([row], [], new Set(), { waiting: true }, ago(10)).stale, []);
  // the same moment, no read time, or a row without a time: nothing is cleared
  assert.deepEqual(mergeBellNotes([row], [], new Set(), { waiting: true }, ago(5)).stale, []);
  assert.deepEqual(mergeBellNotes([row], [], new Set(), { waiting: true }).stale, []);
  assert.deepEqual(mergeBellNotes([{ ...row, created_at: null }], [], new Set(), { waiting: true }, ago(0)).stale, []);
  // still shown, unread, until it is cleared
  assert.equal(mergeBellNotes([row], [], new Set(), { waiting: true }, ago(10)).unread, 1);
});

test("callers past the list's cap share one summary note, so every waiting caller is counted", () => {
  const listed = Array.from({ length: 500 }, (_, n) => ({ id: `call-${n}`, name: null, since: ago(3) }));
  const notes = needsNowNotes({ waiting: listed, waitingMore: 37, at: ago(0), now: NOW });
  const callers = notes.filter((n) => n.page_key === "attention");
  assert.equal(callers.length, 501);
  const more = callers.at(-1);
  assert.equal(more.key, "waiting-more:37");
  assert.equal(more.title, "And 37 more callers want a person");
  assert.equal(more.body, "Open Needs attention to see them all");
  assert.equal(listed.length + 37, 537, "500 notes for the listed callers plus 37 in the summary");
  assert.equal(mergeBellNotes([], notes, new Set()).unread, 501);
  assert.equal(needsNowNotes({ waitingMore: 1 })[0].title, "And 1 more caller wants a person");
  assert.deepEqual(needsNowNotes({ waiting: listed.slice(0, 3), waitingMore: 0 }).map((n) => n.key), ["waiting:call-0", "waiting:call-1", "waiting:call-2"]);
});

test("overdue tasks past the list's limit: the real total on Today, one summary note in the bell", () => {
  const listed = Array.from({ length: 100 }, (_, n) => ({ id: `task-${n}`, title: `Task ${n}`, who: null, due_at: ago(90) }));
  const row = needsNowRows({ overdue: listed, overdueTotal: 101, now: NOW }).find((r) => r.key === "overdue");
  assert.equal(row.title, "101 overdue tasks");
  const notes = needsNowNotes({ overdue: listed, overdueMore: 1, at: ago(0), now: NOW });
  assert.equal(notes.filter((n) => n.page_key === "tasks").length, 101);
  const more = notes.at(-1);
  assert.equal(more.key, "task-more:1");
  assert.equal(more.title, "And 1 more overdue task");
  assert.equal(needsNowNotes({ overdueMore: 5 })[0].title, "And 5 more overdue tasks");
  // no total given: the list's own length; nothing overdue: no row and no note
  assert.equal(needsNowRows({ overdue: listed.slice(0, 2), now: NOW })[0].title, "2 overdue tasks");
  assert.equal(needsNowRows({ overdue: listed.slice(0, 1), overdueTotal: 1, now: NOW })[0].title, "Task 0");
  assert.deepEqual(needsNowRows({ overdue: [], overdueTotal: 0, now: NOW }), []);
  assert.deepEqual(needsNowNotes({ overdue: [], overdueMore: 0 }), []);
});


const ok = (rows, count) => ({ data: rows, count, error: null });

test("a read that fails keeps the last good value, marked as unavailable, and never counts as complete", () => {
  let src = nextSources(SOURCES_START, { waiting: listRead(ok([{ id: "c1" }], 1)), overdue: listRead(ok([{ id: "t1" }], 1)), spam: spamRead({ data: { unreviewed: 2 } }) });
  let s = signalsFrom(src, ago(1));
  assert.deepEqual([s.waiting.length, s.overdue.length, s.spam], [1, 1, 2]);
  assert.deepEqual(s.complete, { waiting: true, task: true });
  assert.equal(s.ready, true);
  assert.equal(s.unavailable, false);
  // all three fail next time: the items stay, the lists are not complete, read keys must not be pruned
  src = nextSources(src, { waiting: listRead({ data: null, error: new Error("offline") }), overdue: listRead({ error: {} }), spam: spamRead({ error: {} }) });
  s = signalsFrom(src, ago(0));
  assert.deepEqual([s.waiting.length, s.overdue.length, s.spam], [1, 1, 2], "last good values kept");
  assert.deepEqual(s.status, { waiting: "stale", overdue: "stale", spam: "stale" });
  assert.deepEqual(s.complete, { waiting: false, task: false });
  assert.equal(s.ready, false);
  assert.equal(s.unavailable, true);
  // so nothing in the bell is marked read on a failed read
  const server = [{ id: "s1", kind: "escalation_unacknowledged", entity_id: "c9", created_at: ago(5), read_at: null }];
  assert.deepEqual(mergeBellNotes(server, needsNowNotes({ waiting: s.waiting }), new Set(), s.complete, s.at).stale, []);
});

test("a first read that fails shows nothing as none: unavailable, not empty and complete", () => {
  const s = signalsFrom(nextSources(SOURCES_START, { waiting: listRead({ error: {} }), overdue: listRead(ok([], 0)), spam: spamRead({ error: {} }) }), ago(0));
  assert.deepEqual(s.status, { waiting: "failed", overdue: "ok", spam: "failed" });
  assert.equal(s.unavailable, true);
  assert.deepEqual(s.complete, { waiting: false, task: true }, "a successful empty list is complete; a failed one is not");
  assert.deepEqual(spamRead(null, false), { type: "ok", value: 0 }, "a role that can't see spam: a real none");
});

test("waiting callers are complete only when one read holds every row its count says exist", () => {
  // the rows and the count come from the same request: no call can slip between pages
  assert.equal(listRead(ok([{ id: "a" }, { id: "b" }], 2)).value.complete, true);
  // a call dealt with and a new one arriving between two separate reads would show as a different count: incomplete
  const shifted = listRead(ok([{ id: "a" }, { id: "c" }], 3)).value;
  assert.equal(shifted.complete, false);
  assert.equal(shifted.more, 1);
  // past the cap (or a server row limit): the rest are counted in one note, and the list is not complete
  const capped = listRead(ok(Array.from({ length: 500 }, (_, n) => ({ id: `c${n}` })), 537)).value;
  assert.deepEqual([capped.complete, capped.more, capped.total], [false, 37, 537]);
  // no count given: not proven complete
  assert.equal(listRead({ data: [{ id: "a" }], count: null }).value.complete, false);
  assert.deepEqual(listRead({ data: "odd" }), { type: "fail" });
  const s = signalsFrom(nextSources(SOURCES_START, { waiting: listRead(ok([{ id: "a" }], 3)) }), ago(0));
  assert.equal(s.complete.waiting, false);
  assert.equal(s.waitingMore, 2);
});

function fakeTimers() {
  let queue = [];
  return { setTimeout: (fn) => { const t = { fn }; queue.push(t); return t; }, clearTimeout: (t) => { queue = queue.filter((q) => q !== t); },
    run: async () => { const q = queue; queue = []; for (const t of q) await t.fn(); } };
}

test("quick changes kept by the app: leaving the page keeps the window and the Undo, and the row never flickers back", async () => {
  const timers = fakeTimers();
  const store = createPendingStore();
  const events = [];
  store.subscribe((e) => events.push(e.type));
  const sent = [];
  const change = deferChange({ commit: async () => { sent.push("t1"); store.succeed("t1"); }, revert: () => store.drop("t1"), timers });
  store.add("t1", change, { hidden: true });
  assert.equal(store.views().get("t1").hidden, true);
  assert.equal(store.waiting(), 1);
  // the page is left: nothing is sent and Undo still works (no page flush any more)
  assert.equal(undoAll(store.changes()), 1);
  await timers.run();
  assert.deepEqual(sent, []);
  assert.equal(store.views().has("t1"), false, "undone: the row is back");
  // again, and this time the window passes: sent once, its view stays until the page has read again
  const c2 = deferChange({ commit: async () => { sent.push("t2"); store.succeed("t2"); }, revert: () => store.drop("t2"), timers });
  store.add("t2", c2, { hidden: true });
  await timers.run();
  assert.deepEqual(sent, ["t2"]);
  assert.equal(store.views().get("t2").hidden, true, "settled: still hidden until the list is read again");
  store.clearSettled("t2");
  assert.equal(store.views().has("t2"), false);
  assert.deepEqual(events, ["add", "drop", "add", "sent", "settled"]);
  // closing the page (pagehide) sends what is still waiting
  const c3 = deferChange({ commit: async () => { sent.push("t3"); }, timers });
  store.add("t3", c3, { hidden: true });
  await store.flushAll();
  assert.deepEqual(sent, ["t2", "t3"]);
});

test("a count from the server must be a real count: anything else is a failed read, never 0", () => {
  for (const bad of [null, undefined, "", " ", true, false, "a few", NaN, Infinity, -1, {}, []]) {
    assert.equal(countValue(bad), null, `${JSON.stringify(bad)} is not a count`);
    assert.deepEqual(spamRead({ data: { unreviewed: bad } }), { type: "fail" });
  }
  assert.equal(countValue(0), 0, "a real 0 is a count");
  assert.equal(countValue(5), 5);
  assert.equal(countValue("3"), 3, "a numeric string from the server");
  assert.deepEqual(spamRead({ data: { unreviewed: 0 } }), { type: "ok", value: 0 });
  assert.deepEqual(spamRead({ data: { unreviewed: "2" } }), { type: "ok", value: 2 });
  // the admin's open ticket count reads the same way (navigation/AdminPhone.jsx)
  assert.equal(countValue({ openTickets: null }.openTickets), null);
});

test("a numeric string too large to be a number is not a count", () => {
  assert.equal(countValue("9".repeat(309)), null);
  assert.deepEqual(spamRead({ data: { unreviewed: "9".repeat(309) } }), { type: "fail" });
  assert.equal(countValue("0"), 0);
  assert.equal(countValue("3"), 3);
});
