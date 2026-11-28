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

test("code inside a sentence is taken out, the rest is still checked", () => {
  const r = check('export const title = "Follow-up requires X-Request-Id";\nexport const A = () => <p>{title}</p>;\n');
  assert.equal(r.code, 1);
  assert.match(r.out, /Follow-up requires/);
  assert.equal(check('export const t = "Send the X-Request-Id header";\n').code, 0);
  const css = check("export const A = () => <p>Follow-up reminders use a 1px solid border</p>;\n");
  assert.equal(css.code, 1);
  assert.match(css.out, /Follow-up reminders/);
  assert.equal(check("export const A = () => <p>A 1px solid-state sensor</p>;\n").code, 1);
});

test("JSX text, labels and long dashes are found", () => {
  assert.equal(check("export const A = () => <p>Book a check-in</p>;\n").code, 1);
  assert.equal(check('export const B = () => <input placeholder="e-mail" />;\n').code, 1);
  assert.equal(check('export const D = () => <p>{"Saved — thanks"}</p>;\n').code, 1);
});

test("a number before the hyphen is found: 6-digit, 5-minute, 12-hour", () => {
  const jsx = check("export const A = () => <p>Enter the 6-digit code.</p>;\n");
  assert.equal(jsx.code, 1);
  assert.match(jsx.out, /6-digit/);
  const str = check('export const hint = "Times start on a 5-minute mark";\n');
  assert.equal(str.code, 1);
  assert.match(str.out, /5-minute/);
  const label = check('export const A = () => <option label="12-hour" />;\n');
  assert.equal(label.code, 1);
  assert.match(label.out, /12-hour/);
  // a label prop given as an expression: title={`Auto-reload: ${name}`}
  const expr = check("export const A = ({ n }) => <Card title={`Auto-reload: ${n}`} />;\n");
  assert.equal(expr.code, 1);
  assert.match(expr.out, /Auto-reload/);
  // dates, phone numbers and ids are digits on both sides, and stay code
  assert.equal(check('export const d = "2026-11-27";\nexport const p = "Call (555) 010 0200 on 2026-11-27";\n').code, 0);
});

test("JSX text on a line of its own is found", () => {
  const r = check([
    "export const A = () => (",
    "  <p className=\"note\">",
    "    Showing them here needs a server-side token.",
    "  </p>",
    ");", "",
  ].join("\n"));
  assert.equal(r.code, 1);
  assert.match(r.out, /Sample\.jsx:3 {2}hyphen in text: Showing them here needs a server-side token\./);
  // text next to an expression is checked: "{n} follow-ups sent", "couldn't run{reason}"
  const expr = check("export const E = ({ n, r }) => <p><small>{n} follow-ups sent</small> The follow-up couldn't run{r}.</p>;\n");
  assert.equal(expr.code, 1);
  assert.equal((expr.out.match(/ {2}hyphen in text:/g) ?? []).length, 2, expr.out);
  // the text after an inline tag on the same line is checked too, once
  const mixed = check([
    "export const B = () => (",
    "  <p>",
    "    Use <strong>Save</strong> to keep a 6-digit code.",
    "  </p>",
    ");", "",
  ].join("\n"));
  assert.equal(mixed.code, 1);
  assert.equal((mixed.out.match(/ {2}hyphen in text:/g) ?? []).length, 1);
  // a second line of the same paragraph is still text
  const two = check("export const C = () => (\n  <p>\n    First line of words.\n    Then a follow-up line.\n  </p>\n);\n");
  assert.equal(two.code, 1);
  assert.match(two.out, /Sample\.jsx:4/);
});

test("a labelled sentence on a line of its own is text, and an object property is still code", () => {
  const label = check("export const L = () => (\n  <p>\n    Note: Enter a 6-digit code.\n  </p>\n);\n");
  assert.equal(label.code, 1);
  assert.match(label.out, /Sample\.jsx:3 {2}hyphen in text: Note: Enter a 6-digit code\./);
  const props = check([
    "export const o = {",
    "  className: \"pay-card\",",
    "  kind: \"one-off\",",
    "  size: compact,",
    "  view: x ? \"side-by-side\" : y,",
    "};", "",
  ].join("\n"));
  assert.equal(props.code, 0, props.out);
});

test("a > on its own line, after props spread over lines, opens the text", () => {
  const r = check([
    "export const A = ({ on }) => (",
    "  <p",
    "    className=\"note\"",
    "    aria-live=\"polite\"",
    "  >",
    "    Showing them needs a server-side token.",
    "  </p>",
    ");", "",
  ].join("\n"));
  assert.equal(r.code, 1);
  assert.match(r.out, /Sample\.jsx:6 {2}hyphen in text: Showing them needs a server-side token\./);
});

test("an opening tag with text after it on the same line keeps the text going onto the next lines", () => {
  const r = check([
    "export const A = () => (",
    "  <p className=\"note\">Calls go to the",
    "    on-call person after hours.",
    "  </p>",
    ");", "",
  ].join("\n"));
  assert.equal(r.code, 1);
  assert.match(r.out, /Sample\.jsx:3 {2}hyphen in text: on-call person after hours\./);
  // the words on the tag's own line are checked too
  const same = check(["export const B = () => (", "  <p>A follow-up note", "    and more.", "  </p>", ");", ""].join("\n"));
  assert.equal(same.code, 1);
  assert.match(same.out, /Sample\.jsx:2 {2}hyphen in text: A follow-up note/);
  // a tag left open at the end of the line (props follow) is not text
  assert.equal(check(["export const C = () => (", "  <Focus><div", "    className=\"x-y\"", "  >", "  </div></Focus>", ");", ""].join("\n")).code, 0);
});

test("a comparison ending in > opens no text; a > that closes props spread over lines still does", () => {
  const cmp = check([
    "export function big(first, pass, limit) {",
    "  const more = limit >",
    "    first-pass",
    "  return more;",
    "}", "",
  ].join("\n"));
  assert.equal(cmp.code, 0, cmp.out);
  const props = check(["export const A = () => (", "  <Card", "    title=\"x\"", "  >", "    Uses a server-side token.", "  </Card>", ");", ""].join("\n"));
  assert.equal(props.code, 1);
  assert.match(props.out, /Sample\.jsx:5/);
});

test("text after an expression is only read on JSX lines, not in plain code", () => {
  // object and call suffixes after a "}" in plain JS are code
  const code = check([
    "const opts = { a: 1 } as-is { b: 2 };",
    "function f() { return 1 } fall-back { x(); }", "",
  ].join("\n"));
  assert.equal(code.code, 0, code.out);
  // inside JSX it is wording
  const jsx = check("export const A = ({ n }) => <p>{n} follow-ups sent</p>;\n");
  assert.equal(jsx.code, 1);
  assert.match(jsx.out, /follow-ups sent/);
});

test("a line that starts with an expression or a child element is checked after it", () => {
  const lines = (body) => check(["export const A = ({ name }) => (", "  <p>", ...body.map((l) => `    ${l}`), "  </p>", ");", ""].join("\n"));
  const expr = lines(["{name} has a follow-up due."]);
  assert.equal(expr.code, 1);
  assert.match(expr.out, /Sample\.jsx:3 {2}hyphen in text: has a follow-up due\./);
  const tag = lines(["<strong>Save</strong> keeps a 6-digit code."]);
  assert.equal(tag.code, 1);
  assert.match(tag.out, /Sample\.jsx:3 {2}hyphen in text: keeps a 6-digit code\./);
  const closing = lines(["Open <strong>", "Settings", "</strong> for the sign-in options."]);
  assert.equal(closing.code, 1);
  assert.match(closing.out, /Sample\.jsx:5 {2}hyphen in text: for the sign-in options\./);
});

test("an expression inside the text doesn't end it: the next line is still checked", () => {
  const r = check(["export const A = ({ name }) => (", "  <p>", "    Hello", "    {name}", "    and welcome to the check-in desk.", "  </p>", ");", ""].join("\n"));
  assert.equal(r.code, 1);
  assert.match(r.out, /Sample\.jsx:5 {2}hyphen in text: and welcome to the check-in desk\./);
  // a closing tag on its own still ends the text
  assert.equal(check(["export const B = (", "  <div>", "    <p>Hi</p>", "  </div>", ");", "const css = \"x-y\";", ""].join("\n")).code, 0);
});

test("a nested element's closing tag keeps the parent's text going; the parent's closing tag ends it", () => {
  const r = check([
    "export const A = () => (",
    "  <section>",
    "    <strong>",
    "      Title",
    "    </strong>",
    "    Text with a follow-up step.",
    "  </section>",
    ");",
    "const kind = { a: 1 };",
    "export const B = () => <div>{kind.a}</div>;", "",
  ].join("\n"));
  assert.equal(r.code, 1);
  assert.match(r.out, /Sample\.jsx:6 {2}hyphen in text: Text with a follow-up step\./);
  // after </section> the text has ended: a plain line of code that follows isn't read as text
  const after = check(["export const C = () => (", "  <section>", "    <strong>", "      Title", "    </strong>", "  </section>", ");",
    "hide-me", ""].join("\n"));
  assert.equal(after.code, 0, after.out);
});

test("control flow after a closing brace is code, but text after an expression is still checked", () => {
  const flow = check([
    "export function f(a, b) {",
    "  if (a) { go(); } else if (b-c) { stop(); }",
    "  try { go(); } catch (e-x) { stop(); }",
    "}", "",
  ].join("\n"));
  assert.equal(flow.code, 0, flow.out);
  const more = check([
    "export function g(a) {",
    "  if (a) { go(); } else { stop-it(); }",
    "  for (const x of a) { y(); } while (z-y) { w(); }",
    "  try { go(); } finally { stop(); }",
    "}", "",
  ].join("\n"));
  assert.equal(more.code, 0, more.out);
  // a word like "for" or "if" that starts visible text is still text
  const words = check("export const B = ({ n, m }) => <p>{n} for follow-up calls{m} if check-in is late</p>;\n");
  assert.equal(words.code, 1);
  assert.match(words.out, /for follow-up calls/);
  assert.match(words.out, /if check-in is late/);
  const text = check("export const A = ({ n }) => <p>{n} follow-ups sent</p>;\n");
  assert.equal(text.code, 1);
  assert.match(text.out, /follow-ups sent/);
});

test("code after a tag is not JSX text: expressions, props, arrow functions, statements", () => {
  const r = check([
    "export function A({ items, on }) {",
    "  const x = (",
    "    <ul>",
    "      {items.map((it) => <li key={it.id}>{it.name}</li>)}",
    "    </ul>",
    "  );",
    "  return (",
    "    <div>",
    "      <Button",
    "        aria-pressed={on}",
    "        data-test-id=\"save-row\"",
    "      >",
    "        Save",
    "      </Button>",
    "      {on && x}",
    "    </div>",
    "  );",
    "}",
    "const row = (v) => v > 0 ? \"x-y\" : \"y-z\";",
    "export const C = () => <i>{row(1)}</i>;", "",
  ].join("\n"));
  assert.equal(r.code, 0, r.out);
});

test("code is not text: class lists, object keys, file names", () => {
  const r = check([
    'export const A = ({ on }) => <button className={on ? "ba-btn ba-btn-primary" : "ba-btn"}>Save</button>;',
    'const ERR = { "row-level security": "Your role can\'t change this." };',
    'const note = "See the guide in n8n/GO-LIVE.md for details";',
    'const row = `<tr><td style="padding:6px 0;font-size:14px;text-align:right">${v}</td></tr>`;',
    "export default ERR;", "",
  ].join("\n"));
  assert.equal(r.code, 0, r.out);
});

test("a fragment holds text, and an entity is part of the text", () => {
  const frag = check("export const A = () => (\n  <>\n    Enter a 6-digit code.\n  </>\n);\n");
  assert.equal(frag.code, 1);
  assert.match(frag.out, /Sample\.jsx:3 {2}hyphen in text: Enter a 6-digit code\./);
  const entity = check("export const B = ({ n }) => <p>{n} 6-digit codes&nbsp;ready</p>;\n");
  assert.equal(entity.code, 1);
  assert.match(entity.out, /6-digit codes/);
  const multi = check("export const C = ({ n }) => (\n  <p>\n    {n} 6-digit codes&nbsp;ready\n  </p>\n);\n");
  assert.equal(multi.code, 1);
  assert.match(multi.out, /Sample\.jsx:3 /);
  const clean = check("export const D = () => (\n  <>\n    <p>Save&nbsp;changes</p>\n  </>\n);\n");
  assert.equal(clean.code, 0, clean.out);
});

test("an expression left open after a tag is code, and a tag with a callback still holds text", () => {
  const expr = check("export const B = ({ follow, up }) => (\n  <p>{\n    follow-up\n  }</p>\n);\n");
  assert.equal(expr.code, 0, expr.out);
  const nested = check("export const C = ({ a, b }) => (\n  <p>\n    Total:{\n      a-b\n    }\n  </p>\n);\n");
  assert.equal(nested.code, 0, nested.out);
  const callback = check("export const A = ({ save }) => (\n  <button onClick={() => save()}>\n    Send a follow-up.\n  </button>\n);\n");
  assert.equal(callback.code, 1);
  assert.match(callback.out, /Sample\.jsx:3 {2}hyphen in text: Send a follow-up\./);
  const after = check("export const D = ({ n }) => (\n  <p>{\n    n\n  }\n    A follow-up line.\n  </p>\n);\n");
  assert.equal(after.code, 1);
  assert.match(after.out, /A follow-up line/);
});

test("an element nested in an open expression holds text again", () => {
  const nested = check("export const A = ({ ready }) => (\n  <div>{\n    ready && (\n      <p>\n        Send a follow-up.\n      </p>\n    )\n  }</div>\n);\n");
  assert.equal(nested.code, 1);
  assert.match(nested.out, /Sample\.jsx:5 {2}hyphen in text: Send a follow-up\./);
  const maths = check("export const B = ({ a, b, ok }) => (\n  <div>{\n    ok && (\n      <p>{a}</p>\n    )\n  }{\n    a-b\n  }</div>\n);\n");
  assert.equal(maths.code, 0, maths.out);
});
