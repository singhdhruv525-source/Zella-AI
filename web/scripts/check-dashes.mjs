#!/usr/bin/env node
// Zella Voice writing rule: no dashes or hyphens in any text people read (docs/DESIGN_SYSTEM.md, "Writing").
// Checks the app's source for:
//   1. long dashes (U+2014, U+2013) anywhere outside comments: these are only ever text;
//   2. hyphenated words in JSX text and in quoted strings that read as words people see (they contain a space,
//      or are a known label prop such as title, label, placeholder, aria-label). A hyphen counts after a letter or a
//      number ("follow-up", "6-digit"). JSX text is checked whether it sits between tags on one line or on lines of
//      its own inside an element.
// Code is not text: class names, CSS, imports, URLs, routes, keys, dates and ids are skipped.
// Usage: node scripts/check-dashes.mjs [--list]   (exit 1 when anything is found)
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const rootArg = process.argv.indexOf("--root");
const ROOT = rootArg > 0 ? process.argv[rootArg + 1] : new URL("../src", import.meta.url).pathname;
const LONG = /[—–]/;
const WORD_HYPHEN = /[A-Za-z0-9]-[A-Za-z]/;
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
const LABEL_PROPS = /\b(title|label|placeholder|aria-label|alt|description|hint|help|message|text|heading|subtitle|empty|cta|button|confirmLabel|cancelLabel)\s*[:=]\s*\{?\s*$/;

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

// JSX text on a line of its own, inside an element that spans lines:
//   <p>
//     Uses a server-side token.
//   </p>
// A line is text when it follows an opening tag (a line ending in ">", including a ">" on its own after props spread
// over lines, but not "=>" or "/>") or more such text, and reads as words: it doesn't start a statement and holds no
// code punctuation. A line inside the text that starts with a whole expression or child element ("{name} has
// arrived", "<strong>Save</strong> keeps a copy", "</strong> and more") keeps the text going, and the words after its
// last tag or brace are checked. What sits inside tags or braces on the line is taken out before it is checked.
const JS_LINE = /^(?:[<{})\]?:&|+*/.,;]|return\b|const\b|let\b|var\b|if\b|else\b|import\b|export\b|function\b|case\b|default\b)|=>|[;=]\s*$|&&|\|\||\b[\w.]+\(|^\w+:\s|[=!]==/;
// control flow after a closing brace: "} else {", "} else if (x) {", "} catch (e) {", "} while (x)". Only the keyword
// with its syntax counts ("if (", "else" right before "{"), so "} for follow-up calls" is still read as text.
const JS_FLOW = /^\s*(?:else\s*$|else\s+if\s*\(|(?:if|for|while|switch|catch)\s*\(|(?:try|finally|do)\s*$|return\s*\()/;
const CODE_BITS = /=>|&&|\|\||[=;{}]|\b[\w.]+\(/;
const count = (s, ch) => s.split(ch).length - 1;
// a line that starts with a child: a whole {expression}, a whole element, a self closing tag, or a closing tag
// followed by more text; braces and tags balance on the line, so nothing carries on to the next one
function childLine(t) {
  if (count(t, "{") !== count(t, "}")) return false;
  if (/^\{/.test(t)) return true;
  if (/^<\/[\w.]*>\s*\S/.test(t)) return true;
  const open = t.match(/^<([A-Za-z][\w.]*)\b/);
  return Boolean(open) && (new RegExp(`</${open[1].replace(".", "\\.")}>`).test(t) || /^<[^<>]*\/>/.test(t));
}
// elements a line opens minus those it closes (self closing tags count for neither)
const netTags = (t) => (t.match(/<[A-Za-z][\w.]*(?:\s[^<>]*?)?(?<!\/)>/g) ?? []).length - (t.match(/<\/[\w.]*>/g) ?? []).length;
// The text lasts while an element opened since it began is still open: a closing </strong> inside an open <section>
// keeps the section's text going, and the closing </section> ends it.
function jsxTextLines(lines) {
  const out = [];
  let inText = false, depth = 0;
  lines.forEach((line, i) => {
    const t = line.trim();
    if (!t) return;
    const closeOnly = /^<\/[\w.]*>$/.test(t);
    const child = inText && /^[<{]/.test(t) && childLine(t);
    const textual = inText && !child && !closeOnly && !JS_LINE.test(t);
    // only the text before the first tag or brace and after the last one: text between tags is checked above
    if (textual) out.push([i, /[<>{}]/.test(t) ? `${t.split(/[<{]/)[0]} ${t.split(/[>}]/).pop()}`.trim() : t]);
    if (child) {
      const rest = t.split(/[>}]/).pop().trim();
      if (rest && !CODE_BITS.test(rest)) out.push([i, rest]);
    }
    // the next line is text when this one opens an element, or is text (or a child) inside an element still open
    const opens = /(^|[^=/-])>$/.test(t) && !/^[)}]/.test(t) && !closeOnly;
    if (opens) depth = (inText ? depth : 0) + Math.max(1, netTags(t));   // a ">" alone ends a tag begun above
    else if (inText && (child || textual || closeOnly)) depth += closeOnly ? -1 : netTags(t);
    else depth = 0;
    inText = depth > 0;
  });
  return out;
}

const found = [];
// the email catalogue lives with the edge functions; its wording is text people read too
const EXTRA = rootArg > 0 ? [] : [new URL("../supabase/functions/_shared/businessEmails.js", import.meta.url).pathname];
for (const f of [...files(ROOT), ...EXTRA]) {
  const lines = stripComments(readFileSync(f, "utf8")).split("\n");
  lines.forEach((line, i) => {
    const where = `${f.startsWith(ROOT) ? relative(ROOT, f) : f.slice(f.indexOf("supabase/"))}:${i + 1}`;
    if (LONG.test(line)) { found.push([where, "long dash", line.trim()]); return; }
    // JSX text between tags, and between an expression and the next tag or expression ("{n} follow-ups sent"); the
    // second kind holds no code punctuation, so props and calls after a "}" are left alone
    const between = [...line.matchAll(/(?<!=)>([^<>{}]*[A-Za-z][^<>{}]*)[<{]/g), ...line.matchAll(/\}([^<>{}=[\]"`\\:;]*[A-Za-z][^<>{}=[\]"`\\:;]*)[<{]/g)];
    for (const m of between) {
      if (m[0].startsWith("}") && JS_FLOW.test(m[1])) continue;   // "} else if (a-b) {" is code, not text
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
  if (/\.[jt]sx$/.test(f)) {
    for (const [i, words] of jsxTextLines(lines)) {
      if (LONG.test(lines[i]) || !WORD_HYPHEN.test(wordsOnly(words))) continue;   // a long dash is reported above
      found.push([`${f.startsWith(ROOT) ? relative(ROOT, f) : f}:${i + 1}`, "hyphen in text", words]);
    }
  }
}

if (process.argv.includes("--list")) for (const [w, k, t] of found) console.log(`${w}  ${k}: ${t.slice(0, 140)}`);
const byKind = found.reduce((a, [, k]) => ((a[k] = (a[k] ?? 0) + 1), a), {});
console.log(`check-dashes: ${found.length} found`, JSON.stringify(byKind));
process.exit(found.length ? 1 : 0);
