#!/usr/bin/env node
// Zella Voice writing rule: no dashes or hyphens in any text people read (docs/DESIGN_SYSTEM.md, "Writing").
// Checks the app's source for:
//   1. long dashes (U+2014, U+2013) anywhere outside comments: these are only ever text;
//   2. hyphenated words in JSX text and in quoted strings that read as words people see (they contain a space,
//      or are a known label prop such as title, label, placeholder, aria-label).
// Code is not text: class names, CSS, imports, URLs, routes, keys, dates and ids are skipped.
// Usage: node scripts/check-dashes.mjs [--list]   (exit 1 when anything is found)
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const rootArg = process.argv.indexOf("--root");
const ROOT = rootArg > 0 ? process.argv[rootArg + 1] : new URL("../src", import.meta.url).pathname;
const LONG = /[—–]/;
const WORD_HYPHEN = /[A-Za-z]-[A-Za-z]/;
// a quoted string that is code, not words: class lists, css, paths, urls, keys, mime types, dates, regexes
const CODE_STRING = /^(?:[a-z0-9_.:/#@?=&%-]+|[a-z][a-z0-9-]*(?:\s+[a-z][a-z0-9-]*)*|https?:\/\/\S+|\S+\/\S+|--[\w-]+|var\(.*\)|[\w-]+\s*:\s*.*;?)$/;
// code that happens to sit in a quoted string: locale tags, CSS (including inline styles in email HTML), file names,
// domains, HTTP header names
const NOT_WORDS = /\ben-US\b|var\(--|\dpx solid|^\s*\.[a-z][\w-]*\s*,|\.(json|csv|pdf|png|md)\b|[a-z0-9-]+\.(com|io|dev|app)\b|\bX-[A-Z][\w-]+|^Content-(Type|Range|Length)$|\b(font|text|line|letter|border|max|min|margin|padding|background)-[a-z-]+\s*:|\b[a-z]+:[^\s;]*;/;
// What is left of a string once the code in it is taken out; only that is checked for hyphens. Template placeholders
// become one letter, then every word that is code (a header name, file name, domain, CSS class or declaration) is
// dropped, so "Follow-up requires X-Request-Id" is still caught for "Follow-up".
const isCode = (t) => NOT_WORDS.test(t) || /^\.[a-z][\w-]*,?$/.test(t);
const wordsOnly = (s) => s.replace(/\$\{[^}]*\}/g, "X").replace(/\d+px solid(?=\s|$|[;,"')])/g, " ").split(/\s+/).filter((t) => !isCode(t)).join(" ");
const LABEL_PROPS = /\b(title|label|placeholder|aria-label|alt|description|hint|help|message|text|heading|subtitle|empty|cta|button|confirmLabel|cancelLabel)\s*[:=]\s*$/;

function files(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) return files(p);
    return /\.(jsx?|tsx?)$/.test(n) && !/\.test\.|_test\./.test(n) ? [p] : [];
  });
}

// strip comments but keep line numbers
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " ")).replace(/(^|[^:"'`\\])\/\/[^\n]*/g, "$1");
}

const found = [];
// the email catalogue lives with the edge functions; its wording is text people read too
const EXTRA = rootArg > 0 ? [] : [new URL("../supabase/functions/_shared/businessEmails.js", import.meta.url).pathname];
for (const f of [...files(ROOT), ...EXTRA]) {
  const lines = stripComments(readFileSync(f, "utf8")).split("\n");
  lines.forEach((line, i) => {
    const where = `${f.startsWith(ROOT) ? relative(ROOT, f) : f.slice(f.indexOf("supabase/"))}:${i + 1}`;
    if (LONG.test(line)) { found.push([where, "long dash", line.trim()]); return; }
    // JSX text between tags
    for (const m of line.matchAll(/>([^<>{}]*[A-Za-z][^<>{}]*)</g)) {
      if (WORD_HYPHEN.test(wordsOnly(m[1])) && !/=>/.test(m[1])) found.push([where, "hyphen in text", m[1].trim()]);
    }
    // quoted strings
    for (const m of line.matchAll(/(["'`])((?:\\.|(?!\1).)*)\1/g)) {
      const s = m[2], before = line.slice(0, m.index);
      if (!WORD_HYPHEN.test(s) || /\$\{/.test(s) && !/\s/.test(s)) continue;
      if (/\b(className|class|style|href|to|src|key|id|type|name|path|route|rel|role|variant|kind|tone|icon|slug|status|action|mode)\s*[:=]\s*\{?\s*$/.test(before)) continue;
      if (/\bclassName=\{[^}]*$/.test(before)) continue;                       // inside a className={...} expression
      if (/[{,]\s*$/.test(before) && /^\s*:/.test(line.slice(m.index + m[0].length))) continue;   // an object key: { "row-level security": ... }
      if (/\b(import|from|require|querySelector|getElementById|classList|addEventListener|matchMedia|rpc|from\(|select|eq|order|in|channel|on)\s*\(?\s*$/.test(before)) continue;
      const isLabel = LABEL_PROPS.test(before);
      // words people read: a phrase, or a capitalised label such as "Follow-up" in a list of choices
      const reads = (/\s/.test(s.trim()) && /[A-Za-z]{2,}\s+[A-Za-z]/.test(s)) || /^[A-Z][a-z]+(-[A-Za-z]+)+$/.test(s.trim());
      if (!isLabel && !reads) continue;
      // a single token that looks like code (a class, key or path); a phrase people read is never exempt here
      if (CODE_STRING.test(s) && !isLabel && !/\s/.test(s.trim())) continue;
      if (!WORD_HYPHEN.test(wordsOnly(s))) continue;
      found.push([where, "hyphen in text", s]);
    }
  });
}

if (process.argv.includes("--list")) for (const [w, k, t] of found) console.log(`${w}  ${k}: ${t.slice(0, 140)}`);
const byKind = found.reduce((a, [, k]) => ((a[k] = (a[k] ?? 0) + 1), a), {});
console.log(`check-dashes: ${found.length} found`, JSON.stringify(byKind));
process.exit(found.length ? 1 : 0);
