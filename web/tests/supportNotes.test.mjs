import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";

const source = readFileSync(new URL("../supabase/functions/owner-provision-business/index.ts", import.meta.url), "utf8");
const start = source.indexOf("const missingTable =");
const end = source.indexOf("async function ticketCreate(", start);
const code = stripTypeScriptTypes(source.slice(start, end));
const ticketNotes = new Function("obj", "list", "text", `${code}; return ticketNotes;`)(
  (v) => v ?? {}, (v, max) => (v ?? []).slice(0, max), (v, max) => typeof v === "string" ? v.trim().slice(0, max) : "",
);

function fakeAdmin(rows, errorAt = -1, error = null) {
  const pages = [];
  return { pages, from(table) {
    assert.equal(table, "support_ticket_notes");
    const orders = [];
    let ids, cursor = null;
    return {
      select() { return this; },
      in(column, values) { assert.equal(column, "ticket_id"); ids = values; return this; },
      or(expr) {
        const m = /^created_at\.gt\.(.+),and\(created_at\.eq\.(.+),id\.gt\.(.+)\)$/.exec(expr);
        assert.ok(m && m[1] === m[2], expr); cursor = { created_at: m[1], id: m[3] }; return this;
      },
      order(column, options) { orders.push([column, options.ascending]); return this; },
      async limit(n) {
        assert.deepEqual(orders, [["created_at", true], ["id", true]]);
        pages.push(cursor ? `${cursor.created_at}/${cursor.id}` : "start");
        if (pages.length - 1 === errorAt) return { data: null, error };
        const data = rows.filter((r) => ids.includes(r.ticket_id)).sort((a, b) =>
          a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id))
          .filter((r) => !cursor || r.created_at > cursor.created_at || (r.created_at === cursor.created_at && r.id > cursor.id));
        return { data: data.slice(0, n), error: null };
      },
    };
  } };
}
const tickets = [{ id: "t1", metadata: { notes: [{ text: "legacy" }] } }, { id: "t2", metadata: {} }];
for (const count of [0, 1000, 2501]) test(`all ${count} notes are returned with tied timestamps across page boundaries`, async () => {
  const rows = Array.from({ length: count }, (_, i) => ({
    id: String(i).padStart(5, "0"), ticket_id: i % 2 ? "t1" : "t2", body: `note ${i}`,
    author_id: null, created_at: "2026-11-16T00:00:00Z",
  })).reverse();
  const admin = fakeAdmin(rows);
  const result = await ticketNotes(admin, tickets);
  assert.equal(admin.pages.length, Math.floor(count / 1000) + 1);
  assert.equal(admin.pages[0], "start");
  for (const ticket of tickets) assert.deepEqual(result.get(ticket.id) ?? [], rows.filter((r) => r.ticket_id === ticket.id)
    .reverse().map(({ body, author_id, created_at }) => ({ body, author_id, created_at })));
});
for (const code of ["42P01", "PGRST205"]) test(`missing table ${code} keeps metadata fallback`, async () => {
  const result = await ticketNotes(fakeAdmin([], 0, { code }), tickets);
  assert.equal(result.get("t1")[0].body, "legacy");
  assert.deepEqual(result.get("t2"), []);
});
test("later page failures propagate rather than returning partial notes", async () => {
  const error = { code: "XX000" };
  const rows = Array.from({ length: 1000 }, (_, i) => ({ id: String(i), ticket_id: "t1", body: "note", author_id: null, created_at: "2026" }));
  await assert.rejects(ticketNotes(fakeAdmin(rows, 1, error), tickets), (e) => e === error);
});
test("no tickets need no queries", async () => {
  assert.equal((await ticketNotes({ from() { throw Error("unexpected query"); } }, [])).size, 0);
});

test("a note saved between pages is neither repeated nor skipped", async () => {
  const rows = Array.from({ length: 1000 }, (_, i) => ({ id: String(i).padStart(5, "0"), ticket_id: "t1", body: `note ${i}`, author_id: null, created_at: "2026-11-16T00:00:00Z" }));
  const admin = fakeAdmin(rows);
  const realFrom = admin.from.bind(admin);
  let calls = 0;
  admin.from = (t) => { if (++calls === 2) rows.push({ id: "00000a", ticket_id: "t1", body: "late", author_id: null, created_at: "2026-11-15T00:00:00Z" }); return realFrom(t); };
  const result = await ticketNotes(admin, tickets);
  const bodies = result.get("t1").map((n) => n.body);
  assert.equal(new Set(bodies).size, bodies.length, "no note repeated");
  assert.equal(bodies.length, 1000);
});
