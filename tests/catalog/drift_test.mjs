#!/usr/bin/env node
// PLT-08 drift test: every audit action, platform alert kind and admin permission that the code writes or checks
// must be in web/supabase/functions/_shared/catalog.json, and every name in that list must still be used.
//
// It reads every SQL file (sql/**), every edge function module (web/supabase/functions/**, so a new module file is
// covered without being listed here), the n8n code nodes (n8n/src) and the web app (web/src).
// Run by `npm run lint` in web. Usage: node tests/catalog/drift_test.mjs [--list]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { inventory, ROOT, stripJsComments } from "./scan.mjs";

export const CATALOG_PATH = join(ROOT, "web/supabase/functions/_shared/catalog.json");

// { name, kind, prefix, unresolved, where }[] and the catalog in; a list of problems out.
export function check(found, catalog, extra = {}) {
  const problems = [];
  const lists = {
    audit: { names: catalog.audit_actions ?? {}, prefixes: catalog.audit_action_prefixes ?? [], what: "audit action", key: "audit_actions" },
    alert: { names: catalog.alert_kinds ?? {}, prefixes: catalog.alert_kind_prefixes ?? [], what: "alert kind", key: "alert_kinds" },
    permission: { names: catalog.permissions ?? {}, prefixes: [], what: "permission", key: "permissions" },
  };
  const used = { audit: new Set(), alert: new Set(), permission: new Set() };
  // own entries only: "constructor" or "toString" are never catalog names
  const has = (names, n) => Object.prototype.hasOwnProperty.call(names, n);
  const usedPrefixes = { audit: new Set(), alert: new Set() };

  for (const f of found) {
    const kind = f.kind === "audit_read" ? "audit" : f.kind;
    const l = lists[kind];
    if (f.unresolved) { problems.push(`${f.where}: can't tell which ${l.what} "${f.name}" is; write it as a literal or a case`); continue; }
    if (f.kind === "audit_read") {
      const ok = f.prefix ? Object.keys(l.names).some((n) => n.startsWith(f.name)) : has(l.names, f.name);
      if (!ok) problems.push(`${f.where}: reads ${l.what} "${f.name}${f.prefix ? "%" : ""}", which nothing in ${l.key} matches`);
      continue;
    }
    if (f.prefix) {
      // permissions are only ever literal names: one built at run time is reported, never tracked as a prefix
      if (kind === "permission") { problems.push(`${f.where}: builds a permission starting "${f.name}" at run time; write each permission as a literal`); continue; }
      if (!l.prefixes.includes(f.name)) problems.push(`${f.where}: builds ${l.what}s starting "${f.name}" at run time; add "${f.name}" to ${kind === "audit" ? "audit_action_prefixes" : "alert_kind_prefixes"} and each name it makes to ${l.key}`);
      usedPrefixes[kind].add(f.name);
      continue;
    }
    used[kind].add(f.name);
    if (!has(l.names, f.name)) problems.push(`${f.where}: ${l.what} "${f.name}" is not in ${l.key} in catalog.json; add it with a label`);
  }

  for (const [kind, l] of Object.entries(lists)) {
    for (const [name, label] of Object.entries(l.names)) {
      if (typeof label !== "string" || !label.trim()) problems.push(`catalog.json: ${l.what} "${name}" has no label`);
      if (/[–—]|[A-Za-z]-[A-Za-z]/.test(label)) problems.push(`catalog.json: the label of "${name}" has a dash or hyphen`);
      const byPrefix = [...(usedPrefixes[kind] ?? [])].some((p) => name.startsWith(p));
      if (!used[kind].has(name) && !byPrefix) problems.push(`catalog.json: ${l.what} "${name}" is no longer written or checked anywhere; remove it`);
    }
    for (const p of l.prefixes) {
      if (!usedPrefixes[kind]?.has(p)) problems.push(`catalog.json: prefix "${p}" is no longer built anywhere; remove it`);
      if (!Object.keys(l.names).some((n) => n.startsWith(p))) problems.push(`catalog.json: prefix "${p}" has no names under it in ${l.key}`);
    }
    const sorted = Object.keys(l.names);
    if (sorted.join("\n") !== [...sorted].sort().join("\n")) problems.push(`catalog.json: keep ${l.key} sorted, so that two changes never touch the same line`);
  }

  // The role editor's list (settings.ts PERMISSION_CATALOG) and the owner only pair must equal the catalog.
  if (extra.permissionCatalog) {
    const ownerOnly = catalog.owner_only_permissions ?? [];
    const want = Object.keys(lists.permission.names).filter((p) => !ownerOnly.includes(p)).sort();
    const have = [...extra.permissionCatalog].sort();
    for (const p of want) if (!have.includes(p)) problems.push(`settings.ts PERMISSION_CATALOG: missing "${p}" from catalog.json`);
    for (const p of have) if (!want.includes(p)) problems.push(`settings.ts PERMISSION_CATALOG: "${p}" is not a catalog.json permission (or is owner only)`);
  }
  // Labels the web app keeps today (ownerFormat.js) must be for real actions.
  for (const a of extra.webLabels ?? []) {
    if (!has(lists.audit.names, a)) problems.push(`web/src/ownerFormat.js ACTION_LABELS: "${a}" is not an audit action in catalog.json`);
  }
  return [...new Set(problems)];
}

// The keys of an object literal's body, at its own level and outside comments: quoted with matching single or double
// quotes ("a.b": or 'a.b':), or a static computed key (["a.b"]:), wherever a property starts (also after another one
// on the same line). A computed key that isn't a plain string isn't a label name and is left out.
export function labelKeys(body) {
  const src = stripJsComments(body), out = [];
  const KEY = /\s*(?:(["'])([^"'\n]+)\1|\[\s*(["'])([^"'\n]+)\3\s*\])\s*:/y;
  let i = 0;
  while (i < src.length) {
    KEY.lastIndex = i;
    const m = KEY.exec(src);
    if (m) out.push(m[2] ?? m[4]);
    // on to the next property: past this one's value, to the next comma at this level (strings and regular
    // expression literals are skipped whole, so brackets or commas inside them count for nothing)
    let depth = 0, quote = null, prev = ":";
    const braces = [];   // for each open brace: "block" (after ) or =>, a function or statement body) or "object"
    for (; i < src.length; i++) {
      const c = src[i];
      if (quote) { if (c === "\\") { i++; continue; } if (c === quote) quote = null; continue; }
      if (c === "'" || c === '"' || c === "`") { quote = c; prev = c; continue; }
      // a regular expression literal, through its closing slash: only where a value starts (after ( , = : [ ! & | ? {);
      // after a value (a name, a number, ) ] or }) a slash divides
      if (c === "/" && "(,=:[!&|?{;".includes(prev)) {
        let cls = false;
        for (i++; i < src.length && src[i] !== "\n"; i++) {
          if (src[i] === "\\") { i++; continue; }
          if (src[i] === "[") cls = true; else if (src[i] === "]") cls = false; else if (src[i] === "/" && !cls) break;
        }
        prev = "/";
        continue;
      }
      if (c === "{") braces.push(prev === ")" || prev === ">" ? "block" : "object");
      if (!/\s/.test(c)) prev = c;
      if (c === "}" && braces.pop() === "block") prev = ";";   // after a block a statement starts: a slash is a regex
      if ("([{".includes(c)) depth++;
      else if (")]}".includes(c)) depth--;
      else if (c === "," && depth <= 0) { i++; break; }
    }
  }
  return out;
}

export function extras(root = ROOT) {
  const settings = readFileSync(join(root, "web/supabase/functions/owner-provision-business/settings.ts"), "utf8");
  const block = settings.match(/PERMISSION_CATALOG[^=]*=\s*\[([\s\S]*?)\n\];/);
  const permissionCatalog = block ? [...block[1].matchAll(/\[\s*"([a-z]+\.[a-z_]+)"/g)].map((m) => m[1]) : [];
  const fmt = readFileSync(join(root, "web/src/ownerFormat.js"), "utf8");
  const labels = fmt.match(/ACTION_LABELS\s*=\s*\{([\s\S]*?)\n\};/);
  const webLabels = labels ? labelKeys(labels[1]) : [];
  return { permissionCatalog, webLabels };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const catalog = JSON.parse(readFileSync(CATALOG_PATH, "utf8"));
  const found = inventory();
  if (process.argv.includes("--list")) {
    for (const f of found) console.log(`${f.kind}\t${f.prefix ? f.name + "*" : f.name}\t${f.where}`);
  }
  const problems = check(found, catalog, extras());
  const count = (k) => Object.keys(catalog[k] ?? {}).length;
  if (problems.length) {
    console.error(`Catalog drift (web/supabase/functions/_shared/catalog.json): ${problems.length} problem(s)`);
    for (const p of problems) console.error(`  ${p}`);
    process.exit(1);
  }
  console.log(`Catalog: ${count("audit_actions")} audit actions, ${count("alert_kinds")} alert kinds and ${count("permissions")} permissions match ${found.length} uses in the code.`);
}
