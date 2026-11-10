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
      if (args.includes("-c")) return "/var/lib/postgresql/zella-sec/data";
      assert.ok(args.includes("ON_ERROR_STOP=1"));
      return output;
    })(true, "admin@zella.test");
    assert.equal(result.includes("/businesses/fake-id"), Boolean(output));
  }
  await assert.rejects(seeds({ ZDB: "ztest" }, (cmd, args) => { if (args.includes("-c")) return "/var/lib/postgresql/zella-sec/data"; throw Error("query failed"); })(true), /query failed/);
});
test("without ZDB no database query runs", async () => {
  assert.ok((await seeds({}, () => assert.fail("unexpected query"))(true)).length);
});

test("isolated target validation rejects unsafe paths, ports and database names before psql", async () => {
  for (const env of [{ ZDB: "prod" }, { ZDB: "z" }, { ZDB: "ztest", ZPG_HOST: "localhost" },
    { ZDB: "ztest", ZPG_HOST: "/socket -h remote" }, { ZDB: "ztest", ZPG_PORT: "55433x" }]) {
    await assert.rejects(seeds(env, () => assert.fail("unexpected query"))(true), /invalid isolated/);
  }
});
test("verification refuses wrong clusters, network connections and failures", async () => {
  for (const output of ["", "/other/data"]) {
    let calls = 0;
    await assert.rejects(seeds({ ZDB: "ztest" }, () => { calls++; return output; })(true), /verification failed/);
    assert.equal(calls, 1);
  }
  await assert.rejects(seeds({ ZDB: "ztest" }, () => { throw Error("verification unavailable"); })(true), /verification unavailable/);
});
test("verification and seed queries clear inherited libpq routing settings", async () => {
  const keys = ["PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGHOST", "PGPORT", "PGDATABASE"];
  let calls = 0;
  await seeds({ ZDB: "ztest", ...Object.fromEntries(keys.map(k => [k, "unsafe"])) }, (cmd, args, options) => {
    calls++;
    for (const key of keys) assert.equal(options.env[key], undefined);
    assert.equal(args[args.indexOf("-h") + 1], "/var/lib/postgresql/zella-sec");
    return args.includes("-c") ? "/var/lib/postgresql/zella-sec/data" : "";
  })(true);
  assert.equal(calls, 2);
});

test("top-level failure prints only the first error line and closes the browser", async () => {
  const errors = [], logs = [];
  let closed = false;
  const process = { exitCode: 0 };
  await vm.runInNewContext(source.slice(source.lastIndexOf("(async () => {")), {
    chromium: { launch: async () => ({ close: async () => { closed = true; } }) },
    args: ["owner"], PERSONAS: { owner: "fake@zella.test" },
    sweep: async () => { throw Error("query failed\nprivate detail"); },
    console: { error: (s) => errors.push(s), log: (s) => logs.push(s) }, process,
  });
  assert.equal(closed, true);
  assert.equal(process.exitCode, 1);
  assert.deepEqual(logs, []);
  assert.deepEqual(errors, ["Glitch sweep failed; no success summary was produced.", "query failed"]);
});
