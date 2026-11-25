// What an audit row changed, in words, for the Activity tab (BIZ-17). Pure: web/tests/businessChanges.test.mjs.
import { humanize } from "../copy/labels.js";

const short = (v) => {
  if (v === null || v === undefined || v === "") return "not set";
  const text = typeof v === "object" ? (Array.isArray(v) ? v.map(String).join(", ") || "none" : JSON.stringify(v)) : String(v);
  return text.length > 60 ? `${text.slice(0, 57)}…` : text;
};

// Every field that changed, in words: { key, label, before, after, hadBefore }. Values are shortened ("not set" when
// empty). A record with only new data (nothing before) lists each recorded field. Used by the Activity tab and the
// Audit logs page (owner approved 25 Nov 2026: a readable list first, the raw record one click away).
export function changeRows(oldData, newData) {
  const before = oldData && typeof oldData === "object" && !Array.isArray(oldData) ? oldData : {};
  const after = newData && typeof newData === "object" && !Array.isArray(newData) ? newData : {};
  return [...new Set([...Object.keys(before), ...Object.keys(after)])]
    .filter((k) => JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null))
    .map((k) => ({ key: k, label: humanize(k), before: short(before[k]), after: short(after[k]), hadBefore: Object.hasOwn(before, k) }));
}

// "Suspended at: not set → 16 Nov" lines for the fields that changed (at most 5).
export function changeLines(oldData, newData) {
  return changeRows(oldData, newData).slice(0, 5).map((r) => `${r.label}: ${r.hadBefore ? `${r.before} → ` : ""}${r.after}`);
}
