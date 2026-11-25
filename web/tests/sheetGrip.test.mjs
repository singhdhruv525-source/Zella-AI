// Every dialog that becomes a bottom sheet on a phone (navigation/BottomSheet.jsx useSheetEnhancer targets
// .bp-panel and .owner-modal dialogs) carries its own drag strip (SheetGrip) as its first child, so the enhancer
// never has to add markup to elements React owns.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const SRC = new URL("../src", import.meta.url).pathname;
const files = (dir) => readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  return statSync(p).isDirectory() ? files(p) : /\.jsx$/.test(n) ? [p] : [];
});

test("each sheet dialog in the app has a drag strip as its first child", () => {
  const found = [];
  for (const f of files(SRC)) {
    const lines = readFileSync(f, "utf8").split("\n");
    lines.forEach((line, i) => {
      const dialog = /role="dialog"/.test(line) && /className=\{?[`"][^`"]*\b(owner-modal|bp-panel)\b(?![-\w])/.test(line);
      if (!dialog) return;
      found.push(`${f.slice(SRC.length + 1)}:${i + 1}`);
      assert.match(lines[i + 1] ?? "", /^\s*<SheetGrip \/>\s*$/, `${f.slice(SRC.length + 1)}:${i + 1} has no SheetGrip as its first child`);
    });
  }
  assert.equal(found.length, 17, `sheet dialogs found: ${found.join(", ")}`);
});
