// Collects the audit action names Zella Voice writes, for auditActions.test.mjs (BIZ-25).
//
// Scope, fixed up front so the test never needs weakening:
//   - sql/*.sql at the top level only (never sql/baseline, sql/rollback or sql/archive): the action literal of every
//     "insert into audit_logs ... ;" statement and the first argument of every zella_admin_audit(...) call;
//   - web/supabase/functions/owner-provision-business/*.ts except *_test.ts: every quoted "family.name" literal on an
//     action: line or on a ternary line that continues one.
// SQL comments ("-- ...") are removed first. An action built at run time ('offer.' || p_kind, "platform.alert_" + s)
// is returned as a prefix ending in "." or "_", and needs a family label.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ACTION = /^[a-z][a-z_]*[._][a-z_]+$/;

function stripSqlComments(source) {
  return source.split("\n").map((line) => {
    // Drop "-- ..." outside quotes.
    let inQuote = false;
    for (let i = 0; i < line.length; i++) {
      if (line[i] === "'") inQuote = !inQuote;
      if (!inQuote && line[i] === "-" && line[i + 1] === "-") return line.slice(0, i);
    }
    return line;
  }).join("\n");
}

export function sqlActions(source) {
  const found = new Set();
  const text = stripSqlComments(source);
  for (const m of text.matchAll(/insert\s+into\s+(?:public\.)?audit_logs\b([\s\S]*?);/gi)) {
    const body = m[1];
    for (const [, a] of body.matchAll(/'([a-z][a-z_]*\.[a-z_]+)'/g)) found.add(a);
    for (const [, a] of body.matchAll(/'([a-z][a-z_]*[._])'\s*\|\|/g)) found.add(a);
  }
  for (const m of text.matchAll(/zella_admin_audit\(\s*'([a-z][a-z_]*[._][a-z_]*)'/gi)) found.add(m[1]);
  return [...found].filter((a) => ACTION.test(a) || /[._]$/.test(a));
}

export function tsActions(source) {
  const found = new Set();
  const lines = source.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!/\baction:/.test(lines[i])) continue;
    // The action expression: this line, plus ternary continuation lines that start with ? or :.
    const chunk = [lines[i].slice(lines[i].indexOf("action:"))];
    for (let j = i + 1; j < lines.length && /^\s*[?:]\s/.test(lines[j]); j++) chunk.push(lines[j]);
    const expr = chunk.join(" ").split(/,\s*(?:business_id|entity_type|entity_id|old_data|new_data)\b/)[0];
    for (const [, a] of expr.matchAll(/"([a-z][a-z_]*\.[a-z_]*)"/g)) found.add(a);
  }
  return [...found].filter((a) => ACTION.test(a) || /[._]$/.test(a));
}

export function collectActions(root) {
  const all = new Map();
  const add = (list, file) => list.forEach((a) => all.set(a, [...(all.get(a) ?? []), file]));
  const sqlDir = join(root, "sql");
  for (const f of readdirSync(sqlDir).filter((f) => f.endsWith(".sql")).sort()) add(sqlActions(readFileSync(join(sqlDir, f), "utf8")), `sql/${f}`);
  const fnDir = join(root, "web/supabase/functions/owner-provision-business");
  for (const f of readdirSync(fnDir).filter((f) => f.endsWith(".ts") && !f.endsWith("_test.ts")).sort()) {
    add(tsActions(readFileSync(join(fnDir, f), "utf8")), `owner-provision-business/${f}`);
  }
  return all;
}
