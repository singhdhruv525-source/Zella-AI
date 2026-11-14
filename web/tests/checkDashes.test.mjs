// The writing check (scripts/check-dashes.mjs) finds hyphens in text people read, including lowercase phrases held in
// variables, and leaves code alone (class lists, object keys, file names).
//   cd web && node --test tests/checkDashes.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const SCRIPT = new URL("../scripts/check-dashes.mjs", import.meta.url).pathname;
function check(source) {
  const dir = mkdtempSync(join(tmpdir(), "check-dashes-"));
  try {
    writeFileSync(join(dir, "Sample.jsx"), source);
    const r = spawnSync(process.execPath, [SCRIPT, "--root", dir, "--list"], { encoding: "utf8" });
    return { code: r.status, out: r.stdout };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("a lowercase caption rendered through a variable is found", () => {
  const r = check('const caption = "please follow-up now";\nexport const C = () => <p>{caption}</p>;\n');
  assert.equal(r.code, 1);
  assert.match(r.out, /please follow-up now/);
});

test("JSX text, labels and long dashes are found", () => {
  assert.equal(check("export const A = () => <p>Book a check-in</p>;\n").code, 1);
  assert.equal(check('export const B = () => <input placeholder="e-mail" />;\n').code, 1);
  assert.equal(check('export const D = () => <p>{"Saved — thanks"}</p>;\n').code, 1);
});

test("code is not text: class lists, object keys, file names", () => {
  const r = check([
    'export const A = ({ on }) => <button className={on ? "ba-btn ba-btn-primary" : "ba-btn"}>Save</button>;',
    'const ERR = { "row-level security": "Your role can\'t change this." };',
    'const note = "See the guide in n8n/GO-LIVE.md for details";',
    "export default ERR;", "",
  ].join("\n"));
  assert.equal(r.code, 0, r.out);
});
