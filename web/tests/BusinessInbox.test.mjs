import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { inboxItem, replyBlock, supportProblems } from "../src/crm/inbox.js";

// Exercise InboxPage's actual data flow before JSX, using the same lightweight
// lifecycle approach as useLoad.test.mjs; no DOM or database is required.
const source = readFileSync(new URL("../src/BusinessInbox.jsx", import.meta.url), "utf8");
const start = source.indexOf("export function InboxPage(");
const body = source.slice(start, source.indexOf("\n  return (", start))
  .replace("export function", "function");

test("paging retains the selected conversation's contact and reply availability", async () => {
  const alice = { id: "alice", first_name: "Alice", phone: "+15551234567" };
  const bob = { id: "bob", first_name: "Bob", phone: "+15557654321" };
  const contacts = { alice, bob };
  const row = (id, customer_id) => ({ kind: "convo", id, row: { id, customer_id, channel: "sms" } });
  const list = { rows: [row("1", "alice")], data: {}, reload() {} };
  const state = ["all", null];
  const loads = [];
  const requests = [];
  let stateIndex, loadIndex, pending;
  const context = vm.createContext({
    INBOX_PAGE: 50, inboxItem, supportProblems,
    useState: () => {
      const index = stateIndex++;
      return [state[index], (value) => { state[index] = value; }];
    },
    useRoster: () => ({}), useServerPages: () => list, useEffect() {},
    useLoad(loader, deps) {
      const index = loadIndex++;
      const previous = loads[index];
      if (!previous || deps.some((dep, i) => !Object.is(dep, previous.deps[i]))) {
        const entry = { deps, loading: true, data: previous?.data };
        loads[index] = entry;
        pending.push(loader().then((data) => { entry.data = data; entry.loading = false; }));
      }
      return loads[index];
    },
    async loadPeople(ids) {
      requests.push(Array.from(ids));
      return Object.fromEntries(ids.filter((id) => contacts[id]).map((id) => [id, contacts[id]]));
    },
    supabase: {
      rpc: async () => ({ data: [] }),
      from: () => ({ select: () => ({ eq: async () => ({ data: [{ provider: "telnyx", status: "active" }] }) }) }),
    },
  });
  const renderPage = vm.runInContext(`${body}\n return { current, person, personStatus, integrations };\n}\nInboxPage`, context);
  const render = () => {
    stateIndex = loadIndex = 0;
    pending = [];
    return renderPage({ workspace: { id: "business", timezone: "UTC" } });
  };
  const settle = async () => { render(); await Promise.all(pending); return render(); };
  await settle();
  state[1] = inboxItem(list.rows[0]);
  const before = await settle();
  assert.equal(before.person, alice);
  assert.deepEqual(requests.at(-1), ["alice"], "selection on the page is deduplicated");

  list.rows = [row("2", "bob")];
  list.data = {};
  const after = await settle();
  assert.deepEqual(requests.at(-1), ["alice", "bob"]);
  assert.equal(after.current.key, before.current.key);
  assert.equal(after.person, alice);
  assert.equal(after.personStatus, "ok");
  assert.equal(replyBlock({ channel: "sms", ...after }), null);

  list.rows = [];
  list.data = {};
  assert.equal((await settle()).person, alice, "an empty page also retains the contact");
  state[1] = null;
  assert.equal((await settle()).person, null);
  assert.deepEqual(requests.at(-1), [], "closing the selection drops its contact from the lookup");
});
