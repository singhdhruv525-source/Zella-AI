// PLT-06: the crawls never treat a missing axe-core as "no problems".
const test = require("node:test");
const assert = require("node:assert/strict");
const { loadAxe, runAxe, INSTALL } = require("./axe.cjs");

test("loadAxe reads the pinned copy", () => {
  const old = process.env.AXE; delete process.env.AXE;
  try { assert.match(loadAxe(), /axe/); } finally { if (old !== undefined) process.env.AXE = old; }
});

test("loadAxe stops with the install step when the file is missing", () => {
  const old = process.env.AXE; process.env.AXE = "/nonexistent/axe.min.js";
  try { assert.throws(() => loadAxe(), (e) => e.message.startsWith(INSTALL)); } finally { if (old === undefined) delete process.env.AXE; else process.env.AXE = old; }
});

test("runAxe reports axe-failed when the scan can't run, never an empty list", async () => {
  const notLoaded = { addScriptTag: async () => {}, evaluate: async (fn) => { globalThis.window = {}; try { return await fn(); } finally { delete globalThis.window; } } };
  assert.equal((await runAxe(notLoaded, ""))[0].id, "axe-failed");
  const throws = { addScriptTag: async () => {}, evaluate: async () => { throw new Error("page closed"); } };
  const r = await runAxe(throws, "");
  assert.equal(r[0].id, "axe-failed");
  assert.match(r[0].sample[0], /page closed/);
});
