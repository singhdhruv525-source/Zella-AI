const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(__dirname + "/glitch-sweep.cjs", "utf8");
const seedSource = source.slice(source.indexOf("const ADMIN_PAGES"), source.indexOf("async function sweep"));
function seeds(env, exec) {
  return vm.runInNewContext(seedSource + "; seeds", {
    process: { env }, require: () => ({ execFileSync: exec }),
  });
}
test("seed queries preserve successful and empty results and stop on SQL errors", async () => {
  for (const output of ["/businesses/fake-id\n", ""]) {
    const result = await seeds({ ZDB: "ztest" }, (cmd, args) => {
      assert.equal(cmd, "psql");
      assert.ok(args.includes("ON_ERROR_STOP=1"));
      return output;
    })(true, "admin@zella.test");
    assert.equal(result.includes("/businesses/fake-id"), Boolean(output));
  }
  await assert.rejects(seeds({ ZDB: "ztest" }, () => { throw Error("query failed"); })(true), /query failed/);
});
test("without ZDB no database query runs", async () => {
  assert.ok((await seeds({}, () => assert.fail("unexpected query"))(true)).length);
});
