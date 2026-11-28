// What an audit row changed, in words, for the Activity tab (BIZ-17). Pure: web/tests/businessChanges.test.mjs.
import { humanize } from "../copy/labels.js";

const short = (v) => {
  if (v === null || v === undefined || v === "") return "not set";
  // a record's ID means nothing to a person reading the history; say it was set
  if (typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)) return "set";
  const text = typeof v === "object" ? (Array.isArray(v) ? v.map(String).join(", ") || "none" : JSON.stringify(v)) : String(v);
  return text.length > 60 ? `${text.slice(0, 57)}…` : text;
};

// Every field that changed, in words: { key, label, before, after, hadBefore }. Values are shortened ("not set" when
// empty). A record with only new data (nothing before) lists each recorded field. Used by the Activity tab and the
// Audit logs page (owner approved 25 Nov 2026: a readable list first, the raw record one click away).
const EMPTY_BEFORE = Object.freeze({});
const EMPTY_AFTER = Object.freeze({});
export function changeRows(oldData, newData) {
  const before = oldData && typeof oldData === "object" && !Array.isArray(oldData) ? oldData : EMPTY_BEFORE;
  const after = newData && typeof newData === "object" && !Array.isArray(newData) ? newData : EMPTY_AFTER;
  // with only one record, every recorded field is listed, null ones too; with both, unchanged fields are left out
  const single = before === EMPTY_BEFORE || after === EMPTY_AFTER;
  return [...new Set([...Object.keys(before), ...Object.keys(after)])]
    .filter((k) => single || JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null))
    .map((k) => ({ key: k, label: humanize(k), before: short(before[k]), after: short(after[k]), hadBefore: Object.hasOwn(before, k) }));
}

// "Suspended at: not set → 16 Nov" lines for the fields that changed (at most 5).
export function changeLines(oldData, newData) {
  return changeRows(oldData, newData).slice(0, 5).map((r) => `${r.label}: ${r.hadBefore ? `${r.before} → ` : ""}${r.after}`);
}
