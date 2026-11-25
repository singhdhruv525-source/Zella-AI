// "Needs you now" in the notification bell (owner, 25 Nov 2026): the mapping from Today's items to bell notes, no
// duplicates with server notifications about the same call or task, and notes leaving once the item is dealt with.
import { test } from "node:test";
import assert from "node:assert/strict";
import { COVERED_KINDS, mergeBellNotes, needsNowNotes, pruneRead } from "../src/crm/needsNowNotes.js";
import { needsNowRows } from "../src/navigation/phoneHelpers.js";

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
  const { rows, unread, stale } = mergeBellNotes(server, notes, new Set(), { waiting: true, task: true });
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
  const { rows, unread, stale } = mergeBellNotes(server, notes, new Set(), { waiting: true, task: true });
  assert.ok(!rows.some((r) => r.key === "waiting:call-1" || r.key === "task:task-1"));
  assert.deepEqual(stale.sort(), ["s1", "s2"]);
  assert.equal(rows.find((r) => r.id === "s1").read_at, "read");
  assert.equal(unread, 2);
  // a list cut off at its limit (or that failed to load) proves nothing: nothing is marked read
  assert.deepEqual(mergeBellNotes(server, notes, new Set(), { waiting: false, task: false }).stale, []);
  // an already read server notification isn't marked again
  assert.deepEqual(mergeBellNotes([{ ...server[0], read_at: ago(0) }], [], new Set(), { waiting: true }).stale, []);
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
