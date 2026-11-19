// PLT-08: find every audit action, platform alert kind and admin permission name the code writes or checks.
//
// The drift test (drift_test.mjs) compares what this finds with the one shared list,
// web/supabase/functions/_shared/catalog.json. Each finder takes a file's text and returns
// [{ name, line, prefix }]: `prefix` is true when the name is built at run time and only its start is known
// ('platform_admin_' || ..., `legal.${kind}`).
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

// a real file system path (a checkout path with spaces or other escaped characters works)
export const ROOT = fileURLToPath(new URL("../../", import.meta.url));

const lineAt = (src, i) => src.slice(0, i).split("\n").length;
// SQL literals, also when the SQL sits inside another string with doubled quotes (zella_patch_function, execute).
const SQL_LIT = /'+([a-z][a-z0-9_.]*)'+/g;
const NAME = /^[a-z][a-z0-9_]*(\.[a-z0-9_]+)?$/;

// SQL without its comments (-- to the end of the line, /* ... */), the same length and lines, so positions still
// match the file. Quoted text is kept: '--' inside a string is not a comment.
export function stripSqlComments(src) {
  let out = "", quote = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (quote) { out += c; if (c === "'") quote = false; continue; }
    if (c === "'") { quote = true; out += c; continue; }
    if (c === "-" && src[i + 1] === "-") { const nl = src.indexOf("\n", i); const end = nl < 0 ? src.length : nl; out += " ".repeat(end - i); i = end - 1; continue; }
    if (c === "/" && src[i + 1] === "*") { const e = src.indexOf("*/", i + 2); const stop = e < 0 ? src.length : e + 2; out += src.slice(i, stop).replace(/[^\n]/g, " "); i = stop - 1; continue; }
    out += c;
  }
  return out;
}

// Splits the comma separated list inside the bracket that opens at src[open]. Quotes and nested brackets are
// respected. Returns { items: [{ text, at }], end } where end is the index of the closing bracket.
export function splitGroup(src, open) {
  const items = [];
  let depth = 0, start = open + 1, quote = null;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (quote) {
      if (c === "\\" && quote !== "'") { i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === "'" || c === '"' || c === "`") { quote = c; continue; }
    if (c === "-" && src[i + 1] === "-") { const nl = src.indexOf("\n", i); i = nl < 0 ? src.length : nl; continue; }
    if (c === "(" || c === "[" || c === "{") { depth++; continue; }
    if (c === ")" || c === "]" || c === "}") {
      depth--;
      if (depth === 0) { items.push({ text: src.slice(start, i), at: start }); return { items, end: i }; }
      continue;
    }
    if (c === "," && depth === 1) { items.push({ text: src.slice(start, i), at: start }); start = i + 1; }
  }
  return { items, end: src.length };
}

// The names one SQL expression can produce: a literal, every branch of a case, a literal joined to a case
// ('automation.' || case ... end), or the known start of any other concatenation. Anything else (a parameter or a
// variable) comes back as { ident } for the caller to resolve.
export function sqlExprNames(text) {
  const t = text.replace(/--[^\n]*/g, " ").replace(/\s+/g, " ").trim().replace(/::\s*text$/i, "").trim();
  const lit = t.match(/^'+([a-z][a-z0-9_.]*)'+$/);
  if (lit) return [{ name: lit[1] }];
  // every then / else result of a case, read whole (up to the next when / else / end of that case): a literal, a
  // name to resolve, a literal joined to more ('attendance.' || new_status: its known start), null ("no audit row"),
  // or unresolved
  const branches = (c) => caseResults(c).map((v) => {
    const lit = v.match(/^'+([a-z0-9_.]*)'+$/);
    if (lit) return { name: lit[1] };
    if (/^null$/i.test(v)) return null;
    if (/^[a-z_][a-z0-9_]*$/i.test(v)) return { ident: v.toLowerCase() };
    const start = v.match(/^'+([a-z][a-z0-9_.]*)'+\s*\|\|/);
    if (start) return { name: start[1], prefix: true };
    return { name: v.slice(0, 60), unresolved: true };
  }).filter(Boolean);
  if (/^case\b.*\bend$/i.test(t)) return branches(t);
  const joined = t.match(/^'+([a-z][a-z0-9_.]*)'+\s*\|\|\s*\(?\s*(case\b.*\bend)\s*\)?$/i);
  if (joined && !/\|\|/.test(joined[2])) {
    return branches(joined[2]).map((b) => (b.name !== undefined && !b.unresolved ? { name: joined[1] + b.name } : { name: joined[1], prefix: true }));
  }
  if (/\|\|/.test(t)) {
    const m = t.match(/^'+([a-z][a-z0-9_.]*)'+\s*\|\|/);
    if (m) return [{ name: m[1], prefix: true }];
  }
  const id = t.match(/^([a-z_][a-z0-9_]*)$/i);
  if (id) return [{ ident: id[1].toLowerCase() }];
  return [{ name: t.slice(0, 60), unresolved: true }];
}

// The result expressions of a case ... end, each read up to the next when / else / end at the same depth (nested
// brackets, nested cases and quoted text are skipped over).
// a dollar quote's tag as PostgreSQL allows it ($$, $tag$, letters of any language, any length), at a given offset
const DOLLAR_TAG = /\$(?:[\p{L}_][\p{L}\p{N}_]*)?\$/uy;
export function caseResults(t) {
  const out = [];
  const word = /\b(case|when|then|else|end)\b/gi;
  let depth = 0, cases = 0, quote = false, start = -1, paren = 0;
  const lower = t.toLowerCase();
  let ident = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (quote) { if (c === "'") quote = false; continue; }
    if (ident) { if (c === '"') { if (t[i + 1] === '"') i++; else ident = false; } continue; }   // "end" as a name, "" inside
    // a dollar quoted string ($$...$$, $tag$...$tag$) is text up to its own closing tag, double quotes included
    if (c === "$" && !(i > 0 && /[\p{L}\p{N}_]/u.test(t[i - 1]))) {
      DOLLAR_TAG.lastIndex = i;
      const tag = DOLLAR_TAG.exec(t);
      if (tag) { const close = t.indexOf(tag[0], i + tag[0].length); i = close < 0 ? t.length : close + tag[0].length - 1; continue; }
    }
    if (c === "'") { quote = true; continue; }
    if (c === '"') { ident = true; continue; }
    if (c === "(") { paren++; continue; }
    if (c === ")") { paren--; continue; }
    word.lastIndex = i;
    const m = word.exec(lower);
    if (!m || m.index !== i || (i > 0 && /[a-z0-9_]/.test(lower[i - 1]))) continue;
    const w = m[1];
    if (w === "case") { cases++; if (cases === 1) depth = paren; i += 3; continue; }
    if (cases === 1 && paren === depth && (w === "when" || w === "else" || w === "end") && start >= 0) {
      out.push(t.slice(start, i).trim()); start = -1;
    }
    if (cases === 1 && paren === depth && (w === "then" || w === "else")) start = i + w.length;
    if (w === "end") { cases--; i += 2; continue; }
    i += w.length - 1;
  }
  return out;
}

// The function a position sits in: its name, parameter names and body text.
export function enclosingFunction(src, at) {
  const re = /create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*\(/gi;
  let last = null;
  for (const m of src.matchAll(re)) { if (m.index > at) break; last = m; }
  if (!last) return null;
  const g = splitGroup(src, last.index + last[0].length - 1);
  const params = g.items.map((p) => p.text.trim().split(/\s+/)[0].toLowerCase());
  re.lastIndex = 0;
  const next = [...src.matchAll(re)].find((m) => m.index > at);
  return { name: last[1].toLowerCase(), params, body: src.slice(g.end, next ? next.index : undefined) };
}

// What a variable in a function body is set to: v_x := ...; or declare v_x text := ...;
export function sqlAssignments(body, ident) {
  const out = [];
  const re = new RegExp(`\\b${ident}\\b(?:\\s+[a-z]+(?:\\(\\d+\\))?)?\\s*:=\\s*`, "gi");
  for (const m of body.matchAll(re)) {
    let depth = 0, quote = false, i = m.index + m[0].length;
    for (; i < body.length; i++) {
      const c = body[i];
      if (c === "'") quote = !quote;
      else if (!quote && c === "(") depth++;
      else if (!quote && c === ")") depth--;
      else if (!quote && depth === 0 && c === ";") break;
    }
    out.push(body.slice(m.index + m[0].length, i));
  }
  return out;
}

// Arguments passed at position idx in every call to fn (definitions, grants and comments are skipped).
export function sqlCallArgs(src, fn, idx) {
  const out = [];
  for (const m of src.matchAll(new RegExp(`\\b${fn}\\s*\\(`, "gi"))) {
    const before = src.slice(Math.max(0, m.index - 80), m.index);
    if (/(function|procedure|on|comment on function)\s+(public\.)?$/i.test(before)) continue;
    const g = splitGroup(src, m.index + m[0].length - 1);
    const item = g.items[idx];
    if (!item || /^\s*[a-z_]+\s+(text|uuid|jsonb|int|integer|boolean|timestamptz)\b/i.test(item.text) || /^\s*(text|uuid|jsonb)\s*$/i.test(item.text)) continue;
    out.push({ text: item.text, at: item.at });
  }
  return out;
}

// insert into [public.]audit_logs (..., action, ...) values (...)[, (...)] | select ...
export function sqlAuditActions(raw) {
  const src = stripSqlComments(raw);
  const out = [];
  for (const m of src.matchAll(/insert\s+into\s+(?:public\.)?audit_logs\s*\(/gi)) {
    const cols = splitGroup(src, m.index + m[0].length - 1);
    const idx = cols.items.findIndex((c) => c.text.trim().toLowerCase() === "action");
    if (idx < 0) continue;
    const rest = src.slice(cols.end + 1);
    const kw = rest.match(/^\s*(values|select)\b/i);
    if (!kw) continue;
    let pos = cols.end + 1 + kw[0].length;
    if (kw[1].toLowerCase() === "values") {
      // one or more tuples
      for (;;) {
        const open = src.indexOf("(", pos);
        if (open < 0 || src.slice(pos, open).trim() !== "") break;
        const g = splitGroup(src, open);
        const item = g.items[idx];
        if (item) for (const n of sqlExprNames(item.text)) out.push({ ...n, at: item.at, line: lineAt(src, item.at) });
        const after = src.slice(g.end + 1).match(/^\s*,\s*/);
        if (!after) break;
        pos = g.end + 1 + after[0].length;
      }
    } else {
      // select a, b, c from ... : split the select list at depth 0 until from / where / ; at the outer level (a
      // from or where inside brackets or quotes doesn't end it)
      const stop = outerStop(src, pos);
      const list = src.slice(pos, stop < 0 ? undefined : stop);
      const g = splitGroup(`(${list})`, 0);
      const item = g.items[idx];
      if (item) for (const n of sqlExprNames(item.text)) out.push({ ...n, at: pos + item.at - 1, line: lineAt(src, pos + item.at - 1) });
    }
  }
  return out;
}

// Where a select list ends: the first from / where / ; outside brackets and quoted text, or -1.
function outerStop(src, from) {
  let depth = 0, quote = false, ident = false;
  for (let i = from; i < src.length; i++) {
    const c = src[i];
    if (quote) { if (c === "'") quote = false; continue; }
    if (ident) { if (c === '"') { if (src[i + 1] === '"') i++; else ident = false; } continue; }   // a "from" column name
    if (c === "'") { quote = true; continue; }
    if (c === '"') { ident = true; continue; }
    if (c === "(") depth++;
    else if (c === ")") { if (depth === 0) return i; depth--; }
    else if (depth === 0) {
      if (c === ";") return i;
      if (/[fw]/i.test(c) && !/[a-z0-9_]/i.test(src[i - 1] ?? "") && /^(from|where)\b/i.test(src.slice(i, i + 6))) return i;
    }
  }
  return -1;
}

// zella_platform_alert('kind', ...) and insert into platform_alerts (kind, ...) values ('kind', ...)
export function sqlAlertKinds(raw) {
  const src = stripSqlComments(raw);
  const out = [];
  for (const m of src.matchAll(/zella_platform_alert\s*\(/gi)) {
    const g = splitGroup(src, m.index + m[0].length - 1);
    const first = g.items[0];
    if (!first) continue;
    // the function's own definition: (p_kind text, ...)
    if (/^\s*(p_kind\s+)?text\b/i.test(first.text) || /^\s*p_kind\b/i.test(first.text)) continue;
    for (const n of sqlExprNames(first.text)) out.push({ ...n, at: first.at, line: lineAt(src, first.at) });
  }
  for (const m of src.matchAll(/insert\s+into\s+(?:public\.)?platform_alerts\s*\(/gi)) {
    const cols = splitGroup(src, m.index + m[0].length - 1);
    const idx = cols.items.findIndex((c) => c.text.trim().toLowerCase() === "kind");
    const vals = src.slice(cols.end + 1).match(/^\s*values\s*\(/i);
    if (idx < 0 || !vals) continue;
    // one or more tuples
    let open = cols.end + vals[0].length;
    for (;;) {
      const g = splitGroup(src, open);
      const item = g.items[idx];
      if (item && !/^\s*p_kind\s*$/i.test(item.text)) for (const n of sqlExprNames(item.text)) out.push({ ...n, at: item.at, line: lineAt(src, item.at) });
      const next = src.slice(g.end + 1).match(/^\s*,\s*\(/);
      if (!next) break;
      open = g.end + next[0].length;
    }
  }
  return out;
}

// zella_admin_can('perm' ...) and rows put in platform_role_permissions ('role', 'perm').
export function sqlPermissions(raw) {
  const src = stripSqlComments(raw);
  const out = [];
  for (const m of src.matchAll(/zella_admin_can\s*\(\s*'+([a-z][a-z0-9_]*\.[a-z0-9_]+)'+/gi)) out.push({ name: m[1], line: lineAt(src, m.index) });
  for (const m of src.matchAll(/insert\s+into\s+(?:public\.)?platform_role_permissions\s*\([^)]*\)\s*values/gi)) {
    let pos = m.index + m[0].length;
    for (;;) {
      const open = src.indexOf("(", pos);
      if (open < 0 || src.slice(pos, open).trim() !== "") break;
      const g = splitGroup(src, open);
      for (const it of g.items) {
        const lit = it.text.trim().match(/^'([a-z][a-z0-9_]*\.[a-z0-9_]+)'$/);
        if (lit) out.push({ name: lit[1], line: lineAt(src, it.at) });
      }
      const after = src.slice(g.end + 1).match(/^\s*,\s*/);
      if (!after) break;
      pos = g.end + 1 + after[0].length;
    }
  }
  return out;
}

// Turns { ident } results into names: a local variable through its assignments, a parameter through every call to
// the function across all SQL files (zella_admin_audit('x', ...)). What can't be followed stays unresolved.
export function resolveSql(list, src, sqlFiles, depth = 0) {
  const out = [];
  for (const f of list) {
    if (!f.ident) { out.push(f); continue; }
    const fn = enclosingFunction(src, f.at);
    const pIdx = fn ? fn.params.indexOf(f.ident) : -1;
    let names = [];
    if (fn && pIdx >= 0 && depth < 2) {
      for (const file of sqlFiles) {
        for (const a of sqlCallArgs(file.src, fn.name, pIdx)) {
          names = names.concat(resolveSql(sqlExprNames(a.text).map((n) => ({ ...n, at: a.at, line: lineAt(file.src, a.at) })), file.src, sqlFiles, depth + 1)
            .map((n) => ({ ...n, via: `${file.rel}:${lineAt(file.src, a.at)}` })));
        }
      }
    } else if (fn) {
      // a variable set from another variable or parameter is followed too (depth limited, so a cycle stops)
      for (const e of sqlAssignments(fn.body, f.ident)) {
        const found = sqlExprNames(e);
        names = names.concat(depth < 3 ? resolveSql(found.map((n) => ({ ...n, at: f.at, line: f.line })), src, sqlFiles, depth + 1) : found.map((n) => (n.ident ? { name: n.ident, unresolved: true } : n)));
      }
    }
    if (names.length) for (const n of names) out.push({ ...n, line: f.line, at: f.at });
    else out.push({ name: f.ident, unresolved: true, line: f.line });
  }
  return out;
}

// TypeScript and JavaScript: strip comments, keeping line numbers.
export function stripJsComments(src) {
  let out = "", quote = null;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (quote) {
      out += c;
      if (c === "\\") { out += src[i + 1] ?? ""; i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === "/" && src[i + 1] === "/") { const nl = src.indexOf("\n", i); const end = nl < 0 ? src.length : nl; out += " ".repeat(end - i); i = end - 1; continue; }
    if (c === "/" && src[i + 1] === "*") { const end = src.indexOf("*/", i + 2); const stop = end < 0 ? src.length : end + 2; out += src.slice(i, stop).replace(/[^\n]/g, " "); i = stop - 1; continue; }
    if (c === "'" || c === '"' || c === "`") quote = c;
    out += c;
  }
  return out;
}

// The expression after `key:` up to the next comma or closing bracket at its own level.
function exprAfter(src, from) {
  let depth = 0, quote = null;
  for (let i = from; i < src.length; i++) {
    const c = src[i];
    if (quote) { if (c === "\\") { i++; continue; } if (c === quote) quote = null; continue; }
    if (c === "'" || c === '"' || c === "`") { quote = c; continue; }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) { if (depth === 0) return src.slice(from, i); depth--; }
    else if ((c === "," || c === ";") && depth === 0) return src.slice(from, i);
  }
  return src.slice(from);
}

// The string literals an expression can produce. A template literal gives its fixed start as a prefix.
export function jsExprNames(expr) {
  const out = [];
  for (const m of expr.matchAll(/(["'])([^"'\n]*)\1|`([^`]*)`/g)) {
    if (m[3] !== undefined) {
      const head = m[3].split("${")[0];
      if (m[3].includes("${")) { if (head) out.push({ name: head, prefix: true }); }
      else out.push({ name: m[3] });
    } else out.push(/^\s*\+/.test(expr.slice(m.index + m[0].length)) ? { name: m[2], prefix: true } : { name: m[2] });
  }
  return out;
}

// The value branches of an expression, with every string literal written as S: "a ? 'x' : y" gives ["S", "y"].
// A branch that doesn't start with a literal (a variable, a call) can't be checked.
// Takes off parentheses around the whole of an expression: "((a ? b : c))" is "a ? b : c".
function unwrap(t) {
  for (;;) {
    t = t.trim();
    if (!t.startsWith("(")) return t;
    let depth = 0, closes = -1;
    for (let i = 0; i < t.length; i++) {
      if (t[i] === "(") depth++;
      else if (t[i] === ")" && --depth === 0) { closes = i; break; }
    }
    if (closes !== t.length - 1) return t;
    t = t.slice(1, -1);
  }
}

export function jsValueBranches(expr) {
  const t = unwrap(expr.replace(/`[^`]*`|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, "S"));
  const parts = [], seps = [];
  let depth = 0, start = 0;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (depth === 0 && (c === "?" || c === ":") && t[i + 1] !== "." && t[i + 1] !== "?" && t[i - 1] !== "?") {
      parts.push(t.slice(start, i).trim()); seps.push(c); start = i + 1;
    }
  }
  parts.push(t.slice(start).trim());
  // a part followed by "?" is a condition; every other part is a value (its own parentheses taken off)
  return parts.filter((_, i) => seps[i] !== "?").map(unwrap);
}

// The source with every string literal's contents blanked (same length), so brackets inside strings don't count.
function maskStrings(src) {
  return src.replace(/`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, (q) => q[0] + " ".repeat(q.length - 2) + q[q.length - 1]);
}

// Whether `key:` at `at` is written where TypeScript expects a type: inside a parameter list, a type alias, an
// interface, a generic, or a type literal used as an annotation (`p: { ... }`, `const x: { ... }`, `): { ... }`).
// Inside an object literal (`= {`, `({`, `return {`, `key: {` in an object) it is a value.
export function inTypePosition(masked, at) {
  let depth = 0, open = -1;
  for (let i = at - 1; i >= 0; i--) {
    const c = masked[i];
    if (")]}".includes(c)) depth++;
    else if ("([{".includes(c)) { if (depth === 0) { open = i; break; } depth--; }
  }
  if (open < 0 || masked[open] === "[") return false;
  const before = masked.slice(0, open).replace(/\s+$/, "");
  if (masked[open] === "(") return !/\b(if|while|for|switch|catch)$/.test(before) && isParameterList(masked, open);
  if (/(\btype\s+[\w$]+(<[^>]*>)?\s*=|\binterface\s+[\w$]+(<[^>]*>)?(\s+extends\s+[^{]+)?|[<|&])$/.test(before)) return true;
  if (!before.endsWith(":")) return false;
  const key = before.slice(0, -1).replace(/\s+$/, "");
  if (key.endsWith(")")) return true; // a return type: "): {"
  if (/\b(const|let|var)\s+[\w$]+\??$/.test(key)) return true; // "const x: {"
  if (!/[\w$]\??$/.test(key)) return false;
  return inTypePosition(masked, key.search(/[\w$]+\??$/));
}

// A "(" opens a parameter list when its matching ")" is followed by "=>" or "{" (a function), or by ":" (a return type).
function isParameterList(masked, open) {
  let depth = 0;
  for (let i = open; i < masked.length; i++) {
    if (masked[i] === "(") depth++;
    else if (masked[i] === ")" && --depth === 0) return /^\s*(=>|\{|:)/.test(masked.slice(i + 1));
  }
  return false;
}

// Audit entries in the edge functions: every `action:` whose value is a dotted name (request actions such as
// "lookup" or "start" are not audit names; every audit name the functions write has a dot).
export function tsAuditActions(raw) {
  const src = stripJsComments(raw);
  const masked = maskStrings(src);
  const out = [];
  for (const m of src.matchAll(/(?:\baction|(["'])action\1)\s*:\s*/g)) {
    const expr = exprAfter(src, m.index + m[0].length);
    // a type, not a value: "action: string", or "action: RequestAction" where a type is written (a parameter, a type
    // alias, an interface, an annotation). In an object literal a PascalCase name is a value and stays unresolved.
    const typed = inTypePosition(masked, m.index);
    const isType = (b) => /^(string|null|undefined|number|boolean)\b/.test(b) || (typed && /^[A-Z][A-Za-z0-9_]*(<[^>]*>)?(\[\])?$/.test(b));
    const loose = jsValueBranches(expr).find((b) => !/^S\b/.test(b) && !isType(b));
    if (loose !== undefined) out.push({ name: expr.trim().replace(/\s+/g, " ").slice(0, 60), unresolved: true, line: lineAt(src, m.index) });
    for (const n of jsExprNames(expr)) {
      if (n.prefix ? /^[a-z][a-z0-9_]*\./.test(n.name) : /^[a-z][a-z0-9_]*\.[a-z0-9_]+$/.test(n.name)) out.push({ ...n, line: lineAt(src, m.index) });
    }
  }
  return out;
}

// Audit names the functions read back: .eq("action", "x"), .in("action", [...]) and "action.like.x%" filters.
export function tsAuditReads(raw) {
  const src = stripJsComments(raw);
  const out = [];
  const masked = maskStrings(src);
  for (const m of src.matchAll(/\.(eq|in)\(\s*["']action["']\s*,\s*/g)) {
    const names = jsExprNames(exprAfter(src, m.index + m[0].length));
    if (!names.length) continue;
    const table = queryTable(src, masked, m.index);
    if (table === null) { out.push({ name: `action filter at line ${lineAt(src, m.index)}`, unresolved: true, line: lineAt(src, m.index) }); continue; }
    if (table === "audit_logs") for (const n of names) out.push({ ...n, line: lineAt(src, m.index) });
  }
  for (const m of src.matchAll(/action\.like\.([a-z_.]*)%/g)) {
    // only a pattern inside the arguments of an .or(...) / .filter(...) call is a filter (a string anywhere else is not
    // a query); the query is that call's receiver
    // out through the enclosing brackets (an array, a .join(...) call) to the first call that is .or( or .filter(
    let callee = null, open = -1, from = m.index - 1;
    for (let level = 0; level < 8 && !callee; level++) {
      let d = 0; open = -1;
      for (let i = from; i >= 0; i--) {
        const c = masked[i];
        if (c === ";") break;
        if (c === ")" || c === "]" || c === "}") d++;
        else if (c === "(" || c === "[" || c === "{") { if (d === 0) { open = i; break; } d--; }
      }
      if (open < 0 || masked[open] === "{") break;
      if (masked[open] === "(") {
        // the method name before the bracket, past any spaces (comments are spaces here)
        let e = open - 1;
        while (e >= 0 && /\s/.test(masked[e])) e--;
        const hit = /\.(or|filter)$/.exec(masked.slice(Math.max(0, e - 7), e + 1));
        if (hit) callee = [masked.slice(e - hit[0].length + 1, open)];
      }
      from = open - 1;
    }
    if (!callee) continue;
    const call = open - callee[0].length;
    const table = queryTable(src, masked, call);
    if (table === null) out.push({ name: `action filter at line ${lineAt(src, m.index)}`, unresolved: true, line: lineAt(src, m.index) });
    else if (table === "audit_logs") out.push({ name: m[1], prefix: true, line: lineAt(src, m.index) });
  }
  return out;
}

// The table a query builder call at `at` belongs to: follows the call chain back to its start (admin.from("t")...)
// and, when the chain starts at a name, every assignment of that name before it (q = admin.from("t")..., q = q.eq(...)).
// Returns the table, or null when it can't be worked out (a parameter, a call result).
export function queryTable(src, masked, at, depth = 0) {
  if (depth > 5) return null;
  // walk back over the chain: .name(...) segments and the head before them
  let i = at;
  for (;;) {
    let j = i - 1;
    while (j >= 0 && /\s/.test(masked[j])) j--;
    if (masked[j] === ")") {
      let d = 0;
      for (; j >= 0; j--) { if (masked[j] === ")") d++; else if (masked[j] === "(") { d--; if (d === 0) break; } }
      j--;
      while (j >= 0 && /[\w$]/.test(masked[j])) j--;
      if (masked[j] === ".") { i = j; continue; }
      // a call with no receiver: the head is a function call, not a query
      return null;
    }
    while (j >= 0 && /[\w$]/.test(masked[j])) j--;
    const head = masked.slice(j + 1, i).trim();
    if (masked[j] === ".") { i = j; continue; }
    const chain = src.slice(j + 1, at);
    const from = chain.match(/\.from\(\s*["']([a-z_]+)["']\s*\)/);
    if (from) return from[1];
    if (!/^[A-Za-z_$][\w$]*$/.test(head)) return null;
    // the head is a name: its latest assignment before here decides
    // (not the assignment this chain is the right hand side of)
    // q = ... only: not state.q = ... or obj?.q = ... (a property, not this binding)
    const all = [...masked.slice(0, j + 1).matchAll(new RegExp(`(?:\\b(?:let|const|var)\\s+)?(?<![.\\w$])${head}\\s*=(?!=)\\s*`, "g"))]
      .filter((x) => x.index + x[0].length < j + 1);
    if (!all.length) return null;
    // The assignments that can reach this call: from the last one that always runs before it (in a block that also
    // holds the call, not after if / else / ? / && / ||), plus every conditional one after that.
    let lastSure = -1;
    all.forEach((a, n) => { if (!conditionalAt(masked, a.index, j)) lastSure = n; });
    const assigns = all.slice(Math.max(lastSure, 0));
    // audit_logs if any of them is, unknown if any can't be told, otherwise the table they name (every .from in the
    // right hand side counts: cond ? admin.from("a") : admin.from("b") can be either)
    const tables = assigns.flatMap((a) => {
      const rhsStart = a.index + a[0].length;
      const rhs = src.slice(rhsStart, rhsStart + exprAfter(src, rhsStart).length);
      const mrhs = maskStrings(rhs);
      if (/[?]|&&|\|\|/.test(mrhs)) {
        const split = armTables(rhs, mrhs, head, (at) => queryTable(src, masked, rhsStart + at, depth + 1));
        if (split) return split;
      }
      const froms = [...rhs.matchAll(/\.from\(\s*["']([a-z_]+)["']\s*\)/g)].map((f) => f[1]);
      if (froms.length) return froms.length === 1 ? froms : [null];
      // q = q.order(...): follow that q back in turn
      if (new RegExp(`^\\s*${head}\\s*\\.`).test(rhs)) return [queryTable(src, masked, rhsStart + rhs.indexOf("."), depth + 1)];
      return [null];
    });
    if (tables.includes("audit_logs")) return "audit_logs";
    if (tables.includes(null)) return null;
    return tables[tables.length - 1];
  }
}

// The tables a conditional right hand side can give: each arm of a ? b : c, or of a && b / a || b, read on its own;
// an arm with no .from(...) that isn't the name itself followed back is unknown (null).
function armTables(rhs, mrhs, head, follow) {
  // (cond ? a : b): read inside the brackets that wrap the whole right hand side
  for (;;) {
    const a = mrhs.search(/\S/), b = mrhs.length - 1 - [...mrhs].reverse().join("").search(/\S/);
    if (a < 0 || mrhs[a] !== "(" || mrhs[b] !== ")") break;
    let d = 0, closes = -1;
    for (let i = a; i <= b; i++) { if (mrhs[i] === "(") d++; else if (mrhs[i] === ")") { d--; if (d === 0) { closes = i; break; } } }
    if (closes !== b) break;
    const inner = (s) => " ".repeat(a + 1) + s.slice(a + 1, b) + " ".repeat(s.length - b);
    rhs = inner(rhs); mrhs = inner(mrhs);
  }
  const arms = [];
  let d = 0, q = -1, colon = -1, start = 0, tern = 0;
  for (let i = 0; i < mrhs.length; i++) {
    const c = mrhs[i];
    if ("([{".includes(c)) d++;
    else if (")]}".includes(c)) d--;
    // ?? and || and && join arms; a ? opens a conditional (not ?. ), and its : is the one at the same nesting of
    // conditionals (a ? b ? x : y : z pairs the inner ? with the first :)
    else if (d === 0 && q < 0 && (mrhs.startsWith("&&", i) || mrhs.startsWith("||", i) || mrhs.startsWith("??", i))) { arms.push([start, i]); start = i + 2; i++; }
    else if (d === 0 && mrhs.startsWith("??", i)) i++;   // inside an arm: both characters of ?? are one operator
    else if (d === 0 && c === "?" && mrhs[i + 1] !== "." && mrhs[i + 1] !== "?") { if (q < 0) q = i; else if (colon < 0) tern++; }
    else if (d === 0 && c === ":" && q >= 0 && colon < 0) { if (tern > 0) tern--; else colon = i; }
  }
  if (q >= 0 && colon > q) arms.push([q + 1, colon], [colon + 1, mrhs.length]);
  else arms.push([start, mrhs.length]);
  if (arms.length === 1) return null;   // nothing to split here
  return arms.flatMap(([a, b]) => {
    const arm = rhs.slice(a, b);
    // an arm that is itself a conditional (bracketed or not) is split the same way
    const pad = (s) => " ".repeat(a) + s.slice(a, b) + " ".repeat(rhs.length - b);
    const nested = /[?]|&&|\|\|/.test(mrhs.slice(a, b)) ? armTables(pad(rhs), pad(mrhs), head, follow) : null;
    if (nested) return nested;
    const froms = [...arm.matchAll(/\.from\(\s*["']([a-z_]+)["']\s*\)/g)].map((f) => f[1]);
    if (froms.length === 1) return froms;
    const lead = /^\s*/.exec(arm)[0].length;
    if (!froms.length && new RegExp(`^\\s*${head}\\s*\\.`).test(arm)) return [follow(a + arm.indexOf(".", lead))];
    return [null];
  });
}

// Whether an assignment at `at` may not run before a call at `call`: it sits in a block that closes before the call,
// or right after if (...) / else / ? / && / || without a block.
function conditionalAt(masked, at, call) {
  let d = 0;
  for (let i = at; i < call; i++) { if (masked[i] === "{") d++; else if (masked[i] === "}") { if (d === 0) return true; d--; } }
  let k = at - 1;
  while (k >= 0 && /\s/.test(masked[k])) k--;
  // if (x) (q = ...): past the brackets that open in front of the assignment
  while (k >= 0 && masked[k] === "(") { k--; while (k >= 0 && /\s/.test(masked[k])) k--; }
  const before = masked.slice(Math.max(0, k - 5), k + 1);
  if (/(?:else|[?:]|&&|\|\|)$/.test(before)) return true;
  if (masked[k] === ")") {   // if (...) / while (...) / for (...) q = ...
    let p = 0, s = k;
    for (; s >= 0; s--) { if (masked[s] === ")") p++; else if (masked[s] === "(") { p--; if (p === 0) break; } }
    if (/\b(?:if|while|for)\s*$/.test(masked.slice(Math.max(0, s - 8), s))) return true;
  }
  return false;
}

// Permission names: values of the PERMISSIONS maps, PERMISSION_CATALOG rows and the two owner only permissions.
export function tsPermissions(raw) {
  const src = stripJsComments(raw);
  const out = [];
  for (const m of src.matchAll(/\b[A-Z_]*PERMISSIONS?(?:_CATALOG)?\b[^=\n]*=\s*/g)) {
    const open = m.index + m[0].length;
    if (!"{[".includes(src[open])) continue;
    const g = splitGroup(src, open);
    for (const n of jsExprNames(src.slice(open, g.end))) {
      if (/^[a-z]+\.[a-z_]+$/.test(n.name)) out.push({ ...n, line: lineAt(src, open) });
    }
  }
  for (const m of src.matchAll(/["']((?:admins|roles)\.manage)["']/g)) out.push({ name: m[1], line: lineAt(src, m.index) });
  return out;
}

// n8n code nodes: p_kind given to zella_platform_alert directly or through an `alert` object.
export function n8nAlertKinds(raw) {
  const src = stripJsComments(raw);
  const out = [];
  const masked = maskStrings(src);
  for (const m of src.matchAll(/\bp_kind\s*:\s*(["'])([a-z][a-z0-9_]*)\1/g)) {
    // the object p_kind sits in, and what that object is given to: an alert: { ... } property, or the argument of a
    // zella_platform_alert call (never zella_resolve_platform_alerts), however long the fields before p_kind are
    let depth = 0, open = -1;
    for (let i = m.index - 1; i >= 0; i--) {
      const c = masked[i];
      if (c === "}" || c === ")" || c === "]") depth++;
      else if (c === "{" || c === "(" || c === "[") { if (depth === 0) { open = i; break; } depth--; }
    }
    if (open < 0 || masked[open] !== "{") continue;
    // what comes before the brace, past any spaces and comments (comments are spaces here): alert: or "alert":, or
    // "zella_platform_alert", as the first argument
    let k = open - 1;
    const back = () => { while (k >= 0 && /\s/.test(src[k])) k--; };
    back();
    const sep = src[k--];
    back();
    let word = "";
    if (src[k] === '"' || src[k] === "'") { const q = src[k]; const s = src.lastIndexOf(q, k - 1); word = s >= 0 ? q + src.slice(s + 1, k) + q : ""; }
    else { let s = k; while (s >= 0 && /[\w$]/.test(src[s])) s--; word = src.slice(s + 1, k + 1); }
    // the RPC name must be the first argument of a call: name( "zella_platform_alert", { ... } ), not an array item
    let callArg = false;
    if (sep === "," && /^["']zella_platform_alert["']$/.test(word)) {
      let s = src.lastIndexOf(word[0], k - 1) - 1;
      while (s >= 0 && /\s/.test(src[s])) s--;
      if (src[s] === "(") {
        s--; while (s >= 0 && /\s/.test(src[s])) s--;
        let w = s; while (w >= 0 && /[\w$]/.test(src[w])) w--;
        const callee = src.slice(w + 1, s + 1);
        // a name or a call result before the bracket is a call; return ( ... ), typeof ( ... ) and the like are not
        callArg = (/^[A-Za-z_$][\w$]*$/.test(callee) && !/^(?:return|typeof|void|await|yield|case|in|of|new|delete|throw|else|do)$/.test(callee)) || src[s] === ")";
      }
    }
    if ((sep === ":" && /^(?:alert|"alert"|'alert')$/.test(word)) || callArg) out.push({ name: m[2], line: lineAt(src, m.index) });
  }
  return out;
}

// Edge functions: p_kind given to zella_platform_alert through admin.rpc("zella_platform_alert", { p_kind: "x", ... }).
export function tsAlertKinds(raw) {
  const src = stripJsComments(raw);
  const out = [];
  for (const m of src.matchAll(/zella_platform_alert["']\s*,\s*\{[^}]*?\bp_kind\s*:\s*["']([a-z][a-z0-9_]*)["']/g)) {
    out.push({ name: m[1], line: lineAt(src, m.index) });
  }
  return out;
}

// The web app: permission names it checks (can("x"), permission: "x", perm: "x", need: "x").
export function webPermissions(raw) {
  const src = stripJsComments(raw);
  const out = [];
  for (const m of src.matchAll(/\b(?:can|hasPermission|allowed)\(\s*["']([a-z]+\.[a-z_]+)["']/g)) out.push({ name: m[1], line: lineAt(src, m.index) });
  for (const m of src.matchAll(/\b(?:permission|perm|need|requires)\s*:\s*["']([a-z]+\.[a-z_]+)["']/g)) out.push({ name: m[1], line: lineAt(src, m.index) });
  return out;
}

export function walk(dir, test) {
  let out = [];
  for (const n of readdirSync(dir)) {
    if (n === "node_modules" || n === "dist" || n.startsWith(".")) continue;
    const p = join(dir, n);
    if (statSync(p).isDirectory()) out = out.concat(walk(p, test));
    else if (test(n, p)) out.push(p);
  }
  return out;
}

// Every place a name is written or checked, as { kind, name, prefix, unresolved, where }.
export function inventory(root = ROOT) {
  const found = [];
  const add = (kind, file, list) => {
    for (const f of list) found.push({ kind, ...f, where: `${relative(root, file)}:${f.line}` });
  };
  const sqlFiles = walk(join(root, "sql"), (n) => n.endsWith(".sql")).map((f) => ({ f, rel: relative(root, f), src: stripSqlComments(readFileSync(f, "utf8")) }));
  for (const { f, src } of sqlFiles) {
    add("audit", f, resolveSql(sqlAuditActions(src), src, sqlFiles));
    add("alert", f, resolveSql(sqlAlertKinds(src), src, sqlFiles));
    add("permission", f, sqlPermissions(src));
  }
  const fnDir = join(root, "web/supabase/functions");
  for (const f of walk(fnDir, (n) => /\.(ts|js)$/.test(n) && !/_test\.ts$|\.test\./.test(n))) {
    const src = readFileSync(f, "utf8");
    add("audit", f, tsAuditActions(src));
    add("audit_read", f, tsAuditReads(src));
    add("permission", f, tsPermissions(src));
    add("alert", f, tsAlertKinds(src));
  }
  for (const f of walk(join(root, "n8n/src"), (n) => n.endsWith(".js"))) add("alert", f, n8nAlertKinds(readFileSync(f, "utf8")));
  for (const f of walk(join(root, "web/src"), (n) => /\.(jsx?|tsx?)$/.test(n))) add("permission", f, webPermissions(readFileSync(f, "utf8")));
  return found;
}

export const isName = (s) => NAME.test(s);
export { SQL_LIT };
